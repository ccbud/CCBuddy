export { CCbuddyCliLoginError } from "./auth-login-contract.js";
export type {
  CodingPlanProviderId,
  LoginCCbuddyCliOptions,
  LoginCCbuddyCliResult,
  LoginBigmodelCodingPlanOptions,
  LoginBigmodelCodingPlanResult,
  ConfigureCodingPlanApiKeyOptions,
  ConfigureCodingPlanApiKeyResult,
  LogoutCCbuddyCliOptions,
  LogoutCCbuddyCliResult,
} from "./auth-login-contract.js";
import {
  CCbuddyCliLoginError,
  type CodingPlanProviderId,
  type LoginCCbuddyCliOptions,
  type LoginCCbuddyCliResult,
  type LoginBigmodelCodingPlanOptions,
  type LoginBigmodelCodingPlanResult,
  type ConfigureCodingPlanApiKeyOptions,
  type ConfigureCodingPlanApiKeyResult,
  type LogoutCCbuddyCliOptions,
  type LogoutCCbuddyCliResult,
} from "./auth-login-contract.js";
import {
  CLI_OAUTH_INVALID_FLOW_CODE,
  CliOAuthError,
  createCodingPlanApiKeyResolver,
  createSharedCCbuddyCredentialStore,
  createCliOAuthClient,
  createCliOAuthPollToken,
  openUrlInBrowser,
  SHARED_CCBUDDY_CREDENTIAL_KEYS,
  type CliOAuthClient,
  type SharedCCbuddyCredentialStore,
} from "@ccbuddy/adapters";
import { createConfig } from "@ccbuddy/adapters/config";
import { createNodeHttpClientAdapter } from "@ccbuddy/adapters/http";
import type { EnvRecord } from "@ccbuddy/adapters/model";
import { buildCCbuddyEndpointUrls, resolveRuntimeCCbuddyEndpointOrigin } from "@ccbuddy/shared";
import { setTimeout as delay } from "node:timers/promises";
import {
  createStandaloneAccountIdentityFromSecret,
  hasStandaloneCodingPlanAccess,
  readStandaloneCodingPlanProviders,
  resolveStandaloneCodingPlanProvider,
  standaloneAccountIdentityCredentialKey,
  standaloneAccountAuthSourceCredentialKey,
  standaloneAccountProviderCredentialKey,
} from "./app/standalone-account-provider-runtime.js";
import {
  NodeModelSelectionConfigRepository,
  NodePersonalProviderConfigRepository,
  PERSONAL_PROVIDER_CONFIG_FILE_NAME,
  CCBUDDY_PERSONAL_PROVIDER_CONFIG_FILE_ENV,
} from "@ccbuddy/provider-node";
import { dirname, join } from "node:path";
import { readLegacyCliPersonalProviderConfig } from "./app/legacy-cli-personal-provider-config-importer.js";
import { throwIfAborted, waitWithAbort } from "./auth-login-abort.js";
import { pollUntilReady } from "./auth-login-polling.js";

const DEFAULT_LOGIN_TIMEOUT_MS = 5 * 60 * 1_000;

/**
 * Z.ai 与 BigModel 共用服务端轮询登录：init 拿授权地址，浏览器授权后轮询到 ready，
 * 再解析项目访问材料并写入凭据与默认模型。OAuth 登录不落盘派生 API Key，
 * 运行时按 `authSource: "oauth"` 用访问令牌换取请求凭据。
 */
export async function loginCCbuddyCli(
  _options: LoginCCbuddyCliOptions = {},
): Promise<LoginCCbuddyCliResult> {
  // CCbuddy BYOK-only product: no upstream cloud account, OAuth, coding plan, or
  // subscription flow is exposed (docs/specs/byok-only.md). Use /apikey to register
  // a user-configured provider endpoint credential instead.
  throw new CCbuddyCliLoginError(
    "config_update_failed",
    "CCbuddy uses only user-configured provider endpoints",
  );
}

export async function loginBigmodelCodingPlan(
  options: LoginBigmodelCodingPlanOptions = {},
): Promise<LoginBigmodelCodingPlanResult> {
  return {
    ...(await loginCCbuddyCli({ ...options, providerId: "bigmodel" })),
    providerId: "bigmodel",
  };
}

export async function configureCodingPlanApiKey(
  options: ConfigureCodingPlanApiKeyOptions,
): Promise<ConfigureCodingPlanApiKeyResult> {
  const apiKey = options.apiKey.trim();
  if (!apiKey) {
    throw new CCbuddyCliLoginError("config_update_failed", "API key must not be empty.");
  }
  const credentialStore =
    options.credentialStore ?? createSharedCCbuddyCredentialStore({ env: options.env });
  // 手填 Key 也可能等待配置锁；必须沿用入口代次，避免恢复后仍提交旧默认模型。
  const credentialGuard = await credentialStore.captureRecoveryGuard();
  const configPatch = await credentialGuard.run(() =>
    persistStandaloneCodingPlanConnection({
      accountIdentity: createStandaloneAccountIdentityFromSecret(apiKey),
      apiKey,
      commitGuard: credentialGuard.commit,
      credentialStore,
      env: options.env ?? process.env,
      personalProviderConfigPath: options.personalProviderConfigPath,
      providerId: options.providerId,
    }),
  );
  return {
    configPath: configPatch.path,
    model: configPatch.mainModel,
    providerId: options.providerId,
  };
}

function createOAuthClient(options: LoginCCbuddyCliOptions, env: EnvRecord): CliOAuthClient {
  return createCliOAuthClient({
    baseUrl:
      options.baseUrl ?? buildCCbuddyEndpointUrls(resolveCliCCbuddyEndpointOrigin(env)).apiBaseUrl,
    providerId: options.providerId ?? "zai",
    httpClient: options.httpClient ?? createDefaultHttpClient(env),
  });
}

function resolveCliCCbuddyEndpointOrigin(env: EnvRecord): string {
  return resolveRuntimeCCbuddyEndpointOrigin(env);
}

function createDefaultHttpClient(env: EnvRecord) {
  const config = createConfig({ env });
  return createNodeHttpClientAdapter({
    env,
    proxyUrl: config.config.network.httpProxy,
    noProxy: config.config.network.noProxy,
    caCertFile: config.config.network.caCertFile,
    timeoutMs: config.config.network.timeout,
  });
}

async function resolveCodingPlanMaterial(input: {
  accessToken: string;
  env: EnvRecord;
  httpClient?: Parameters<typeof createCodingPlanApiKeyResolver>[0]["httpClient"];
  family: CodingPlanProviderId;
  signal?: AbortSignal;
  resolver?: ReturnType<typeof createCodingPlanApiKeyResolver>;
}) {
  const resolver =
    input.resolver ??
    createCodingPlanApiKeyResolver({
      httpClient: input.httpClient ?? createDefaultHttpClient(input.env),
    });
  return resolver.resolveMaterial(
    {
      accessToken: input.accessToken,
      family: input.family,
    },
    { signal: input.signal },
  );
}

interface StandaloneCodingPlanPersistenceResult {
  readonly mainModel: string;
  readonly path: string;
}

async function persistStandaloneCodingPlanConnection(input: {
  readonly accountIdentity: string;
  readonly apiKey?: string;
  readonly authSource?: "oauth";
  readonly credentialStore: SharedCCbuddyCredentialStore;
  readonly commitGuard?: (write: () => Promise<void>) => Promise<void>;
  readonly env: EnvRecord;
  readonly personalProviderConfigPath?: string;
  readonly providerId: CodingPlanProviderId;
}): Promise<StandaloneCodingPlanPersistenceResult> {
  const configuredProvider = await resolveStandaloneCodingPlanProvider(input.providerId, input.env);
  const providerId = configuredProvider.providerId;
  const modelId = configuredProvider.modelId;
  const credentialKey = standaloneAccountProviderCredentialKey({
    providerId,
    accountIdentity: input.accountIdentity,
  });
  await input.credentialStore.saveMany({
    [standaloneAccountIdentityCredentialKey(providerId)]: input.accountIdentity,
    [standaloneAccountAuthSourceCredentialKey(providerId)]: input.authSource ?? "manual",
    ...(input.apiKey ? { [credentialKey]: input.apiKey } : {}),
  });
  const path =
    input.personalProviderConfigPath ??
    input.env[CCBUDDY_PERSONAL_PROVIDER_CONFIG_FILE_ENV]?.trim() ??
    join(dirname(input.credentialStore.filePath), PERSONAL_PROVIDER_CONFIG_FILE_NAME);
  // 登录与运行时共享文件和事务；首次写入仍先保留旧用户 Provider，不能仅写默认值。
  const personalRepository = new NodePersonalProviderConfigRepository({
    filePath: path,
    commitGuard: input.commitGuard,
    importLegacy: () => readLegacyCliPersonalProviderConfig({}),
    pollingIntervalMs: false,
  });
  const repository = new NodeModelSelectionConfigRepository({
    personalRepository,
  });
  try {
    await repository.saveConfiguredDefault({ providerId, modelId });
  } finally {
    repository.dispose();
    personalRepository.dispose();
  }
  return {
    mainModel: `${providerId}/${modelId}`,
    path,
  };
}

export async function hasConfiguredStandaloneCodingPlan(
  options: {
    credentialStore?: SharedCCbuddyCredentialStore;
    env?: EnvRecord;
  } = {},
): Promise<boolean> {
  const credentialStore =
    options.credentialStore ?? createSharedCCbuddyCredentialStore({ env: options.env });
  return hasStandaloneCodingPlanAccess(credentialStore, options.env ?? process.env);
}

export async function logoutCCbuddyCli(
  options: LogoutCCbuddyCliOptions = {},
): Promise<LogoutCCbuddyCliResult> {
  // CCbuddy BYOK-only product: no upstream OAuth session to sign out of.
  return { credentialsPath: "" };
}
