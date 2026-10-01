import { createHash } from "node:crypto";
import type { CCbuddyHistoryImportProducer } from "@ccbuddy/shared";

/**
 * 同一条外部会话导入到同一 workspace 永远得到同一个 task id：
 * 再次"在 CCbuddy 继续"时能找回之前的任务，而不是堆出第二份副本。
 */
export function buildImportedHistoryTaskId(params: {
  producer: CCbuddyHistoryImportProducer;
  producerSessionId: string;
  workspacePath: string;
}): string {
  const digest = createHash("sha256")
    .update(`history:${params.producer}:${params.producerSessionId}:${params.workspacePath}`)
    .digest("hex")
    .slice(0, 24);
  return `history-import-${digest}`;
}
