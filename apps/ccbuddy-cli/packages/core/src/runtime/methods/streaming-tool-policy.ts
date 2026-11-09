import type { ModelToolCall } from "@ccbuddy/contracts";
import type { AgentRuntimeInternal } from "../internal.js";

const STREAMING_TOOL_EXECUTION_MODE = "readOnly";

export function shouldExecuteToolDuringStream(
  runtime: AgentRuntimeInternal,
  toolCall: ModelToolCall,
): boolean {
  if (toolCall.providerExecuted) return false;
  if (toolCall.name.trim().length === 0) return false;
  if (runtime.config.modelStreaming !== "on") return false;
  if ((runtime.config.streamingToolExecution ?? STREAMING_TOOL_EXECUTION_MODE) === "off") {
    return false;
  }
  const entry = runtime.registry.get(toolCall.name);
  if (!entry) return false;
  const metadata = entry.metadata;
  const sideEffectScope = entry.permission?.sideEffectScope ?? metadata.sideEffectScope;
  const requiresUserInteraction = entry.requiresUserInteraction ?? metadata.requiresUserInteraction;
  return (
    metadata.readOnly &&
    metadata.concurrentSafe &&
    !metadata.destructive &&
    !metadata.needsApproval &&
    !requiresUserInteraction &&
    sideEffectScope === "none"
  );
}
