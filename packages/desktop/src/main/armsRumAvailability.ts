import { CCBUDDY_ARMS_RUM_ENDPOINT, CCBUDDY_TELEMETRY_ENABLED } from "@ccbuddy/shared";

export function isArmsRumEnabled(telemetryEnabled: boolean, endpoint: string): boolean {
  return Boolean(telemetryEnabled && endpoint);
}

// 两个启动入口共用同一判断，避免未配置 ARMS 时跳过本地 crashReporter。
export const armsRumEnabled = isArmsRumEnabled(
  CCBUDDY_TELEMETRY_ENABLED,
  CCBUDDY_ARMS_RUM_ENDPOINT,
);
