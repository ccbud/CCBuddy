import { isDeepStrictEqual } from "node:util";
import type { RuntimeMessageEntry } from "../../agent/message-history.js";

interface Candidate<Model> {
  controller: AbortController;
  entries: readonly RuntimeMessageEntry[];
  instructions: string;
  model: Model;
  status: "pending" | "ready" | "failed";
  summary?: string;
  abortSignals: Map<AbortSignal, () => void>;
}

const candidates = new WeakMap<object, Candidate<unknown>>();

export function startSpeculativeCompaction<Model>(
  owner: object,
  input: {
    entries: readonly RuntimeMessageEntry[];
    instructions: string;
    model: Model;
    signal?: AbortSignal;
    run: (signal: AbortSignal) => Promise<string>;
    onFailure?: (error: unknown) => void;
  },
): void {
  if (input.signal?.aborted) {
    discardSpeculativeCompaction(owner);
    return;
  }
  const existing = candidates.get(owner);
  if (existing && matches(existing, input)) {
    if (existing.status === "pending") linkAbortSignal(owner, existing, input.signal);
    return;
  }
  discardSpeculativeCompaction(owner);

  let entries: RuntimeMessageEntry[];
  try {
    // The candidate must own the exact source snapshot. No later turn may mutate it.
    entries = structuredClone(input.entries) as RuntimeMessageEntry[];
  } catch {
    return;
  }
  const controller = new AbortController();
  const candidate: Candidate<Model> = {
    abortSignals: new Map(),
    controller,
    entries,
    instructions: input.instructions,
    model: input.model,
    status: "pending",
  };
  candidates.set(owner, candidate);
  linkAbortSignal(owner, candidate, input.signal);
  void Promise.resolve()
    .then(() => {
      if (controller.signal.aborted) return undefined;
      return input.run(controller.signal);
    })
    .then((summary) => {
      if (candidates.get(owner) !== candidate || controller.signal.aborted) return;
      if (!summary?.trim()) {
        candidate.status = "failed";
        return;
      }
      candidate.summary = summary;
      candidate.status = "ready";
    })
    .catch((error: unknown) => {
      if (candidates.get(owner) !== candidate || controller.signal.aborted) return;
      candidate.status = "failed";
      input.onFailure?.(error);
    })
    .finally(() => unlinkAbortSignals(candidate));
}

export function takeSpeculativeCompaction<Model>(
  owner: object,
  input: {
    entries: readonly RuntimeMessageEntry[];
    instructions: string;
    model: Model;
  },
): { entryCount: number; summary: string } | undefined {
  const candidate = candidates.get(owner);
  if (!candidate) return undefined;
  const valid = matches(candidate, input) && candidate.status === "ready";
  const result =
    valid && candidate.summary
      ? { entryCount: candidate.entries.length, summary: candidate.summary }
      : undefined;
  discardSpeculativeCompaction(owner);
  return result;
}

export function buildSecondPassEntries(
  entries: readonly RuntimeMessageEntry[],
  contextPrefixCount: number,
  prepared: { entryCount: number; summary: string },
): RuntimeMessageEntry[] {
  if (prepared.entryCount < contextPrefixCount || prepared.entryCount > entries.length) {
    return [...entries];
  }
  return [
    ...entries.slice(0, contextPrefixCount),
    {
      message: {
        role: "user",
        content: `Earlier conversation summary (first compaction pass):\n\n${prepared.summary}`,
      },
    },
    ...entries.slice(prepared.entryCount),
  ];
}

export function discardSpeculativeCompaction(owner: object): void {
  const candidate = candidates.get(owner);
  if (!candidate) return;
  candidates.delete(owner);
  unlinkAbortSignals(candidate);
  candidate.controller.abort();
}

function linkAbortSignal(
  owner: object,
  candidate: Candidate<unknown>,
  signal: AbortSignal | undefined,
): void {
  if (!signal || candidate.abortSignals.has(signal)) return;
  if (signal.aborted) {
    discardSpeculativeCompaction(owner);
    return;
  }
  const abort = () => discardSpeculativeCompaction(owner);
  signal.addEventListener("abort", abort, { once: true });
  candidate.abortSignals.set(signal, () => signal.removeEventListener("abort", abort));
}

function unlinkAbortSignals(candidate: Candidate<unknown>): void {
  for (const unlink of candidate.abortSignals.values()) unlink();
  candidate.abortSignals.clear();
}

function matches<Model>(
  candidate: Candidate<unknown>,
  input: { entries: readonly RuntimeMessageEntry[]; instructions: string; model: Model },
): boolean {
  return (
    candidate.model === input.model &&
    candidate.instructions === input.instructions &&
    candidate.entries.length <= input.entries.length &&
    isDeepStrictEqual(candidate.entries, input.entries.slice(0, candidate.entries.length))
  );
}
