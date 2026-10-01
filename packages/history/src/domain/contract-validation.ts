import {
  HISTORY_PROTOCOL_VERSION,
  HISTORY_SOURCES,
  type HistoryRefreshEvent,
  type HistorySessionDetail,
  type HistorySnapshot,
  type HistorySource,
} from "./contract-types.js";

/** Runtime validation of the read contract; the renderer calls these before trusting IPC output. */

function record(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("Invalid history protocol object");
  }
  return value as Record<string, unknown>;
}

function requiredString(value: unknown): void {
  if (typeof value !== "string") throw new TypeError("Invalid history protocol string");
}

function nullableString(value: unknown): void {
  if (value !== null) requiredString(value);
}

function requiredNumber(value: unknown): void {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new TypeError("Invalid history protocol number");
  }
}

function requiredArray(value: unknown): unknown[] {
  if (!Array.isArray(value)) throw new TypeError("Invalid history protocol array");
  return value;
}

function requiredSource(value: unknown): void {
  if (!HISTORY_SOURCES.includes(value as HistorySource)) {
    throw new TypeError("Invalid history source");
  }
}

function validateSummary(value: unknown): void {
  const item = record(value);
  for (const key of [
    "id",
    "sessionId",
    "title",
    "project",
    "createdAt",
    "lastActivity",
    "fingerprint",
  ]) {
    requiredString(item[key]);
  }
  requiredSource(item.source);
  nullableString(item.cwd);
  nullableString(item.model);
  validateUsage(item.usage);
  nullableString(item.parentSessionId);
  requiredNumber(item.messageCount);
  if (typeof item.isSubagent !== "boolean") throw new TypeError("Invalid subagent flag");
}

function validateUsage(value: unknown): void {
  if (value === null) return;
  const usage = record(value);
  for (const key of ["inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens"]) {
    requiredNumber(usage[key]);
  }
}

function validateDiagnostic(value: unknown): void {
  const item = record(value);
  requiredString(item.code);
  nullableString(item.source);
  nullableString(item.path);
  requiredString(item.message);
  if (item.line !== undefined) requiredNumber(item.line);
}

function validateRootStatus(value: unknown): void {
  const item = record(value);
  requiredSource(item.source);
  requiredString(item.path);
  if (!["default", "environment", "profile", "custom"].includes(String(item.origin))) {
    throw new TypeError("Invalid history root origin");
  }
  if (typeof item.available !== "boolean") throw new TypeError("Invalid history root status");
}

function validateBlock(value: unknown): void {
  const block = record(value);
  switch (block.type) {
    case "text":
    case "reasoning":
      requiredString(block.text);
      return;
    case "tool_call":
      requiredString(block.toolName);
      nullableString(block.toolCallId);
      if (!("input" in block)) throw new TypeError("Missing tool input");
      return;
    case "tool_result":
      nullableString(block.toolCallId);
      if (!("output" in block)) throw new TypeError("Missing tool output");
      if (block.isError !== undefined && typeof block.isError !== "boolean") {
        throw new TypeError("Invalid tool result status");
      }
      return;
    case "image":
      requiredString(block.dataUrl);
      return;
    default:
      throw new TypeError("Invalid history content type");
  }
}

function validateMessage(value: unknown): void {
  const item = record(value);
  requiredString(item.id);
  requiredNumber(item.sequence);
  if (!["user", "assistant", "tool", "system"].includes(String(item.role))) {
    throw new TypeError("Invalid history role");
  }
  nullableString(item.timestamp);
  nullableString(item.model);
  if (item.usage !== undefined) validateUsage(item.usage);
  for (const block of requiredArray(item.blocks)) validateBlock(block);
}

/** Validates IPC output before a renderer trusts its shape. */
export function parseHistorySnapshot(value: unknown): HistorySnapshot {
  const result = record(value);
  if (result.protocolVersion !== HISTORY_PROTOCOL_VERSION) {
    throw new TypeError("Unsupported history protocol version");
  }
  requiredNumber(result.version);
  if (typeof result.complete !== "boolean") throw new TypeError("Invalid history completion flag");
  for (const item of requiredArray(result.sessions)) validateSummary(item);
  for (const item of requiredArray(result.diagnostics)) validateDiagnostic(item);
  // 根目录状态是本版新增字段；旧快照缺省视为未上报，而不是拒绝整份目录。
  if (result.roots === undefined) result.roots = [];
  for (const item of requiredArray(result.roots)) validateRootStatus(item);
  return result as unknown as HistorySnapshot;
}

export function parseHistorySessionDetail(value: unknown): HistorySessionDetail {
  const result = record(value);
  validateSummary(result.summary);
  for (const item of requiredArray(result.messages)) validateMessage(item);
  for (const item of requiredArray(result.diagnostics)) validateDiagnostic(item);
  return result as unknown as HistorySessionDetail;
}

export function parseHistoryRefreshEvent(value: unknown): HistoryRefreshEvent {
  const result = record(value);
  requiredNumber(result.generation);
  if (result.type === "progress") {
    requiredNumber(result.completed);
    requiredNumber(result.total);
    nullableString(result.source);
  } else if (result.type === "terminal") {
    if (!["success", "error", "cancelled"].includes(String(result.status))) {
      throw new TypeError("Invalid history terminal status");
    }
    parseHistorySnapshot(result.snapshot);
  } else throw new TypeError("Invalid history event type");
  return result as unknown as HistoryRefreshEvent;
}
