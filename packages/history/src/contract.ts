/** The renderer-facing, versioned read contract. No filesystem operation is exposed. */
export const HISTORY_PROTOCOL_VERSION = 1 as const;

export type HistorySource = "claude" | "codex" | "qoder" | "grok" | "copilot" | "antigravity";

export interface HistoryRoot {
  source: HistorySource;
  path: string;
}

export interface HistorySessionSummary {
  id: string;
  source: HistorySource;
  sessionId: string;
  title: string;
  project: string;
  cwd: string | null;
  createdAt: string;
  lastActivity: string;
  messageCount: number;
  model: string | null;
  usage: HistoryTokenUsage | null;
  parentSessionId: string | null;
  isSubagent: boolean;
  fingerprint: string;
}

export interface HistoryTokenUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
}

export type HistoryContentBlock =
  | { type: "text" | "reasoning"; text: string }
  | { type: "tool_call"; toolName: string; toolCallId: string | null; input: unknown }
  | { type: "tool_result"; toolCallId: string | null; output: unknown; isError?: boolean }
  | { type: "image"; dataUrl: string };

export interface HistoryMessage {
  id: string;
  sequence: number;
  role: "user" | "assistant" | "tool" | "system";
  timestamp: string | null;
  model: string | null;
  usage?: HistoryTokenUsage | null;
  blocks: HistoryContentBlock[];
}

export interface HistoryDiagnostic {
  code:
    | "unreadable_root"
    | "unsafe_path"
    | "unreadable_file"
    | "malformed_record"
    | "unsupported_record"
    | "changed_source";
  source: HistorySource | null;
  path: string | null;
  message: string;
  line?: number;
}

export interface HistorySessionDetail {
  summary: HistorySessionSummary;
  messages: HistoryMessage[];
  diagnostics: HistoryDiagnostic[];
}

export interface HistorySnapshot {
  protocolVersion: typeof HISTORY_PROTOCOL_VERSION;
  version: number;
  sessions: HistorySessionSummary[];
  diagnostics: HistoryDiagnostic[];
  complete: boolean;
}

export interface HistoryRefreshProgress {
  type: "progress";
  generation: number;
  completed: number;
  total: number;
  source: HistorySource | null;
}

export interface HistoryRefreshTerminal {
  type: "terminal";
  generation: number;
  status: "success" | "error" | "cancelled";
  snapshot: HistorySnapshot;
}

export type HistoryRefreshEvent = HistoryRefreshProgress | HistoryRefreshTerminal;

export interface HistoryRefreshOptions {
  signal?: AbortSignal;
  onEvent?: (event: HistoryRefreshEvent) => void;
}

export interface HistoryLibraryOptions {
  homeDirectory?: string;
  roots?: readonly HistoryRoot[];
}

export interface HistoryLibraryPort {
  list(): HistorySnapshot;
  load(id: string): Promise<HistorySessionDetail>;
  refresh(options?: HistoryRefreshOptions): Promise<HistoryRefreshTerminal>;
}

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
  if (
    !["claude", "codex", "qoder", "grok", "copilot", "antigravity"].includes(String(item.source))
  ) {
    throw new TypeError("Invalid history source");
  }
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
