import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { CCbuddyStdioTapDevState } from "@ccbuddy/shared";
import { getAppConfigDir } from "#src/paths.js";
import { isEffectiveDevelopmentNodeEnv } from "#src/runtime-tools/nodeEnv.js";

interface CCbuddyStdioTapStateFile {
  enabled?: boolean;
}

function isCCbuddyStdioTapDevVisible(): boolean {
  return isEffectiveDevelopmentNodeEnv();
}

function getCCbuddyStdioTapDevDir(): string {
  return join(getAppConfigDir(), "dev");
}

export function getCCbuddyStdioTapDevLogDir(): string {
  return join(getCCbuddyStdioTapDevDir(), "stdio-traffic");
}

function getCCbuddyStdioTapDevStatePath(): string {
  return join(getCCbuddyStdioTapDevDir(), "ccbuddy-stdio-tap.json");
}

function readStateFile(path: string): CCbuddyStdioTapStateFile {
  if (!existsSync(path)) {
    return {};
  }

  try {
    const parsed = JSON.parse(readFileSync(path, "utf-8")) as unknown;
    return parsed && typeof parsed === "object" ? (parsed as CCbuddyStdioTapStateFile) : {};
  } catch {
    return {};
  }
}

export function readCCbuddyStdioTapDevState(): CCbuddyStdioTapDevState {
  const visible = isCCbuddyStdioTapDevVisible();
  const statePath = getCCbuddyStdioTapDevStatePath();
  const fileState = readStateFile(statePath);
  return {
    enabled: visible && fileState.enabled === true,
    visible,
    logDir: getCCbuddyStdioTapDevLogDir(),
    statePath,
  };
}

export function setCCbuddyStdioTapDevEnabled(enabled: boolean): CCbuddyStdioTapDevState {
  const visible = isCCbuddyStdioTapDevVisible();
  const statePath = getCCbuddyStdioTapDevStatePath();
  mkdirSync(getCCbuddyStdioTapDevDir(), { recursive: true });
  writeFileSync(
    statePath,
    `${JSON.stringify(
      {
        // 开发态 stdio 抓包是高频原始协议帧，只能通过显式开关写旁路文件，避免误进生产日志。
        enabled: visible && enabled,
        updatedAt: new Date().toISOString(),
      },
      null,
      2,
    )}\n`,
  );
  return readCCbuddyStdioTapDevState();
}
