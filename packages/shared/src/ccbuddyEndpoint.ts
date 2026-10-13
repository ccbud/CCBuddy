import type { CCbuddyEnv } from "./env.js";

export const DEFAULT_CCBUDDY_ENDPOINT_ORIGIN = "https://ccbuddy.z.ai";
export const TEST_CCBUDDY_ENDPOINT_ORIGIN = "https://ccbuddy.z.ai";
export const CODING_PLAN_LOCAL_WEBVIEW_ORIGIN = "http://localhost:3000";
export const DEFAULT_BIGMODEL_API_ORIGIN = "https://bigmodel.cn";
export const TEST_BIGMODEL_API_ORIGIN = "https://bigmodel.cn";
export const DEFAULT_ZAI_OAUTH_ORIGIN = "https://chat.z.ai";
export const TEST_ZAI_OAUTH_ORIGIN = "https://chat.z.ai";
export const DEFAULT_ZAI_BUSINESS_BASE_URL = "https://api.z.ai";
export const TEST_ZAI_BUSINESS_BASE_URL = "https://api.z.ai";
export const DEFAULT_ZAI_OAUTH_CLIENT_ID = "client_P8X5CMWmlaRO9gyO-KSqtg";
export const TEST_ZAI_OAUTH_CLIENT_ID = "client_P8X5CMWmlaRO9gyO-KSqtg";
export interface CCbuddyEndpointUrls {
  origin: string;
  apiBaseUrl: string;
  webShareCallbackUrl: string;
  ccbuddyPlanOpenAiBaseUrl: string;
  ccbuddyPlanAnthropicBaseUrl: string;
  ccbuddyPlanBillingCurrentUrl: string;
  ccbuddyPlanBillingBalanceUrl: string;
}

export interface RuntimeCCbuddyEndpointEnv {
  [key: string]: string | undefined;
  CCBUDDY_ENV?: string;
  CCBUDDY_BASE_URL?: string;
  CCBUDDY_ENDPOINT_ORIGIN?: string;
  CCBUDDY_TEST_BASE_URL?: string;
  CCBUDDY_PRODUCTION_BASE_URL?: string;
}

export interface RuntimeBigModelApiEnv {
  [key: string]: string | undefined;
  CCBUDDY_ENV?: string;
  BIGMODEL_API_BASE_URL?: string;
  BIGMODEL_TEST_API_BASE_URL?: string;
  BIGMODEL_PRODUCTION_API_BASE_URL?: string;
}

export interface RuntimeZaiEndpointEnv {
  [key: string]: string | undefined;
  CCBUDDY_ENV?: string;
  ZAI_OAUTH_ORIGIN?: string;
  ZAI_TEST_OAUTH_ORIGIN?: string;
  ZAI_PRODUCTION_OAUTH_ORIGIN?: string;
  ZAI_BUSINESS_BASE_URL?: string;
  ZAI_TEST_BUSINESS_BASE_URL?: string;
  ZAI_PRODUCTION_BUSINESS_BASE_URL?: string;
  ZAI_OAUTH_CLIENT_ID?: string;
  ZAI_TEST_OAUTH_CLIENT_ID?: string;
  ZAI_PRODUCTION_OAUTH_CLIENT_ID?: string;
  ZAI_OAUTH_APP_ID?: string;
}

export interface RuntimeProductEndpointEnv
  extends RuntimeCCbuddyEndpointEnv, RuntimeBigModelApiEnv, RuntimeZaiEndpointEnv {}

export interface RuntimeProductEndpointConfig {
  ccbuddyEnv: CCbuddyEnv;
  ccbuddyEndpointOrigin: string;
  ccbuddyEndpointUrls: CCbuddyEndpointUrls;
  zaiOAuthOrigin: string;
  zaiBusinessBaseUrl: string;
  zaiOAuthClientId: string;
  bigModelApiOrigin: string;
}

function readRuntimeEnvValue(
  env: Record<string, string | undefined>,
  key: string,
): string | undefined {
  const value = env[key]?.trim();
  return value ? value : undefined;
}

function readRuntimeCCbuddyEnvScopedValue(
  env: Record<string, string | undefined>,
  ccbuddyEnv: CCbuddyEnv,
  testKey: string,
  productionKey: string,
): string | undefined {
  return readRuntimeEnvValue(env, ccbuddyEnv === "production" ? productionKey : testKey);
}

export function normalizeCCbuddyEndpointOrigin(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) {
    throw new Error("CCbuddy endpoint origin is empty");
  }

  const parsed = new URL(trimmed);
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") {
    throw new Error("CCbuddy endpoint origin must use http or https");
  }
  return parsed.origin;
}

function isLoopbackHostname(hostname: string): boolean {
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1";
}

export function isTrustedCodingPlanWebviewOrigin(
  value: string | null | undefined,
  options?: {
    e2eStoreBridgeEnabled?: boolean;
  },
): boolean {
  if (!value) return false;
  try {
    const origin = normalizeCCbuddyEndpointOrigin(value);
    if (
      origin === DEFAULT_CCBUDDY_ENDPOINT_ORIGIN ||
      origin === TEST_CCBUDDY_ENDPOINT_ORIGIN ||
      origin === CODING_PLAN_LOCAL_WEBVIEW_ORIGIN
    ) {
      return true;
    }
    const parsed = new URL(origin);
    return options?.e2eStoreBridgeEnabled === true && isLoopbackHostname(parsed.hostname);
  } catch {
    return false;
  }
}

export function resolveCCbuddyEndpointOrigin(options?: {
  env?: CCbuddyEnv;
  envBaseOrigin?: string | null;
  overrideOrigin?: string | null;
}): string {
  const env = options?.env ?? "test";
  const envBaseOrigin = options?.envBaseOrigin?.trim();
  if (env === "production") {
    return envBaseOrigin
      ? normalizeCCbuddyEndpointOrigin(envBaseOrigin)
      : DEFAULT_CCBUDDY_ENDPOINT_ORIGIN;
  }

  const overrideOrigin = options?.overrideOrigin?.trim();
  if (overrideOrigin) {
    return normalizeCCbuddyEndpointOrigin(overrideOrigin);
  }

  return envBaseOrigin
    ? normalizeCCbuddyEndpointOrigin(envBaseOrigin)
    : TEST_CCBUDDY_ENDPOINT_ORIGIN;
}

export function resolveRuntimeCCbuddyEnv(env: RuntimeCCbuddyEndpointEnv = {}): CCbuddyEnv {
  // 独立 CLI / 服务测试未注入 CCBUDDY_ENV 时默认生产域；桌面测试包会显式下发 CCBUDDY_ENV=test。
  return env.CCBUDDY_ENV?.trim().toLowerCase() === "test" ? "test" : "production";
}

export function resolveRuntimeCCbuddyEndpointOrigin(
  env: RuntimeCCbuddyEndpointEnv = {},
  options?: { overrideOrigin?: string | null },
): string {
  const ccbuddyEnv = resolveRuntimeCCbuddyEnv(env);
  const scopedBaseOrigin =
    ccbuddyEnv === "production"
      ? readRuntimeEnvValue(env, "CCBUDDY_PRODUCTION_BASE_URL")
      : readRuntimeEnvValue(env, "CCBUDDY_TEST_BASE_URL");

  return resolveCCbuddyEndpointOrigin({
    env: ccbuddyEnv,
    envBaseOrigin:
      readRuntimeEnvValue(env, "CCBUDDY_BASE_URL") ??
      readRuntimeEnvValue(env, "CCBUDDY_ENDPOINT_ORIGIN") ??
      scopedBaseOrigin,
    overrideOrigin: options?.overrideOrigin,
  });
}

export function buildRuntimeCCbuddyEndpointUrls(
  env: RuntimeCCbuddyEndpointEnv = {},
): CCbuddyEndpointUrls {
  return buildCCbuddyEndpointUrls(resolveRuntimeCCbuddyEndpointOrigin(env));
}

export function buildRuntimeCCbuddyApiUrl(
  env: RuntimeCCbuddyEndpointEnv = {},
  path: string,
): string {
  const normalizedPath = path.startsWith("/") ? path : `/${path}`;
  return `${resolveRuntimeCCbuddyEndpointOrigin(env)}${normalizedPath}`;
}

export function resolveBigModelApiOrigin(env: RuntimeBigModelApiEnv = {}): string {
  const ccbuddyEnv = resolveRuntimeCCbuddyEnv(env);
  const scopedBaseOrigin =
    ccbuddyEnv === "production"
      ? readRuntimeEnvValue(env, "BIGMODEL_PRODUCTION_API_BASE_URL")
      : readRuntimeEnvValue(env, "BIGMODEL_TEST_API_BASE_URL");
  const fallbackOrigin =
    ccbuddyEnv === "production" ? DEFAULT_BIGMODEL_API_ORIGIN : TEST_BIGMODEL_API_ORIGIN;

  return normalizeCCbuddyEndpointOrigin(
    readRuntimeEnvValue(env, "BIGMODEL_API_BASE_URL") ?? scopedBaseOrigin ?? fallbackOrigin,
  );
}

export function buildBigModelApiUrl(env: RuntimeBigModelApiEnv = {}, path: string): string {
  const normalizedPath = path.startsWith("/") ? path : `/${path}`;
  return `${resolveBigModelApiOrigin(env)}${normalizedPath}`;
}

export function buildBigModelCodingPlanPersonalManageUrl(env: RuntimeBigModelApiEnv = {}): string {
  // 修复原因：BigModel Coding Plan 管理页要跟随 CCBUDDY_ENV；
  // 测试环境如果继续写死 bigmodel.cn，会把测试账号带到生产套餐页。
  return buildBigModelApiUrl(env, "/coding-plan/personal/overview");
}

export function buildBigModelCodingPlanTeamManageUrl(env: RuntimeBigModelApiEnv = {}): string {
  return buildBigModelApiUrl(env, "/coding-plan/team/plans");
}

export function resolveZaiOAuthOrigin(env: RuntimeZaiEndpointEnv = {}): string {
  const ccbuddyEnv = resolveRuntimeCCbuddyEnv(env);
  const scopedOrigin = readRuntimeCCbuddyEnvScopedValue(
    env,
    ccbuddyEnv,
    "ZAI_TEST_OAUTH_ORIGIN",
    "ZAI_PRODUCTION_OAUTH_ORIGIN",
  );
  const fallbackOrigin =
    ccbuddyEnv === "production" ? DEFAULT_ZAI_OAUTH_ORIGIN : TEST_ZAI_OAUTH_ORIGIN;

  return normalizeCCbuddyEndpointOrigin(
    readRuntimeEnvValue(env, "ZAI_OAUTH_ORIGIN") ?? scopedOrigin ?? fallbackOrigin,
  );
}

export function resolveZaiBusinessBaseUrl(env: RuntimeZaiEndpointEnv = {}): string {
  const ccbuddyEnv = resolveRuntimeCCbuddyEnv(env);
  const scopedOrigin = readRuntimeCCbuddyEnvScopedValue(
    env,
    ccbuddyEnv,
    "ZAI_TEST_BUSINESS_BASE_URL",
    "ZAI_PRODUCTION_BUSINESS_BASE_URL",
  );
  const fallbackOrigin =
    ccbuddyEnv === "production" ? DEFAULT_ZAI_BUSINESS_BASE_URL : TEST_ZAI_BUSINESS_BASE_URL;

  return normalizeCCbuddyEndpointOrigin(
    readRuntimeEnvValue(env, "ZAI_BUSINESS_BASE_URL") ?? scopedOrigin ?? fallbackOrigin,
  );
}

export function resolveZaiOAuthClientId(env: RuntimeZaiEndpointEnv = {}): string {
  const ccbuddyEnv = resolveRuntimeCCbuddyEnv(env);
  const scopedClientId = readRuntimeCCbuddyEnvScopedValue(
    env,
    ccbuddyEnv,
    "ZAI_TEST_OAUTH_CLIENT_ID",
    "ZAI_PRODUCTION_OAUTH_CLIENT_ID",
  );
  const fallbackClientId =
    ccbuddyEnv === "production" ? DEFAULT_ZAI_OAUTH_CLIENT_ID : TEST_ZAI_OAUTH_CLIENT_ID;

  return (
    readRuntimeEnvValue(env, "ZAI_OAUTH_CLIENT_ID") ??
    scopedClientId ??
    readRuntimeEnvValue(env, "ZAI_OAUTH_APP_ID") ??
    fallbackClientId
  );
}

export function buildZaiOAuthUrl(origin: string, path: string): string {
  const normalizedPath = path.startsWith("/") ? path : `/${path}`;
  return `${normalizeCCbuddyEndpointOrigin(origin)}${normalizedPath}`;
}

export function buildRuntimeZaiOAuthUrl(env: RuntimeZaiEndpointEnv = {}, path: string): string {
  return buildZaiOAuthUrl(resolveZaiOAuthOrigin(env), path);
}

export function buildRuntimeZaiBusinessUrl(env: RuntimeZaiEndpointEnv = {}, path: string): string {
  const normalizedPath = path.startsWith("/") ? path : `/${path}`;
  return `${resolveZaiBusinessBaseUrl(env)}${normalizedPath}`;
}

export function resolveRuntimeProductEndpointConfig(
  env: RuntimeProductEndpointEnv = {},
): RuntimeProductEndpointConfig {
  const ccbuddyEnv = resolveRuntimeCCbuddyEnv(env);
  const ccbuddyEndpointOrigin = resolveRuntimeCCbuddyEndpointOrigin(env);

  return {
    ccbuddyEnv,
    ccbuddyEndpointOrigin,
    ccbuddyEndpointUrls: buildCCbuddyEndpointUrls(ccbuddyEndpointOrigin),
    zaiOAuthOrigin: resolveZaiOAuthOrigin(env),
    zaiBusinessBaseUrl: resolveZaiBusinessBaseUrl(env),
    zaiOAuthClientId: resolveZaiOAuthClientId(env),
    bigModelApiOrigin: resolveBigModelApiOrigin(env),
  };
}

export function buildCCbuddyEndpointUrls(origin: string): CCbuddyEndpointUrls {
  const normalizedOrigin = normalizeCCbuddyEndpointOrigin(origin);
  return {
    origin: normalizedOrigin,
    apiBaseUrl: `${normalizedOrigin}/api/v1`,
    webShareCallbackUrl: `${normalizedOrigin}/cn/share/callback`,
    ccbuddyPlanOpenAiBaseUrl: `${normalizedOrigin}/api/v1/ccbuddy-plan`,
    ccbuddyPlanAnthropicBaseUrl: `${normalizedOrigin}/api/v1/ccbuddy-plan/anthropic`,
    ccbuddyPlanBillingCurrentUrl: `${normalizedOrigin}/api/v1/ccbuddy-plan/billing/current`,
    ccbuddyPlanBillingBalanceUrl: `${normalizedOrigin}/api/v1/ccbuddy-plan/billing/balance`,
  };
}

export function rewriteCCbuddyEndpointUrl(
  input: string | URL,
  endpointOrigin: string,
): string | URL {
  const originalUrl = typeof input === "string" ? input : input.toString();
  let parsed: URL;
  try {
    parsed = new URL(originalUrl);
  } catch {
    return input;
  }
  const sourceOrigin = DEFAULT_CCBUDDY_ENDPOINT_ORIGIN;
  if (parsed.origin !== sourceOrigin) {
    return input;
  }

  const targetOrigin = normalizeCCbuddyEndpointOrigin(endpointOrigin);
  if (targetOrigin === sourceOrigin) {
    return input;
  }

  const target = new URL(targetOrigin);
  target.pathname = parsed.pathname;
  target.search = parsed.search;
  target.hash = parsed.hash;
  return target.toString();
}
