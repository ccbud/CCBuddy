import { DEFAULT_CCBUDDY_ENDPOINT_ORIGIN } from "./ccbuddyEndpoint.js";

export const CCBUDDY_SOURCE_HEADERS = {
  "User-Agent": "CCbuddy/unknown",
  "HTTP-Referer": DEFAULT_CCBUDDY_ENDPOINT_ORIGIN,
  "X-Title": "CCbuddy@electron",
} as const;

export interface BuildCCbuddySourceHeadersFromContextOptions {
  appVersion?: string;
  arch?: string;
  clientLanguage?: string;
  clientTimezone?: string;
  deviceMid?: string;
  endpointOrigin?: string;
  osVersion?: string;
  platform?: string;
  releaseChannel?: string;
  sourceTitle?: string;
}

export function normalizeCCbuddySourceHeaderValue(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  if (!trimmed || !/^[\x20-\x7e]+$/.test(trimmed)) {
    return undefined;
  }
  return trimmed;
}

export function buildCCbuddySourceHeadersFromContext(
  options: BuildCCbuddySourceHeadersFromContextOptions = {},
): Record<string, string> {
  const appVersion = normalizeCCbuddySourceHeaderValue(options.appVersion);
  const arch = normalizeCCbuddySourceHeaderValue(options.arch);
  const clientLanguage = normalizeCCbuddySourceHeaderValue(options.clientLanguage) ?? "unknown";
  const clientTimezone = normalizeCCbuddySourceHeaderValue(options.clientTimezone) ?? "unknown";
  const deviceMid = normalizeCCbuddySourceHeaderValue(options.deviceMid);
  const endpointOrigin =
    normalizeCCbuddySourceHeaderValue(options.endpointOrigin) ?? DEFAULT_CCBUDDY_ENDPOINT_ORIGIN;
  const osVersion = normalizeCCbuddySourceHeaderValue(options.osVersion);
  const platform = normalizeCCbuddySourceHeaderValue(options.platform);
  const releaseChannel = normalizeCCbuddySourceHeaderValue(options.releaseChannel);
  const sourceTitle = normalizeCCbuddySourceHeaderValue(options.sourceTitle) ?? "electron";

  return {
    ...CCBUDDY_SOURCE_HEADERS,
    "HTTP-Referer": endpointOrigin,
    "User-Agent": `CCbuddy/${appVersion ?? "unknown"}`,
    ...(appVersion ? { "X-CCbuddy-App-Version": appVersion } : {}),
    "X-Title": `CCbuddy@${sourceTitle}`,
    ...(platform && arch ? { "X-Platform": `${platform}-${arch}` } : {}),
    ...(releaseChannel ? { "X-Release-Channel": releaseChannel } : {}),
    "X-Client-Language": clientLanguage,
    "X-Client-Timezone": clientTimezone,
    ...(platform ? { "X-Os-Category": normalizeOsCategory(platform) } : {}),
    ...(osVersion ? { "X-Os-Version": osVersion } : {}),
    ...(deviceMid ? { "X-Device-Mid": deviceMid } : {}),
  };
}

function normalizeOsCategory(platform: string): string {
  switch (platform) {
    case "darwin":
      return "macos";
    case "win32":
      return "windows";
    default:
      return "linux";
  }
}
