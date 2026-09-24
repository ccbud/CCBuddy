import type {
  HistoryDiagnostic,
  HistoryLibraryPort,
  HistoryRefreshEvent,
  HistoryRefreshOptions,
  HistoryRefreshTerminal,
  HistoryRoot,
  HistorySessionDetail,
  HistorySessionSummary,
  HistorySnapshot,
} from "../contract.js";
import { HISTORY_PROTOCOL_VERSION } from "../contract.js";
import type { Candidate } from "../domain/candidate.js";
import type { HistorySourcePort, ParsedCandidate, ParsedSource } from "./source-adapter.js";

interface CatalogEntry {
  candidate: Candidate;
  summary: HistorySessionSummary;
  producerParentSessionId: string | null;
}

function linkParents(entries: Map<string, CatalogEntry>): void {
  const byProducerId = new Map<string, string>();
  for (const [id, entry] of entries) {
    byProducerId.set(`${entry.summary.source}\0${entry.summary.sessionId}`, id);
  }
  for (const [id, entry] of entries) {
    const raw = entry.producerParentSessionId;
    const parentId = raw ? (byProducerId.get(`${entry.summary.source}\0${raw}`) ?? null) : null;
    entry.summary = { ...entry.summary, parentSessionId: parentId === id ? null : parentId };
  }
}

function projectName(cwd: string | null): string {
  return cwd ? (cwd.replace(/\/+$/, "").split(/[\\/]/).at(-1) ?? "") : "";
}

function summarize(candidate: Candidate, parsed: ParsedSource): HistorySessionSummary {
  const createdAt = parsed.createdAt ?? candidate.stamp.createdAt;
  const lastActivity = parsed.lastActivity ?? candidate.stamp.modifiedAt;
  return {
    id: candidate.id,
    source: candidate.source,
    sessionId: parsed.sessionId,
    title: parsed.title,
    project: projectName(parsed.cwd),
    cwd: parsed.cwd,
    createdAt,
    lastActivity: new Date(Math.max(Date.parse(createdAt), Date.parse(lastActivity))).toISOString(),
    messageCount: parsed.messageCount,
    model: parsed.model,
    usage: parsed.usage,
    parentSessionId: parsed.parentSessionId,
    isSubagent: parsed.isSubagent,
    fingerprint: candidate.stamp.fingerprint,
  };
}

function diagnostic(candidate: Candidate, error: unknown): HistoryDiagnostic {
  const message = String(error);
  return {
    code: message.includes("changed") ? "changed_source" : "unreadable_file",
    source: candidate.source,
    path: candidate.path,
    message,
  };
}

function detailFromParsed(candidate: Candidate, result: ParsedCandidate): HistorySessionDetail {
  const current = { ...candidate, stamp: result.stamp };
  return {
    summary: summarize(current, result.parsed),
    messages: result.parsed.messages,
    diagnostics: result.diagnostics,
  };
}

export class HistoryLibraryCore implements HistoryLibraryPort {
  private readonly roots: readonly HistoryRoot[];
  private readonly explicitRoots: boolean;
  private generation = 0;
  private version = 0;
  private entries = new Map<string, CatalogEntry>();
  private snapshot: HistorySnapshot = {
    protocolVersion: HISTORY_PROTOCOL_VERSION,
    version: 0,
    sessions: [],
    diagnostics: [],
    complete: false,
  };

  constructor(
    roots: readonly HistoryRoot[],
    explicitRoots: boolean,
    private readonly sources: HistorySourcePort,
  ) {
    this.explicitRoots = explicitRoots;
    this.roots = roots;
  }

  list(): HistorySnapshot {
    return structuredClone(this.snapshot);
  }

  async load(id: string): Promise<HistorySessionDetail> {
    const starting = this.entries.get(id);
    if (!starting) throw new Error(`Unknown history session: ${id}`);
    let detail: HistorySessionDetail;
    try {
      detail = detailFromParsed(
        starting.candidate,
        await this.sources.parse(starting.candidate, "detail"),
      );
    } catch (error) {
      throw new Error(`Cannot read history session ${id}: ${String(error)}`);
    }
    const current = this.entries.get(id);
    if (
      !current ||
      (current !== starting && current.summary.fingerprint !== detail.summary.fingerprint)
    ) {
      throw new Error(`History session changed while loading: ${id}`);
    }
    const producerParentSessionId = detail.summary.parentSessionId;
    const parent = producerParentSessionId
      ? [...this.entries.values()].find(
          (entry) =>
            entry.summary.source === detail.summary.source &&
            entry.summary.sessionId === producerParentSessionId,
        )
      : null;
    detail.summary = { ...detail.summary, parentSessionId: parent?.summary.id ?? null };
    if (JSON.stringify(current.summary) !== JSON.stringify(detail.summary)) {
      const candidate = {
        ...current.candidate,
        stamp: await this.sources.stamp(current.candidate),
      };
      if (candidate.stamp.fingerprint !== detail.summary.fingerprint) {
        throw new Error(`History session changed while loading: ${id}`);
      }
      this.entries.set(id, { candidate, summary: detail.summary, producerParentSessionId });
      this.publish(this.snapshot.diagnostics, this.snapshot.complete);
    }
    return detail;
  }

  async refresh(options: HistoryRefreshOptions = {}): Promise<HistoryRefreshTerminal> {
    const generation = ++this.generation;
    const emit = (event: HistoryRefreshEvent): void => {
      try {
        options.onEvent?.(event);
      } catch {
        /* observer cannot change the owner */
      }
    };
    const cancelled = (): boolean =>
      options.signal?.aborted === true || generation !== this.generation;
    const finish = (status: HistoryRefreshTerminal["status"]): HistoryRefreshTerminal => {
      const terminal: HistoryRefreshTerminal = {
        type: "terminal",
        generation,
        status,
        snapshot: this.list(),
      };
      emit(terminal);
      return terminal;
    };
    if (cancelled()) return finish("cancelled");
    try {
      const found = await this.sources.discover(this.roots, this.explicitRoots, options.signal);
      if (cancelled()) return finish("cancelled");
      const next = new Map<string, CatalogEntry>();
      const diagnostics = [...found.diagnostics];
      let completed = 0;
      for (const candidate of found.candidates) {
        if (cancelled()) return finish("cancelled");
        try {
          const detail = detailFromParsed(
            candidate,
            await this.sources.parse(candidate, "metadata", options.signal),
          );
          const stamped = { ...candidate, stamp: await this.sources.stamp(candidate) };
          if (stamped.stamp.fingerprint !== detail.summary.fingerprint) {
            throw new Error("Source changed before catalog publication");
          }
          next.set(candidate.id, {
            candidate: stamped,
            summary: detail.summary,
            producerParentSessionId: detail.summary.parentSessionId,
          });
          diagnostics.push(...detail.diagnostics);
        } catch (error) {
          diagnostics.push(diagnostic(candidate, error));
          const previous = this.entries.get(candidate.id);
          if (previous) next.set(candidate.id, previous);
        }
        completed += 1;
        emit({
          type: "progress",
          generation,
          completed,
          total: found.candidates.length,
          source: candidate.source,
        });
      }
      if (cancelled()) return finish("cancelled");
      if (found.diagnostics.some((item) => item.code === "unreadable_root")) {
        // A failed root cannot authorize removal of its previously visible sessions.
        for (const [id, entry] of this.entries) {
          if (!next.has(id)) next.set(id, entry);
        }
      }
      linkParents(next);
      this.entries = next;
      this.publish(diagnostics, diagnostics.length === 0);
      return finish(
        diagnostics.some((item) => item.code !== "malformed_record") ? "error" : "success",
      );
    } catch (error) {
      if (cancelled()) return finish("cancelled");
      this.publish(
        [
          {
            code: "unreadable_root",
            source: null,
            path: null,
            message: String(error),
          },
        ],
        false,
      );
      return finish("error");
    }
  }

  private publish(diagnostics: HistoryDiagnostic[], complete: boolean): void {
    this.version += 1;
    const sessions = [...this.entries.values()]
      .map((entry) => entry.summary)
      .sort((a, b) => b.lastActivity.localeCompare(a.lastActivity) || a.id.localeCompare(b.id));
    this.snapshot = {
      protocolVersion: HISTORY_PROTOCOL_VERSION,
      version: this.version,
      sessions,
      diagnostics,
      complete,
    };
  }
}
