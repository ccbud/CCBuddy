/** Read-only renderer contract. These types are structural and have no Node dependency. */
export type HistorySource = "claude" | "codex" | "qoder" | "grok" | "copilot" | "antigravity";

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
  usage?: HistoryTokenUsage | null;
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
  blocks: readonly HistoryContentBlock[];
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
  messages: readonly HistoryMessage[];
  diagnostics: readonly HistoryDiagnostic[];
}

export interface HistorySnapshot {
  protocolVersion: 1;
  version: number;
  sessions: readonly HistorySessionSummary[];
  diagnostics: readonly HistoryDiagnostic[];
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

export type HistoryLocale = "zh-CN" | "en-US";
