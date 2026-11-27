import type {
  AiSdkModelExecutionConfig,
  AiSdkNetworkConfig,
  EnvRecord,
} from "@ccbuddy/adapters/model";
import type { ProviderEndpointRoutingPort } from "@ccbuddy/contracts";
import {
  resolveRuntimeCCbuddyEnv,
  resolveRuntimeCCbuddyEndpointOrigin,
  CCBUDDY_APP_VERSION_ENV,
  CCBUDDY_CLIENT_LANGUAGE_ENV,
} from "@ccbuddy/shared";
import {
  createRuntimePlatformHeaders,
  normalizePrintableHeaderValue,
} from "./runtime-platform-headers.js";

export type ModelProviderSourceTitle = "cli" | "electron";

interface RuntimeExecutionConfigOptions {
  appVersion?: string;
  endpointRoutingPort?: ProviderEndpointRoutingPort;
  network?: AiSdkNetworkConfig;
  sourceTitle?: ModelProviderSourceTitle;
}

export function createRuntimeAiSdkModelExecutionConfig(
  env: EnvRecord = process.env,
  options: RuntimeExecutionConfigOptions = {},
): AiSdkModelExecutionConfig {
  const network = normalizeAiSdkNetworkConfig(options.network);
  return {
    defaultHeaders: buildCliCCbuddySourceHeaders(env, options),
    env,
    ...(network ? { network } : {}),
    ...(options.endpointRoutingPort ? { endpointRoutingPort: options.endpointRoutingPort } : {}),
  };
}

function normalizeAiSdkNetworkConfig(
  network: AiSdkNetworkConfig | undefined,
): AiSdkNetworkConfig | undefined {
  if (!network?.caCertFile && !network?.httpProxy && !network?.noProxy) return undefined;
  return {
    ...(network.caCertFile ? { caCertFile: network.caCertFile } : {}),
    ...(network.httpProxy ? { httpProxy: network.httpProxy } : {}),
    ...(network.noProxy ? { noProxy: network.noProxy } : {}),
  };
}

export function buildCliCCbuddySourceHeaders(
  env: EnvRecord,
  options: Pick<RuntimeExecutionConfigOptions, "appVersion" | "sourceTitle"> = {},
): Record<string, string> {
  const sourceTitle = options.sourceTitle ?? detectDefaultProviderSourceTitle();
  const appVersion = resolveAppVersionForHeaders(env, options);
  const locale = resolveClientLanguageForHeaders(env);
  const timezone = normalizePrintableHeaderValue(Intl.DateTimeFormat().resolvedOptions().timeZone);
  return {
    "HTTP-Referer": resolveRuntimeCCbuddyEndpointOrigin(env),
    "User-Agent": `CCbuddy/${appVersion ?? "unknown"}`,
    ...(appVersion ? { "X-CCbuddy-App-Version": appVersion } : {}),
    "X-Title": `CCbuddy@${sourceTitle}`,
    "X-Release-Channel": resolveRuntimeCCbuddyEnv(env),
    "X-Client-Language": locale ?? "unknown",
    "X-Client-Timezone": timezone ?? "unknown",
    "X-CCbuddy-Agent": "glm",
    ...createRuntimePlatformHeaders(),
  };
}

function resolveAppVersionForHeaders(
  env: EnvRecord,
  options: Pick<RuntimeExecutionConfigOptions, "appVersion">,
): string | undefined {
  return normalizePrintableHeaderValue(env[CCBUDDY_APP_VERSION_ENV] ?? options.appVersion);
}

/**
 * X-Client-Language 优先取 Desktop spawn 时下发的界面语言（CCBUDDY_CLIENT_LANGUAGE）。
 * Bug 原因：过去只取 Agent 进程 Intl，App 从 Dock 启动没有 LANG 时 ICU 回退 en-US，
 * 界面选日/俄/韩语时模型请求仍发 en-US。非法或空值回落 Intl，不阻断请求。
 */
export function resolveClientLanguageForHeaders(env: EnvRecord): string | undefined {
  return (
    normalizePrintableHeaderValue(env[CCBUDDY_CLIENT_LANGUAGE_ENV]) ??
    normalizePrintableHeaderValue(Intl.DateTimeFormat().resolvedOptions().locale)
  );
}

function detectDefaultProviderSourceTitle(): ModelProviderSourceTitle {
  return process.argv.includes("app-server") || process.argv.includes("agent-server")
    ? "electron"
    : "cli";
}
