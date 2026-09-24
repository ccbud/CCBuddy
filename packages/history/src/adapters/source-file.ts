import { realpath } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { createInterface } from "node:readline";
import type { HistoryDiagnostic } from "../contract.js";
import type { SourceRecord } from "../app/source-adapter.js";
import { object } from "../domain/value.js";
import { type Candidate, openVerified, stamp, withinRoot } from "./discovery.js";

const MAX_ROW_DIAGNOSTICS = 256;

export async function* jsonlRecords(
  candidate: Candidate,
  diagnostics: HistoryDiagnostic[],
  signal?: AbortSignal,
): AsyncGenerator<SourceRecord> {
  const { handle, before } = await openVerified(candidate);
  const stream = handle.createReadStream({ autoClose: false, signal });
  const lines = createInterface({ input: stream, crlfDelay: Infinity });
  let lineNumber = 0;
  let malformedRows = 0;
  try {
    for await (const line of lines) {
      if (signal?.aborted) throw new Error("History read cancelled");
      lineNumber += 1;
      if (line.trim() === "") continue;
      let value: unknown;
      try {
        value = JSON.parse(line);
      } catch {
        value = null;
      }
      if (value === null || Array.isArray(value) || typeof value !== "object") {
        malformedRows += 1;
        if (malformedRows <= MAX_ROW_DIAGNOSTICS) {
          diagnostics.push({
            code: "malformed_record",
            source: candidate.source,
            path: candidate.path,
            line: lineNumber,
            message: `Ignored malformed JSONL record at line ${lineNumber}`,
          });
        }
      } else {
        yield { number: lineNumber, value: object(value) };
      }
    }
  } finally {
    lines.close();
    stream.destroy();
    await handle.close();
  }
  if (malformedRows > MAX_ROW_DIAGNOSTICS) {
    diagnostics.push({
      code: "malformed_record",
      source: candidate.source,
      path: candidate.path,
      message: `Ignored ${malformedRows - MAX_ROW_DIAGNOSTICS} additional malformed JSONL records`,
    });
  }
  const after = await stamp(candidate.path, candidate.root);
  if (after.fingerprint !== before.fingerprint) throw new Error("Source changed during read");
}

/** A parser may read only fixed-name sidecars alongside its already approved transcript. */
export async function readTextSidecar(candidate: Candidate, name: string): Promise<string | null> {
  if (name !== basename(name) || name === "." || name === "..") {
    throw new Error("Invalid sidecar name");
  }
  const path = join(dirname(candidate.path), name);
  let canonical: string;
  try {
    canonical = await realpath(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw error;
  }
  if (!withinRoot(canonical, candidate.root) || canonical !== path) {
    throw new Error("Sidecar escapes its approved directory");
  }
  const sidecar = { ...candidate, path };
  const { handle, before } = await openVerified(sidecar);
  try {
    if (before.size > 8_000_000n) throw new Error("Sidecar is not a bounded ordinary file");
    const contents = await handle.readFile({ encoding: "utf8" });
    const after = await stamp(path, candidate.root);
    if (after.fingerprint !== before.fingerprint) throw new Error("Sidecar changed during read");
    return contents;
  } finally {
    await handle.close();
  }
}
