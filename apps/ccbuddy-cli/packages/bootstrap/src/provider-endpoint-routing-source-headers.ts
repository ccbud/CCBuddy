import { readFile } from "node:fs/promises";
import { arch as readOsArch, homedir, release as readOsRelease } from "node:os";
import { join } from "node:path";
import {
  buildCCbuddySourceHeadersFromContext,
  resolveRuntimeCCbuddyEndpointOrigin,
  resolveRuntimeCCbuddyEnv,
  CCBUDDY_APP_VERSION_ENV,
} from "@ccbuddy/shared";
import type { ModelProviderSourceTitle } from "./model-config.js";

const CCBUDDY_DATA_BASE_DIR_ENV_KEY = "CCBUDDY_DATA_BASE_DIR";
const cachedDeviceMidByStateFile = new Map<string, string>();

interface CreateProviderEndpointRoutingSourceHeadersOptions {
  appVersion?: string;
  env?: NodeJS.ProcessEnv;
  sourceTitle?: ModelProviderSourceTitle;
}

export async function createProviderEndpointRoutingSourceHeaders(
  options: CreateProviderEndpointRoutingSourceHeadersOptions = {},
): Promise<Record<string, string>> {
  const env = options.env ?? process.env;
  const deviceMid = await readExistingDeviceMid(resolveTelemetryStateFile(env));
  return buildCCbuddySourceHeadersFromContext({
    appVersion: env[CCBUDDY_APP_VERSION_ENV] ?? options.appVersion,
    arch: readOsArch(),
    clientLanguage: resolveClientLanguage(),
    clientTimezone: resolveClientTimezone(),
    deviceMid,
    endpointOrigin: resolveRuntimeCCbuddyEndpointOrigin(env),
    osVersion: readOsRelease(),
    platform: process.platform,
    releaseChannel: resolveRuntimeCCbuddyEnv(env),
    sourceTitle: options.sourceTitle ?? "cli",
  });
}

function resolveClientLanguage(): string {
  return Intl.DateTimeFormat().resolvedOptions().locale;
}

function resolveClientTimezone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone;
}

function resolveTelemetryStateFile(env: NodeJS.ProcessEnv): string {
  const dataBaseDir = env[CCBUDDY_DATA_BASE_DIR_ENV_KEY]?.trim() || homedir();
  return join(dataBaseDir, ".ccbuddy", "v2", "telemetry-state.json");
}

async function readExistingDeviceMid(
  stateFile: string,
): Promise<string | undefined> {
  const cached = cachedDeviceMidByStateFile.get(stateFile);
  if (cached) {
    return cached;
  }

  try {
    const parsed = JSON.parse(await readFile(stateFile, "utf8")) as {
      deviceMid?: unknown;
    };
    if (typeof parsed.deviceMid !== "string") {
      return undefined;
    }

    const deviceMid = parsed.deviceMid.trim();
    if (!deviceMid || !/^[\x20-\x7e]+$/.test(deviceMid)) {
      return undefined;
    }

    cachedDeviceMidByStateFile.set(stateFile, deviceMid);
    return deviceMid;
  } catch {
    // deviceMid 由 Desktop telemetry 管理；Agent 只异步复用已存在值，不创建或修改设备身份。
    return undefined;
  }
}
