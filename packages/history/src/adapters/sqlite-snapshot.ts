import { constants } from "node:fs";
import { mkdtemp, open, rm } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { DatabaseSync as DatabaseSyncType } from "node:sqlite";
import type { Candidate, SourceStamp } from "../domain/candidate.js";
import { openVerified, stamp, stampSqlite } from "./discovery.js";

// Desktop's bundler rewrites a direct node:sqlite import to a bare sqlite import.
// Loading through require preserves the built-in protocol in the Electron main bundle.
const { DatabaseSync } = createRequire(import.meta.url)(
  "node:sqlite",
) as typeof import("node:sqlite");

export async function copyVerified(candidate: Candidate, destination: string): Promise<void> {
  const { handle, before } = await openVerified(candidate);
  let target;
  try {
    target = await open(
      destination,
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL,
      0o600,
    );
    const buffer = Buffer.allocUnsafe(1024 * 1024);
    let position = 0;
    while (true) {
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, position);
      if (bytesRead === 0) break;
      let written = 0;
      while (written < bytesRead) {
        const result = await target.write(buffer, written, bytesRead - written, position + written);
        if (result.bytesWritten === 0) throw new Error("Cannot copy SQLite snapshot");
        written += result.bytesWritten;
      }
      position += bytesRead;
    }
    const after = await stamp(candidate.path, candidate.root);
    if (after.fingerprint !== before.fingerprint)
      throw new Error("Source changed while making SQLite snapshot");
  } finally {
    await handle.close();
    await target?.close();
  }
}

/**
 * Runs `read` against a private copy of a producer SQLite database and its WAL / shared-memory
 * siblings. SQLite only ever sees bytes copied through verified descriptors, never a producer
 * path that could be swapped for a symlink between validation and open, and the composite
 * fingerprint must be identical before and after the read.
 */
export async function withSqliteSnapshot<T>(
  candidate: Candidate,
  read: (database: DatabaseSyncType) => T | Promise<T>,
): Promise<{ result: T; stamp: SourceStamp }> {
  const before = await stampSqlite(candidate.path, candidate.root);
  const privateDirectory = await mkdtemp(join(tmpdir(), "ccbuddy-history-db-"));
  let result: T;
  try {
    const snapshot = join(privateDirectory, "source.db");
    await copyVerified(candidate, snapshot);
    for (const suffix of ["-wal", "-shm"]) {
      const sibling = { ...candidate, path: `${candidate.path}${suffix}` };
      try {
        await copyVerified(sibling, `${snapshot}${suffix}`);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
    }
    const database = new DatabaseSync(snapshot);
    try {
      result = await read(database);
    } finally {
      database.close();
    }
  } finally {
    await rm(privateDirectory, { recursive: true, force: true });
  }
  const after = await stampSqlite(candidate.path, candidate.root);
  if (after.fingerprint !== before.fingerprint) throw new Error("Source changed during read");
  return { result, stamp: after };
}
