/** The renderer-facing, versioned read contract. No filesystem operation is exposed. */
export const HISTORY_PROTOCOL_VERSION = 1 as const;

export type HistorySource =
  | "ccbuddy"
  | "claude"
  | "codex"
  | "qoder"
  | "grok"
  | "copilot"
  | "antigravity";

export const HISTORY_SOURCES: readonly HistorySource[] = [
  "ccbuddy",
  "claude",
  "codex",
  "qoder",
  "grok",
  "copilot",
  "antigravity",
];

/** Where a scanned root came from: shipped defaults, an environment variable, a detected profile directory, or user configuration. */
export type HistoryRootOrigin = "default" | "environment" | "profile" | "custom";

export interface HistoryRoot {
  source: HistorySource;
  path: string;
  origin?: HistoryRootOrigin;
}

/** The roots a refresh actually looked at; `available` is false when the directory does not exist or cannot be read. */
export interface HistoryRootStatus {
  source: HistorySource;
  path: string;
  origin: HistoryRootOrigin;
  available: boolean;
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
  roots: HistoryRootStatus[];
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
  /** Replaces default discovery entirely; missing explicit roots are reported instead of skipped. */
  roots?: readonly HistoryRoot[];
  /** User-configured roots merged into default discovery; resolved again on every refresh. */
  extraRoots?: () => Promise<readonly HistoryRoot[]> | readonly HistoryRoot[];
  /** Environment used for `CLAUDE_CONFIG_DIR`, `CODEX_HOME` and similar overrides. */
  environment?: NodeJS.ProcessEnv;
  /** Directory holding CCbuddy's own agent session database (`db.sqlite`). */
  ccbuddySessionDatabaseDirectory?: string;
}

export interface HistoryLibraryPort {
  list(): HistorySnapshot;
  load(id: string): Promise<HistorySessionDetail>;
  refresh(options?: HistoryRefreshOptions): Promise<HistoryRefreshTerminal>;
}
