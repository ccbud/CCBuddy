import { CCBUDDY_ARMS_RUM_ENDPOINT } from "@ccbuddy/shared";

export function isArmsRumEnabled(endpoint: string): boolean {
  return Boolean(endpoint.trim());
}

// 两个启动入口共用同一判断，避免未配置 ARMS 时跳过本地 crashReporter。
// 修复原因：可选采集能力已由 endpoint 是否配置决定，旧 telemetry 开关导出已移除；
// 沿用旧导入会在 Main 启动前抛错，且会让本地 crashReporter 的选择与 SDK 分叉。
export const armsRumEnabled = isArmsRumEnabled(CCBUDDY_ARMS_RUM_ENDPOINT);
