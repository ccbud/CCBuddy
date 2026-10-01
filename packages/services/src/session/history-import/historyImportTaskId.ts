import { createHash } from "node:crypto";
import { resolveWorkspaceKey, type CCbuddyHistoryImportProducer } from "@ccbuddy/shared";

/**
 * 同一条外部会话导入到同一 workspace 永远得到同一个 task id：
 * 再次"在 CCbuddy 继续"时能找回之前的任务，而不是堆出第二份副本。
 */
export function buildImportedHistoryTaskId(params: {
  producer: CCbuddyHistoryImportProducer;
  producerSessionId: string;
  workspacePath: string;
  workspaceIdentity?: string;
}): string {
  // taskId 同时是全局路由和 Agent 持久化键；只哈希路径会让同路径的远程 workspace 串用会话。
  // 复用标准 identity key；没有 identity 时仍使用原路径，保持已有本地导入 ID 不变。
  const workspaceKey = resolveWorkspaceKey(params);
  const digest = createHash("sha256")
    .update(`history:${params.producer}:${params.producerSessionId}:${workspaceKey}`)
    .digest("hex")
    .slice(0, 24);
  return `history-import-${digest}`;
}
