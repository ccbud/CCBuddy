import type {
  BrowserOpenResult,
  SharedCCbuddyCredentialStore,
  CliOAuthClient,
  CliOAuthInitData,
  CliOAuthPollData,
  CliOAuthUser,
  createCliOAuthClient,
  createCodingPlanApiKeyResolver,
} from "@ccbuddy/adapters";
import type { EnvRecord } from "@ccbuddy/adapters/model";

export type CodingPlanProviderId = "bigmodel" | "zai";

export interface LoginCCbuddyCliOptions {
  providerId?: CodingPlanProviderId;
  abortSignal?: AbortSignal;
  apiKeyResolver?: ReturnType<typeof createCodingPlanApiKeyResolver>;
  baseUrl?: string;
  credentialStore?: SharedCCbuddyCredentialStore;
  env?: EnvRecord;
  httpClient?: Parameters<typeof createCliOAuthClient>[0]["httpClient"];
  noBrowser?: boolean;
  now?: () => number;
  onAuthorizeUrl?: (data: CliOAuthInitData) => void | Promise<void>;
  onBrowserOpen?: (result: BrowserOpenResult) => void | Promise<void>;
  onPollStatus?: (data: CliOAuthPollData) => void | Promise<void>;
  openBrowser?: (url: string) => Promise<BrowserOpenResult>;
  pollToken?: string;
  sleep?: (ms: number) => Promise<void>;
  timeoutMs?: number;
  personalProviderConfigPath?: string;
}

export interface LoginCCbuddyCliResult {
  browser?: BrowserOpenResult;
  configPath: string;
  credentialsPath: string;
  model: string;
  providerId: CodingPlanProviderId;
  user: CliOAuthUser;
}

export type LoginBigmodelCodingPlanOptions = Omit<LoginCCbuddyCliOptions, "providerId">;
export type LoginBigmodelCodingPlanResult = LoginCCbuddyCliResult & { providerId: "bigmodel" };

export interface ConfigureCodingPlanApiKeyOptions {
  apiKey: string;
  credentialStore?: SharedCCbuddyCredentialStore;
  env?: EnvRecord;
  personalProviderConfigPath?: string;
  providerId: CodingPlanProviderId;
}

export interface ConfigureCodingPlanApiKeyResult {
  configPath: string;
  model: string;
  providerId: CodingPlanProviderId;
}

export interface LogoutCCbuddyCliOptions {
  credentialStore?: SharedCCbuddyCredentialStore;
  env?: EnvRecord;
}

export interface LogoutCCbuddyCliResult {
  credentialsPath: string;
}

const ACCOUNT_LOGIN_DISABLED = "Account login is unavailable. Configure your own model provider.";

export async function hasConfiguredStandaloneCodingPlan(): Promise<boolean> {
  return false;
}

export class CCbuddyCliLoginError extends Error {
  readonly code:
    | "auth_failed"
    | "auth_timeout"
    | "config_update_failed"
    | "credential_write_failed";

  constructor(
    code: CCbuddyCliLoginError["code"],
    message: string,
    options: { cause?: unknown } = {},
  ) {
    super(message, options);
    this.name = "CCbuddyCliLoginError";
    this.code = code;
  }
}

export async function loginCCbuddyCli(
  _options: LoginCCbuddyCliOptions = {},
): Promise<LoginCCbuddyCliResult> {
  throw new Error(ACCOUNT_LOGIN_DISABLED);
}

export async function loginBigmodelCodingPlan(
  _options: LoginBigmodelCodingPlanOptions = {},
): Promise<LoginBigmodelCodingPlanResult> {
  throw new Error(ACCOUNT_LOGIN_DISABLED);
}

export async function configureCodingPlanApiKey(
  _options: ConfigureCodingPlanApiKeyOptions,
): Promise<ConfigureCodingPlanApiKeyResult> {
  throw new Error(ACCOUNT_LOGIN_DISABLED);
}

export async function logoutCCbuddyCli(
  _options: LogoutCCbuddyCliOptions = {},
): Promise<LogoutCCbuddyCliResult> {
  throw new Error(ACCOUNT_LOGIN_DISABLED);
}
