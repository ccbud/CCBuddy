import type { HistoryDiagnostic, HistoryRoot } from "../contract.js";
import type { HistorySourcePort, ParsedCandidate, SourceInput } from "../app/source-adapter.js";
import type { Candidate } from "../domain/candidate.js";
import { claudeAdapter } from "./claude.js";
import { codexAdapter } from "./codex.js";
import { qoderAdapter } from "./qoder.js";
import { grokAdapter } from "./grok.js";
import { copilotAdapter } from "./copilot.js";
import { parseAntigravity } from "./antigravity.js";
import { discover, stamp, stampSqlite } from "./discovery.js";
import { jsonlRecords, readTextSidecar } from "./source-file.js";

const adapters = {
  claude: claudeAdapter,
  codex: codexAdapter,
  qoder: qoderAdapter,
  grok: grokAdapter,
  copilot: copilotAdapter,
};

export class FileHistorySourceRepository implements HistorySourcePort {
  discover(roots: readonly HistoryRoot[], explicit: boolean, signal?: AbortSignal) {
    return discover(roots, explicit, signal);
  }

  stamp(candidate: Candidate) {
    return candidate.source === "antigravity"
      ? stampSqlite(candidate.path, candidate.root)
      : stamp(candidate.path, candidate.root);
  }

  async parse(
    candidate: Candidate,
    mode: "metadata" | "detail",
    signal?: AbortSignal,
  ): Promise<ParsedCandidate> {
    const before = await this.stamp(candidate);
    const freshCandidate = { ...candidate, stamp: before };
    let parsed: ParsedCandidate["parsed"];
    let diagnostics: HistoryDiagnostic[] = [];
    if (candidate.source === "antigravity") {
      parsed = await parseAntigravity(freshCandidate, mode, signal);
    } else {
      const input: SourceInput = {
        file: candidate.path,
        relativePath: candidate.relativePath,
        records: jsonlRecords(freshCandidate, diagnostics, signal),
        mode,
        readJsonSidecar: async (name) => {
          const text = await readTextSidecar(candidate, name);
          if (text === null) return null;
          const value: unknown = JSON.parse(text);
          return value !== null && typeof value === "object" && !Array.isArray(value)
            ? (value as Record<string, unknown>)
            : null;
        },
        readTextSidecar: (name) => readTextSidecar(candidate, name),
      };
      parsed = await adapters[candidate.source].parse(input);
    }
    const after = await this.stamp(candidate);
    if (after.fingerprint !== before.fingerprint) throw new Error("Source changed during parsing");
    return { stamp: after, parsed, diagnostics: [...diagnostics, ...(parsed.diagnostics ?? [])] };
  }
}
