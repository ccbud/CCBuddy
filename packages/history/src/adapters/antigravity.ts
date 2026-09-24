import { constants } from "node:fs";
import { mkdtemp, open, rm } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { basename, extname, join } from "node:path";
import type { HistoryContentBlock } from "../contract.js";
import type { ParsedSource } from "../app/source-adapter.js";
import { MessageCollector } from "../domain/message-collector.js";
import { message, string } from "../domain/value.js";
import { type Candidate, openVerified, stamp, stampSqlite } from "./discovery.js";
import { WireMessage } from "./antigravity-wire.js";

// Desktop's bundler rewrites a direct node:sqlite import to a bare sqlite import.
// Loading through require preserves the built-in protocol in the Electron main bundle.
const { DatabaseSync } = createRequire(import.meta.url)(
  "node:sqlite",
) as typeof import("node:sqlite");

function toolName(name: string): string {
  const mapping: Record<string, string> = {
    run_command: "Bash",
    view_file: "Read",
    list_dir: "LS",
    grep_search: "Grep",
    find_by_name: "Glob",
    replace_file_content: "Edit",
    write_to_file: "Write",
    read_url_content: "WebFetch",
    search_web: "WebSearch",
  };
  return mapping[name] ?? name;
}

function normalizeStep(step: WireMessage, number: number): ParsedSource["messages"] {
  const metadata = step.child(5);
  const at = metadata?.timestamp(1);
  const user = step.child(19);
  if (user) {
    const blocks: HistoryContentBlock[] = [];
    const text = string(user.text(2));
    if (text) blocks.push({ type: "text", text });
    for (const attachment of user.children(9)) {
      const mime = attachment.text(1) ?? "";
      const bytes = attachment.bytes(2);
      if (mime.startsWith("image/") && bytes && bytes.byteLength <= 8_000_000) {
        blocks.push({
          type: "image",
          dataUrl: `data:${mime};base64,${Buffer.from(bytes).toString("base64")}`,
        });
      } else if (attachment.text(5)) {
        blocks.push({ type: "text", text: `[attachment: ${attachment.text(5)}]` });
      }
    }
    const result = message(number, "user", blocks, at);
    return result ? [result] : [];
  }
  const tool = metadata?.child(4);
  if (tool) {
    let input: unknown = null;
    const raw = tool.text(3);
    if (raw) {
      try {
        input = JSON.parse(raw) as unknown;
      } catch {
        input = raw;
      }
    }
    const result = message(
      number,
      "assistant",
      [
        {
          type: "tool_call",
          toolName: toolName(tool.text(2) ?? "tool"),
          toolCallId: tool.text(1),
          input,
        },
      ],
      at,
    );
    return result ? [result] : [];
  }
  const answer = step.child(20);
  const text = string(answer?.text(1)) ?? string(answer?.text(8));
  const result = message(number, "assistant", text ? [{ type: "text", text }] : [], at);
  const stats = metadata?.child(9);
  if (result && stats) {
    result.usage = {
      inputTokens: Number(stats.number(2) ?? 0n),
      outputTokens: Number(stats.number(3) ?? 0n),
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
    };
  }
  return result ? [result] : [];
}

export async function parseAntigravity(
  candidate: Candidate,
  mode: "metadata" | "detail",
  signal?: AbortSignal,
): Promise<ParsedSource> {
  const before = await stampSqlite(candidate.path, candidate.root);
  const privateDirectory = await mkdtemp(join(tmpdir(), "ccbuddy-history-db-"));
  const collector = new MessageCollector(mode);
  let firstAt: string | null = null;
  let lastAt: string | null = null;
  try {
    const snapshot = join(privateDirectory, "source.db");
    await copyVerified(candidate, snapshot);
    for (const suffix of ["-wal", "-shm"]) {
      const original = { ...candidate, path: `${candidate.path}${suffix}` };
      try {
        await copyVerified(original, `${snapshot}${suffix}`);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
    }
    // SQLite sees only private bytes copied through verified file descriptors. Never hand it a
    // producer path that could be swapped for a symlink between validation and open.
    const database = new DatabaseSync(snapshot);
    try {
      const statement = database.prepare(
        "SELECT idx, step_payload FROM steps WHERE idx > ? ORDER BY idx LIMIT 128",
      );
      let cursor = -9_223_372_036_854_775_808n;
      while (true) {
        if (signal?.aborted) throw new Error("History read cancelled");
        const rows = statement.all(cursor);
        if (rows.length === 0) break;
        for (const row of rows) {
          const index = BigInt(row.idx as number | bigint);
          cursor = index;
          const payload = row.step_payload;
          if (!(payload instanceof Uint8Array)) continue;
          const step = WireMessage.decode(payload);
          if (!step) continue;
          for (const item of normalizeStep(step, Number(index) || collector.count + 1)) {
            firstAt ??= item.timestamp;
            lastAt = item.timestamp ?? lastAt;
            collector.add(item);
          }
        }
        await new Promise<void>((resolve) => setImmediate(resolve));
      }
    } finally {
      database.close();
    }
  } finally {
    await rm(privateDirectory, { recursive: true, force: true });
  }
  const after = await stampSqlite(candidate.path, candidate.root);
  if (after.fingerprint !== before.fingerprint) throw new Error("Source changed during read");
  return {
    sessionId: basename(candidate.path, extname(candidate.path)),
    title: collector.title,
    cwd: null,
    model: null,
    parentSessionId: null,
    isSubagent: false,
    createdAt: firstAt,
    lastActivity: lastAt,
    messages: collector.messages,
    messageCount: collector.count,
    usage: collector.usage,
  };
}

async function copyVerified(candidate: Candidate, destination: string): Promise<void> {
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
