import type {
  HistoryDiagnostic,
  HistoryMessage,
  HistoryRoot,
  HistorySource,
  HistoryTokenUsage,
} from "../contract.js";
import type { Candidate, SourceStamp } from "../domain/candidate.js";
import type { JsonRecord } from "../domain/value.js";

export interface SourceRecord {
  number: number;
  value: JsonRecord;
}

export interface SourceInput {
  file: string;
  relativePath: string;
  records: AsyncIterable<SourceRecord>;
  mode: "metadata" | "detail";
  readJsonSidecar(name: string): Promise<JsonRecord | null>;
  readTextSidecar(name: string): Promise<string | null>;
}

export interface ParsedSource {
  sessionId: string;
  title: string;
  cwd: string | null;
  model: string | null;
  parentSessionId: string | null;
  isSubagent: boolean;
  createdAt: string | null;
  lastActivity: string | null;
  messages: HistoryMessage[];
  messageCount: number;
  usage: HistoryTokenUsage | null;
  diagnostics?: HistoryDiagnostic[];
}

export interface SourceAdapter {
  source: HistorySource;
  parse(input: SourceInput): Promise<ParsedSource>;
}

export interface ParsedCandidate {
  stamp: SourceStamp;
  parsed: ParsedSource;
  diagnostics: HistoryDiagnostic[];
}

export interface HistorySourcePort {
  discover(
    roots: readonly HistoryRoot[],
    explicit: boolean,
    signal?: AbortSignal,
  ): Promise<{
    candidates: Candidate[];
    diagnostics: HistoryDiagnostic[];
  }>;
  parse(
    candidate: Candidate,
    mode: "metadata" | "detail",
    signal?: AbortSignal,
  ): Promise<ParsedCandidate>;
  stamp(candidate: Candidate): Promise<SourceStamp>;
}
