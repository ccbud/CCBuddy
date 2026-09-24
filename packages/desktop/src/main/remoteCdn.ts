import { CCBUDDY_VERSION, type CCbuddyEnv } from "@ccbuddy/shared";

declare const __CCBUDDY_CDN_BASE_URL__: string | undefined;

export interface ResolveRemoteCdnOptions {
  env?: CCbuddyEnv;
  locale?: string;
  timeZone?: string;
  overrideBaseUrl?: string;
  version?: string;
  now?: Date;
}

function normalizeBaseUrl(value: string): string {
  const url = new URL(value);
  if (!["http:", "https:"].includes(url.protocol))
    throw new Error("CDN URL must use http or https");
  return value.replace(/\/+$/, "");
}

export function resolveRemoteCdnBaseUrls(options: ResolveRemoteCdnOptions = {}): string[] {
  const override = options.overrideBaseUrl?.trim();
  if (override) return [normalizeBaseUrl(override)];
  const baseUrl =
    process.env.CCBUDDY_CDN_BASE_URL?.trim() ||
    (typeof __CCBUDDY_CDN_BASE_URL__ === "undefined" ? "" : __CCBUDDY_CDN_BASE_URL__);
  // A copied CCbuddy CDN is not a CCbuddy release source. Remote deployment remains
  // available when an operator supplies a CCbuddy-owned asset base explicitly.
  if (!baseUrl) return [];
  return [
    `${normalizeBaseUrl(baseUrl)}/ccbuddy/electron/releases/${options.version ?? CCBUDDY_VERSION}`,
  ];
}
