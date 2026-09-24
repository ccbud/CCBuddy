// ── 旧协议兼容面（过渡期）──────────────────────────────
// 剩余 1 个导出：deriveCCbuddyTaskStatusFromSessionSnapshot。
// 消费者：ccbuddyTaskServiceAdapter/ccbuddyTaskIndexSyncer/ccbuddySessionProjection（旧投影栈）。
import type { CCbuddySessionStateSnapshot } from "./ccbuddy-protocol/index.js";
import { getCCbuddyUserVisibleMessages } from "./ccbuddy-session-visible-content.js";
import type { CCbuddyTaskMeta } from "./ccbuddy-task-types-core.js";
type CCbuddyTaskStatus = CCbuddyTaskMeta["status"];

function statusFromCCbuddySession(
  status: CCbuddySessionStateSnapshot["session"]["status"],
): CCbuddyTaskStatus {
  if (status === "running" || status === "waiting" || status === "paused") {
    return "running";
  }
  if (status === "error") return "error";
  if (status === "completed") return "completed";
  return undefined;
}

function hasBlockingActiveSnapshotRuntime(snapshot: CCbuddySessionStateSnapshot): boolean {
  if (snapshot.runtime.activeTurnId || snapshot.runtime.activeTurnKind) {
    return true;
  }
  // projection.currentTurnId 是最后一次投影的 turn 边界，完成后会保留；
  // 只有 runtime active 字段、权限或工具调用才能证明当前仍有真实阻塞运行态。
  if ((snapshot.projection.pendingPermissions ?? []).length > 0) {
    return true;
  }
  return (snapshot.projection.activeToolCalls ?? []).some(
    (toolCall) => toolCall.status === "pending" || toolCall.status === "running",
  );
}

function hasActiveSnapshotRuntime(snapshot: CCbuddySessionStateSnapshot): boolean {
  return hasBlockingActiveSnapshotRuntime(snapshot);
}

function isToolCallContinuationFinish(finish: string | undefined): boolean {
  const normalized = finish?.trim().toLowerCase().replace(/_/g, "-");
  return normalized === "tool-calls";
}

function hasCompletedVisibleAssistantTurn(snapshot: CCbuddySessionStateSnapshot): boolean {
  const visibleMessages = getCCbuddyUserVisibleMessages(snapshot.messages, {
    target: snapshot.projection.target,
  });
  const latestVisibleMessage = visibleMessages.at(-1);
  if (latestVisibleMessage?.info.role !== "assistant") {
    return false;
  }
  if (isToolCallContinuationFinish(latestVisibleMessage.info.finish)) {
    return false;
  }
  return typeof latestVisibleMessage.info.time.completed === "number";
}

export function deriveCCbuddyTaskStatusFromSessionSnapshot(
  snapshot: CCbuddySessionStateSnapshot,
): CCbuddyTaskStatus {
  if (snapshot.projection.lastError) {
    return "error";
  }

  const status = statusFromCCbuddySession(snapshot.session.status);
  if (status === "error" || status === "completed") {
    return status;
  }
  if (hasCompletedVisibleAssistantTurn(snapshot) && !hasBlockingActiveSnapshotRuntime(snapshot)) {
    // desktop continuous 的 session/read 依赖 runtime projection。
    // 旧投影有可能只 replay 到 model_streaming finish，漏掉 turn_complete，导致 currentTurnId
    // 短暂或长期残留。此时持久化 assistant 已有 completed 时间，比 stale currentTurnId 更权威。
    return "completed";
  }
  if (hasActiveSnapshotRuntime(snapshot)) {
    return status ?? "running";
  }
  return status;
}
