import type { CCbuddyTaskRuntimeStatus } from "@ccbuddy/shared";

export function isLiveTaskRuntimeStatus(status: CCbuddyTaskRuntimeStatus | undefined): boolean {
  // Bugfix: restoring 只是历史恢复，不代表 agent 正在执行新一轮生成。
  return status === "creating" || status === "streaming";
}
