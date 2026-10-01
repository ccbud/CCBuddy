import { createHash } from "node:crypto";
import type { DatabaseSync } from "node:sqlite";
import type { HistoryTokenUsage } from "../contract.js";
import type { ParsedSource } from "../app/source-adapter.js";
import type { Candidate } from "../domain/candidate.js";
import { MessageCollector } from "../domain/message-collector.js";
import { message, string } from "../domain/value.js";
import {
  CONTENT_PART_TYPES,
  decodeMessage,
  numberValue,
  parseJson,
  partBlocks,
  rowNumber,
  rowString,
  type Row,
} from "./ccbuddy-parts.js";
import { stampSqlite } from "./discovery.js";
import { withSqliteSnapshot } from "./sqlite-snapshot.js";

/**
 * CCbuddy's own agent sessions live in one SQLite database (`session`, `message`, `part`
 * tables). Unlike the JSONL producers, one file holds every session, so discovery expands the
 * database into one catalog candidate per session row and keeps the per-session metadata of a
 * single verified snapshot in a cache keyed by the database fingerprint.
 */

const BATCH_ROWS = 512;
const TITLE_MAX_CHARS = 90;

interface SessionMeta {
  id: string;
  title: string;
  titleSource: string | null;
  directory: string | null;
  parentId: string | null;
  created: number;
  updated: number;
}

interface SessionStats {
  count: number;
  model: string | null;
  usage: HistoryTokenUsage | null;
  firstUserText: string | null;
}

export interface CcbuddyBundle {
  path: string;
  fingerprint: string;
  sessions: Map<string, ParsedSource>;
}

/** One verified snapshot per refresh: session listing and per-session metadata share the read. */
export class CcbuddyMetadataCache {
  private bundle: CcbuddyBundle | null = null;

  get(path: string, fingerprint: string): CcbuddyBundle | null {
    return this.bundle && this.bundle.path === path && this.bundle.fingerprint === fingerprint
      ? this.bundle
      : null;
  }

  set(bundle: CcbuddyBundle): void {
    this.bundle = bundle;
  }
}

function readSessionRows(database: DatabaseSync): SessionMeta[] {
  const rows = database.prepare("SELECT * FROM session").all() as Row[];
  const sessions: SessionMeta[] = [];
  for (const row of rows) {
    const id = rowString(row.id);
    if (!id) continue;
    sessions.push({
      id,
      title: typeof row.title === "string" ? row.title : "",
      titleSource: rowString(row.title_source),
      directory: rowString(row.directory),
      parentId: rowString(row.parent_id),
      created: rowNumber(row.time_created),
      updated: rowNumber(row.time_updated),
    });
  }
  return sessions;
}

function* batches(database: DatabaseSync, sql: string, signal?: AbortSignal): Generator<Row> {
  const statement = database.prepare(sql);
  let cursor = -1n;
  while (true) {
    if (signal?.aborted) throw new Error("History read cancelled");
    const rows = statement.all(cursor) as Row[];
    if (rows.length === 0) return;
    for (const row of rows) {
      const rowId = row.row_id;
      cursor = typeof rowId === "bigint" ? rowId : BigInt(numberValue(rowId));
      yield row;
    }
  }
}

function resolveTitle(session: SessionMeta, firstUserText: string | null): string {
  const stored = session.title.trim();
  if (stored && session.titleSource !== "default") return stored.slice(0, TITLE_MAX_CHARS);
  const derived = firstUserText?.trim().slice(0, TITLE_MAX_CHARS) ?? "";
  return derived || stored.slice(0, TITLE_MAX_CHARS);
}

function parsedSource(
  session: SessionMeta,
  stats: SessionStats | undefined,
  collector: MessageCollector | null,
): ParsedSource {
  const title = resolveTitle(session, collector?.title || (stats?.firstUserText ?? null));
  const created = session.created > 0 ? new Date(session.created).toISOString() : null;
  const updated = session.updated > 0 ? new Date(session.updated).toISOString() : created;
  return {
    sessionId: session.id,
    title,
    cwd: session.directory,
    model: stats?.model ?? null,
    parentSessionId: session.parentId,
    isSubagent: session.parentId !== null,
    createdAt: created,
    lastActivity: updated,
    messages: collector?.messages ?? [],
    messageCount: collector?.count ?? stats?.count ?? 0,
    usage: collector?.usage ?? stats?.usage ?? null,
  };
}

function addUsage(total: HistoryTokenUsage | null, next: HistoryTokenUsage): HistoryTokenUsage {
  if (!total) return { ...next };
  total.inputTokens += next.inputTokens;
  total.outputTokens += next.outputTokens;
  total.cacheReadTokens += next.cacheReadTokens;
  total.cacheWriteTokens += next.cacheWriteTokens;
  return total;
}

/** Metadata for every session from one snapshot; bodies stay in the database. */
export function buildCcbuddyBundle(
  database: DatabaseSync,
  signal?: AbortSignal,
): Map<string, ParsedSource> {
  const sessions = readSessionRows(database);
  const contentMessages = new Set<string>();
  for (const row of batches(
    database,
    `SELECT rowid AS row_id, message_id, data FROM part WHERE rowid > ? ORDER BY rowid LIMIT ${BATCH_ROWS}`,
    signal,
  )) {
    const messageId = rowString(row.message_id);
    if (messageId && CONTENT_PART_TYPES.has(string(parseJson(row.data).type) ?? "")) {
      contentMessages.add(messageId);
    }
  }
  const stats = new Map<string, SessionStats>();
  for (const row of batches(
    database,
    `SELECT rowid AS row_id, id, session_id, data FROM message WHERE rowid > ? ORDER BY rowid LIMIT ${BATCH_ROWS}`,
    signal,
  )) {
    const id = rowString(row.id);
    const sessionId = rowString(row.session_id);
    if (!id || !sessionId || !contentMessages.has(id)) continue;
    const decoded = decodeMessage(row.data);
    if (!decoded) continue;
    let entry = stats.get(sessionId);
    if (!entry) {
      entry = { count: 0, model: null, usage: null, firstUserText: null };
      stats.set(sessionId, entry);
    }
    entry.count += 1;
    if (decoded.role === "assistant") {
      entry.model = decoded.model ?? entry.model;
      if (decoded.usage) entry.usage = addUsage(entry.usage, decoded.usage);
    }
  }
  const needsTitle = new Set(
    sessions
      .filter((session) => session.titleSource === "default" || !session.title.trim())
      .map((session) => session.id),
  );
  if (needsTitle.size > 0) {
    for (const row of batches(
      database,
      `SELECT part.rowid AS row_id, part.session_id, part.data
       FROM part JOIN message ON message.id = part.message_id
       WHERE part.rowid > ? AND json_extract(message.data, '$.role') = 'user'
         AND coalesce(json_extract(message.data, '$.synthetic'), 0) != 1
         AND json_extract(part.data, '$.type') = 'text'
       ORDER BY part.rowid LIMIT ${BATCH_ROWS}`,
      signal,
    )) {
      const sessionId = rowString(row.session_id);
      if (!sessionId || !needsTitle.has(sessionId)) continue;
      const text = string(parseJson(row.data).text);
      if (!text) continue;
      const entry = stats.get(sessionId) ?? {
        count: 0,
        model: null,
        usage: null,
        firstUserText: null,
      };
      entry.firstUserText ??= text;
      stats.set(sessionId, entry);
      needsTitle.delete(sessionId);
    }
  }
  const result = new Map<string, ParsedSource>();
  for (const session of sessions)
    result.set(session.id, parsedSource(session, stats.get(session.id), null));
  return result;
}

function orderKey(row: Row): [number, number, number] {
  const sequence = row.sequence;
  return [
    sequence === null || sequence === undefined ? Number.MAX_SAFE_INTEGER : rowNumber(sequence),
    rowNumber(row.time_created),
    rowNumber(row.row_id),
  ];
}

function compareRows(left: Row, right: Row): number {
  const a = orderKey(left);
  const b = orderKey(right);
  return a[0] - b[0] || a[1] - b[1] || a[2] - b[2];
}

/** Materializes one session's transcript in source order. */
export function readCcbuddyDetail(
  database: DatabaseSync,
  sessionId: string,
  signal?: AbortSignal,
): ParsedSource | null {
  const row = database.prepare("SELECT * FROM session WHERE id = ?").get(sessionId) as
    | Row
    | undefined;
  if (!row) return null;
  const session: SessionMeta = {
    id: sessionId,
    title: typeof row.title === "string" ? row.title : "",
    titleSource: rowString(row.title_source),
    directory: rowString(row.directory),
    parentId: rowString(row.parent_id),
    created: rowNumber(row.time_created),
    updated: rowNumber(row.time_updated),
  };
  const messages = (
    database
      .prepare("SELECT rowid AS row_id, * FROM message WHERE session_id = ?")
      .all(sessionId) as Row[]
  ).sort(compareRows);
  const partsByMessage = new Map<string, Row[]>();
  for (const part of database
    .prepare("SELECT rowid AS row_id, * FROM part WHERE session_id = ?")
    .all(sessionId) as Row[]) {
    const messageId = rowString(part.message_id);
    if (!messageId) continue;
    const list = partsByMessage.get(messageId) ?? [];
    list.push(part);
    partsByMessage.set(messageId, list);
  }
  const collector = new MessageCollector("detail");
  const stats: SessionStats = { count: 0, model: null, usage: null, firstUserText: null };
  messages.forEach((messageRow, index) => {
    if (signal?.aborted) throw new Error("History read cancelled");
    const decoded = decodeMessage(messageRow.data);
    const id = rowString(messageRow.id);
    if (!decoded || !id) return;
    const blocks = (partsByMessage.get(id) ?? [])
      .sort(compareRows)
      .flatMap((part) => partBlocks(parseJson(part.data)));
    const item = message(
      index + 1,
      decoded.hidden ? "system" : decoded.role,
      blocks,
      decoded.at ?? rowNumber(messageRow.time_created),
      decoded.model,
    );
    if (!item) return;
    if (decoded.usage) item.usage = decoded.usage;
    if (decoded.role === "assistant") stats.model = decoded.model ?? stats.model;
    collector.add(item);
  });
  return parsedSource(session, stats, collector);
}

function candidateId(path: string, sessionId: string): string {
  return `ccbuddy:${createHash("sha256").update(`${path}\0${sessionId}`).digest("hex").slice(0, 24)}`;
}

/** Turns the single database candidate into one candidate per session, filling the metadata cache on the way. */
export async function expandCcbuddyCandidates(
  base: Candidate,
  cache: CcbuddyMetadataCache,
  signal?: AbortSignal,
): Promise<Candidate[]> {
  const { result, stamp } = await withSqliteSnapshot(base, (database) =>
    buildCcbuddyBundle(database, signal),
  );
  cache.set({ path: base.path, fingerprint: stamp.fingerprint, sessions: result });
  return [...result.keys()].map((sessionId) => ({
    ...base,
    stamp,
    sessionId,
    relativePath: `${base.relativePath}#${sessionId}`,
    id: candidateId(base.path, sessionId),
  }));
}

export async function parseCcbuddy(
  candidate: Candidate,
  mode: "metadata" | "detail",
  cache: CcbuddyMetadataCache,
  signal?: AbortSignal,
): Promise<ParsedSource> {
  const sessionId = candidate.sessionId;
  if (!sessionId) throw new Error("CCbuddy history candidate has no session");
  if (mode === "metadata") {
    const before = await stampSqlite(candidate.path, candidate.root);
    let bundle = cache.get(candidate.path, before.fingerprint);
    if (!bundle) {
      const { result, stamp } = await withSqliteSnapshot(candidate, (database) =>
        buildCcbuddyBundle(database, signal),
      );
      bundle = { path: candidate.path, fingerprint: stamp.fingerprint, sessions: result };
      cache.set(bundle);
    }
    const parsed = bundle.sessions.get(sessionId);
    if (!parsed) throw new Error(`CCbuddy session ${sessionId} is no longer in the database`);
    return parsed;
  }
  const { result } = await withSqliteSnapshot(candidate, (database) =>
    readCcbuddyDetail(database, sessionId, signal),
  );
  if (!result) throw new Error(`CCbuddy session ${sessionId} is no longer in the database`);
  return result;
}
