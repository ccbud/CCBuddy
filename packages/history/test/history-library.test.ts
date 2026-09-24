import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import {
  mkdtemp,
  mkdir,
  readFile,
  rename,
  rm,
  stat,
  symlink,
  utimes,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, before, test } from "node:test";
import {
  HistoryLibrary,
  parseHistoryRefreshEvent,
  parseHistorySessionDetail,
  parseHistorySnapshot,
} from "../src/module.ts";
import type { HistoryRoot } from "../src/contract.ts";
import { HistoryLibraryCore } from "../src/app/history-library.ts";
import type { HistorySourcePort } from "../src/app/source-adapter.ts";
import { FileHistorySourceRepository } from "../src/adapters/history-source-repository.ts";
import { defaultRoots } from "../src/adapters/discovery.ts";

let temporary = "";
let roots: HistoryRoot[] = [];

async function fixture(path: string, lines: unknown[]): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(
    path,
    `${lines.map((line) => (typeof line === "string" ? line : JSON.stringify(line))).join("\n")}\n`,
  );
}

function varint(value: number): number[] {
  const result: number[] = [];
  let remaining = value;
  while (remaining >= 128) {
    result.push((remaining & 0x7f) | 0x80);
    remaining = Math.floor(remaining / 128);
  }
  result.push(remaining);
  return result;
}

function field(number: number, bytes: Uint8Array): Uint8Array {
  return Uint8Array.from([...varint((number << 3) | 2), ...varint(bytes.length), ...bytes]);
}

function textField(number: number, text: string): Uint8Array {
  return field(number, Buffer.from(text));
}

before(async () => {
  temporary = await mkdtemp(join(tmpdir(), "ccbuddy-history-"));
  roots = (["claude", "codex", "qoder", "grok", "copilot", "antigravity"] as const).map(
    (source) => ({ source, path: join(temporary, source) }),
  );
  for (const root of roots) await mkdir(root.path, { recursive: true });
  await fixture(join(temporary, "claude", "-tmp-project", "claude-id.jsonl"), [
    {
      type: "user",
      sessionId: "claude-id",
      cwd: "/tmp/project",
      timestamp: "2026-09-24T08:00:00Z",
      message: { role: "user", content: "Review this code" },
    },
    "{bad json",
    {
      type: "assistant",
      sessionId: "claude-id",
      timestamp: "2026-09-24T08:01:00Z",
      message: {
        role: "assistant",
        model: "claude-test",
        usage: { input_tokens: 12, output_tokens: 5 },
        content: [
          { type: "text", text: "Reviewed" },
          { type: "tool_use", id: "call-1", name: "Read", input: { file_path: "a.ts" } },
        ],
      },
    },
  ]);
  await fixture(
    join(temporary, "claude", "-tmp-project", "claude-id", "subagents", "agent-child.jsonl"),
    [
      {
        type: "user",
        sessionId: "claude-id",
        agentId: "child",
        cwd: "/tmp/project",
        message: { role: "user", content: "Check tests" },
      },
    ],
  );
  await fixture(join(temporary, "qoder", "-tmp-qoder", "qoder-id.jsonl"), [
    { type: "attachment", attachment: { type: "queued_command", prompt: "Run tests" } },
    {
      type: "assistant",
      message: {
        id: "a1",
        role: "assistant",
        usage: { input_tokens: 4, output_tokens: 1 },
        content: [{ type: "text", text: "Tests " }],
      },
    },
    {
      type: "assistant",
      message: {
        id: "a1",
        role: "assistant",
        model: "qoder-model",
        usage: { input_tokens: 8, output_tokens: 2 },
        content: [{ type: "text", text: "passed" }],
      },
    },
  ]);
  await fixture(join(temporary, "codex", "2026", "09", "24", "rollout-id.jsonl"), [
    {
      type: "session_meta",
      timestamp: "2026-09-24T09:00:00Z",
      payload: { id: "codex-id", cwd: "/tmp/codex" },
    },
    { type: "turn_context", payload: { model: "gpt-test" } },
    {
      type: "response_item",
      timestamp: "2026-09-24T09:00:01Z",
      payload: {
        type: "message",
        role: "user",
        content: [{ type: "input_text", text: "Fix a bug" }],
      },
    },
    {
      type: "response_item",
      payload: {
        type: "function_call",
        name: "shell",
        call_id: "tool-1",
        arguments: '{"command":"pwd"}',
      },
    },
    {
      type: "response_item",
      payload: { type: "function_call_output", call_id: "tool-1", output: "/tmp/codex" },
    },
    {
      type: "response_item",
      payload: {
        type: "message",
        role: "assistant",
        content: [{ type: "output_text", text: "Fixed" }],
      },
    },
    {
      type: "event_msg",
      payload: {
        type: "token_count",
        info: {
          last_token_usage: {
            input_tokens: 100,
            output_tokens: 10,
            cached_input_tokens: 20,
          },
        },
      },
    },
  ]);
  await fixture(join(temporary, "codex", "2026", "09", "24", "rollout-child.jsonl"), [
    {
      type: "session_meta",
      payload: {
        id: "codex-child",
        parent_thread_id: "codex-id",
        source: { subagent: { thread_spawn: { parent_thread_id: "codex-id" } } },
        cwd: "/tmp/codex",
      },
    },
    {
      type: "response_item",
      payload: {
        type: "message",
        role: "user",
        content: [{ type: "input_text", text: "Inspect tests" }],
      },
    },
  ]);
  const grokDir = join(temporary, "grok", "%2Ftmp%2Fgrok", "grok-id");
  await fixture(join(grokDir, "chat_history.jsonl"), [
    { type: "user", content: "<user_info>noise</user_info>" },
    { type: "user", content: "<user_query>Build timeline</user_query>" },
    { type: "reasoning", summary: [{ text: "Plan steps" }] },
    {
      type: "assistant",
      content: "Done",
      tool_calls: [{ id: "g1", name: "Shell", arguments: { command: "pwd" } }],
    },
  ]);
  await writeFile(
    join(grokDir, "summary.json"),
    JSON.stringify({
      generated_title: "Grok title",
      current_model_id: "grok-test",
      info: { id: "grok-id", cwd: "/tmp/grok" },
    }),
  );
  const copilotDir = join(temporary, "copilot", "copilot-id");
  await fixture(join(copilotDir, "events.jsonl"), [
    { type: "session.start", data: { sessionId: "copilot-id", context: { cwd: "/tmp/copilot" } } },
    { type: "user.message", timestamp: "2026-09-24T10:00:00Z", data: { content: "Explain code" } },
    { type: "assistant.message", data: { content: "Here it is", model: "copilot-test" } },
    {
      type: "tool.execution_complete",
      data: { toolCallId: "c1", success: true, result: { content: "result" } },
    },
  ]);
  await writeFile(
    join(copilotDir, "workspace.yaml"),
    "name: Copilot workspace\ncwd: /tmp/copilot\n",
  );
  const db = new DatabaseSync(join(temporary, "antigravity", "anti-id.db"));
  db.exec("CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_payload BLOB NOT NULL)");
  db.prepare("INSERT INTO steps (idx, step_payload) VALUES (?, ?)").run(
    1,
    field(19, textField(2, "Antigravity prompt")),
  );
  db.prepare("INSERT INTO steps (idx, step_payload) VALUES (?, ?)").run(
    2,
    field(20, textField(1, "Antigravity answer")),
  );
  db.close();
});

after(async () => {
  if (temporary) await rm(temporary, { recursive: true, force: true });
});

test("discovers six producers, isolates malformed lines, and returns source-ordered details", async () => {
  const library = new HistoryLibrary({ roots });
  const events: unknown[] = [];
  const result = await library.refresh({ onEvent: (event) => events.push(event) });
  assert.equal(result.status, "success");
  assert.equal(events.filter((event) => (event as { type: string }).type === "terminal").length, 1);
  assert.equal(events.at(-1), result);
  const snapshot = parseHistorySnapshot(library.list());
  assert.equal(snapshot.sessions.length, 8);
  assert.deepEqual(
    new Set(snapshot.sessions.map((item) => item.source)),
    new Set(roots.map((root) => root.source)),
  );
  assert.equal(snapshot.complete, false);
  assert(snapshot.diagnostics.some((item) => item.code === "malformed_record" && item.line === 2));
  const parent = snapshot.sessions.find((item) => item.sessionId === "claude-id");
  const child = snapshot.sessions.find((item) => item.parentSessionId === parent?.id);
  assert(parent && child && child.isSubagent);
  const claude = parseHistorySessionDetail(await library.load(parent.id));
  assert.deepEqual(parent.usage, {
    inputTokens: 12,
    outputTokens: 5,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
  });
  assert.deepEqual(claude.summary.usage, parent.usage);
  assert.equal(claude.messages[0]?.blocks[0]?.type, "text");
  assert.equal(claude.messages[1]?.blocks[1]?.type, "tool_call");
  const codex = await library.load(
    snapshot.sessions.find((item) => item.sessionId === "codex-id")!.id,
  );
  assert.deepEqual(
    codex.messages.map((item) => item.role),
    ["user", "assistant", "tool", "assistant"],
  );
  assert.equal(codex.messages[1]?.blocks[0]?.type, "tool_call");
  assert.deepEqual(codex.summary.usage, {
    inputTokens: 80,
    outputTokens: 10,
    cacheReadTokens: 20,
    cacheWriteTokens: 0,
  });
  const codexParent = snapshot.sessions.find((item) => item.sessionId === "codex-id");
  const codexChild = snapshot.sessions.find((item) => item.sessionId === "codex-child");
  assert.equal(codexChild?.parentSessionId, codexParent?.id);
  const qoder = await library.load(snapshot.sessions.find((item) => item.source === "qoder")!.id);
  assert.equal(qoder.messages.length, 2);
  assert.equal(qoder.messages[1]?.blocks.length, 2);
  assert.deepEqual(qoder.summary.usage, {
    inputTokens: 8,
    outputTokens: 2,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
  });
  const grok = await library.load(snapshot.sessions.find((item) => item.source === "grok")!.id);
  assert.equal(grok.summary.title, "Grok title");
  assert.equal(grok.messages[0]?.blocks[0]?.type, "text");
  const grokSummaryPath = join(temporary, "grok", "%2Ftmp%2Fgrok", "grok-id", "summary.json");
  await writeFile(
    grokSummaryPath,
    JSON.stringify({ generated_title: "Updated Grok title", info: { id: "grok-id" } }),
  );
  const updatedGrok = await library.load(grok.summary.id);
  assert.equal(updatedGrok.summary.title, "Updated Grok title");
  assert.equal(
    library.list().sessions.find((item) => item.id === grok.summary.id)?.title,
    "Updated Grok title",
  );
  const copilot = await library.load(
    snapshot.sessions.find((item) => item.source === "copilot")!.id,
  );
  assert.equal(copilot.summary.title, "Copilot workspace");
  const antigravity = await library.load(
    snapshot.sessions.find((item) => item.source === "antigravity")!.id,
  );
  assert.deepEqual(
    antigravity.messages.map((item) => item.role),
    ["user", "assistant"],
  );
  assert.doesNotThrow(() => parseHistoryRefreshEvent(result));
});

test("catalog refresh streams metadata and detail rereads the transcript", async () => {
  const root = join(temporary, "large-copilot");
  const content = "x".repeat(2_048);
  const path = join(root, "many", "events.jsonl");
  await fixture(path, [
    ...Array.from({ length: 4_096 }, (_, index) => ({
      type: "user.message",
      data: { content: index === 0 ? "First prompt" : content },
    })),
    ...Array.from({ length: 300 }, () => "{bad json"),
  ]);
  class RecordingSource extends FileHistorySourceRepository {
    readonly modes: string[] = [];

    override async parse(
      candidate: Parameters<FileHistorySourceRepository["parse"]>[0],
      mode: Parameters<FileHistorySourceRepository["parse"]>[1],
      signal?: AbortSignal,
    ) {
      this.modes.push(mode);
      const result = await super.parse(candidate, mode, signal);
      if (mode === "metadata") assert.equal(result.parsed.messages.length, 0);
      return result;
    }
  }
  const source = new RecordingSource();
  const library = new HistoryLibraryCore([{ source: "copilot", path: root }], true, source);
  assert.equal((await library.refresh()).status, "success");
  assert.deepEqual(source.modes, ["metadata"]);
  assert.equal(library.list().diagnostics.length, 257);
  const summary = library.list().sessions[0];
  assert.equal(summary?.messageCount, 4_096);
  assert.equal(summary.title, "First prompt");
  const detail = await library.load(summary.id);
  assert.deepEqual(source.modes, ["metadata", "detail"]);
  assert.equal(detail.messages.length, 4_096);
  assert.equal(detail.summary.messageCount, summary.messageCount);
});

test("detects an atomic replacement even with equal size and mtime", async () => {
  const library = new HistoryLibrary({ roots });
  await library.refresh();
  const before = library
    .list()
    .sessions.find((item) => item.source === "claude" && !item.isSubagent)!;
  const path = join(temporary, "claude", "-tmp-project", "claude-id.jsonl");
  const old = await readFile(path);
  const oldStat = await import("node:fs/promises").then((fs) => fs.stat(path));
  const replacement = Buffer.from(old.toString().replace("Reviewed", "Reworked"));
  assert.equal(replacement.length, old.length);
  const staged = `${path}.replacement`;
  await writeFile(staged, replacement);
  await utimes(staged, oldStat.atime, oldStat.mtime);
  await rename(staged, path);
  const detail = await library.load(before.id);
  assert.notEqual(detail.summary.fingerprint, before.fingerprint);
  assert.equal(detail.summary.messageCount, before.messageCount);
  assert.equal(
    library.list().sessions.find((item) => item.id === before.id)?.fingerprint,
    detail.summary.fingerprint,
  );
  assert.equal(
    detail.messages[1]?.blocks[0]?.type === "text" ? detail.messages[1].blocks[0].text : "",
    "Reworked",
  );
});

test("reports unsafe paths and read failures without authorizing an empty library", async () => {
  const library = new HistoryLibrary({
    roots: [...roots, { source: "claude", path: join(temporary, "missing") }],
  });
  const escaped = join(temporary, "outside.jsonl");
  await writeFile(escaped, "{}\n");
  await symlink(escaped, join(temporary, "claude", "-tmp-project", "escaped.jsonl"));
  const result = await library.refresh();
  assert.equal(result.status, "error");
  assert.equal(result.snapshot.complete, false);
  assert(result.snapshot.sessions.length >= 6);
  assert(result.snapshot.diagnostics.some((item) => item.code === "unsafe_path"));
  assert(result.snapshot.diagnostics.some((item) => item.code === "unreadable_root"));
  // 父会话和子会话都属于 Codex；删除父会话文件时只应断言父会话读取失败。
  const codex = result.snapshot.sessions.find((item) => item.sessionId === "codex-id")!;
  await rm(join(temporary, "codex", "2026", "09", "24", "rollout-id.jsonl"));
  await assert.rejects(() => library.load(codex.id), /Cannot read history session/);
});

test("runtime validators reject wrong protocol versions and malformed detail", () => {
  assert.throws(() =>
    parseHistorySnapshot({
      protocolVersion: 2,
      version: 1,
      sessions: [],
      diagnostics: [],
      complete: true,
    }),
  );
  assert.throws(() => parseHistorySessionDetail({ summary: {}, messages: [], diagnostics: [] }));
});

test("a missing root preserves the last visible snapshot and returns an error terminal", async () => {
  const root = join(temporary, "transient-root");
  await fixture(join(root, "-tmp-review", "session.jsonl"), [
    {
      type: "user",
      sessionId: "session",
      message: { role: "user", content: "Persist visibility" },
    },
  ]);
  const library = new HistoryLibrary({ roots: [{ source: "claude", path: root }] });
  assert.equal((await library.refresh()).status, "success");
  const visible = library.list().sessions[0];
  assert(visible);
  await rename(root, `${root}-moved`);
  const result = await library.refresh();
  assert.equal(result.status, "error");
  assert.equal(result.snapshot.complete, false);
  assert.equal(result.snapshot.sessions[0]?.id, visible.id);
});

test("superseded refresh cannot publish its older generation", async () => {
  let releaseFirst: ((value: { candidates: []; diagnostics: [] }) => void) | undefined;
  let calls = 0;
  const port: HistorySourcePort = {
    discover: () => {
      calls += 1;
      return calls === 1
        ? new Promise((resolve) => {
            releaseFirst = resolve;
          })
        : Promise.resolve({ candidates: [], diagnostics: [] });
    },
    parse: async () => {
      throw new Error("Older generation parsed after supersession");
    },
    stamp: async () => {
      throw new Error("No files in this test");
    },
  };
  const library = new HistoryLibraryCore([], true, port);
  const firstEvents: string[] = [];
  const first = library.refresh({ onEvent: (event) => firstEvents.push(event.type) });
  const second = await library.refresh();
  releaseFirst?.({ candidates: [], diagnostics: [] });
  const old = await first;
  assert.equal(second.status, "success");
  assert.equal(old.status, "cancelled");
  assert.deepEqual(firstEvents, ["terminal"]);
  assert.equal(library.list().version, second.snapshot.version);
});

test("Grok updates-only sessions replay chunks and completed tools without writing a chat cache", async () => {
  const root = join(temporary, "grok-updates-only");
  const session = join(root, "%2Ftmp%2Fupdates", "stream-id");
  const updatesPath = join(session, "updates.jsonl");
  const update = (sessionUpdate: Record<string, unknown>, timestamp: number) => ({
    timestamp,
    method: "session/update",
    params: { sessionId: "stream-id", update: sessionUpdate },
  });
  await fixture(updatesPath, [
    update({ sessionUpdate: "user_message_chunk", content: { type: "text", text: "Build " } }, 1),
    update({ sessionUpdate: "user_message_chunk", content: { type: "text", text: "timeline" } }, 2),
    update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Plan" } }, 3),
    update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Working" } }, 4),
    update(
      {
        sessionUpdate: "tool_call",
        toolCallId: "tc-1",
        title: "Read file",
        rawInput: { path: "a.ts" },
      },
      5,
    ),
    update(
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "tc-1",
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: "file contents" } }],
      },
      6,
    ),
    update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Done" } }, 7),
    update({ sessionUpdate: "user_message_chunk", content: { type: "text", text: "Thanks" } }, 8),
  ]);
  await writeFile(
    join(session, "summary.json"),
    JSON.stringify({
      current_model_id: "grok-test",
      info: { id: "stream-id", cwd: "/tmp/updates" },
    }),
  );
  const library = new HistoryLibrary({ roots: [{ source: "grok", path: root }] });
  assert.equal((await library.refresh()).status, "success");
  const summary = library.list().sessions[0];
  assert.equal(summary.sessionId, "stream-id");
  assert.equal(summary.title, "Build timeline");
  assert.equal(summary.messageCount, 5);
  const detail = await library.load(summary.id);
  assert.deepEqual(
    detail.messages.map((item) => item.role),
    ["user", "assistant", "tool", "assistant", "user"],
  );
  assert.deepEqual(detail.messages[0]?.blocks, [{ type: "text", text: "Build timeline" }]);
  assert.deepEqual(detail.messages[1]?.blocks, [
    { type: "reasoning", text: "Plan" },
    { type: "text", text: "Working" },
    { type: "tool_call", toolName: "Read file", toolCallId: "tc-1", input: { path: "a.ts" } },
  ]);
  assert.deepEqual(detail.messages[2]?.blocks, [
    { type: "tool_result", toolCallId: "tc-1", output: "file contents", isError: false },
  ]);
  assert.equal(detail.summary.messageCount, summary.messageCount);
  await assert.rejects(() => stat(join(session, "chat_history.jsonl")), { code: "ENOENT" });
});

test("Grok prefers chat history over updates and rejects unsupported replay controls", async () => {
  const root = join(temporary, "grok-preference");
  const session = join(root, "%2Ftmp%2Ftwo", "two-files");
  await fixture(join(session, "chat_history.jsonl"), [
    { type: "user", content: "Derived conversation" },
  ]);
  await fixture(join(session, "updates.jsonl"), [
    {
      timestamp: 1,
      method: "session/update",
      params: {
        sessionId: "two-files",
        update: { sessionUpdate: "user_message_chunk", content: { type: "text", text: "Raw" } },
      },
    },
  ]);
  const control = join(root, "%2Ftmp%2Fcontrol", "control-id");
  await fixture(join(control, "updates.jsonl"), [
    {
      timestamp: 1,
      method: "_x.ai/session/update",
      params: {
        sessionId: "control-id",
        update: { sessionUpdate: "rewind_marker", target_prompt_index: 0 },
      },
    },
  ]);
  const compacted = join(root, "%2Ftmp%2Fcompacted", "compacted-id");
  await fixture(join(compacted, "updates.jsonl"), [
    {
      timestamp: 1,
      method: "_x.ai/session/update",
      params: {
        sessionId: "compacted-id",
        update: { sessionUpdate: "compaction_checkpoint", checkpoint_id: "checkpoint-1" },
      },
    },
  ]);
  const library = new HistoryLibrary({ roots: [{ source: "grok", path: root }] });
  const result = await library.refresh();
  assert.equal(result.status, "error");
  assert.equal(result.snapshot.sessions.length, 1);
  assert.equal(result.snapshot.sessions[0]?.messageCount, 1);
  assert.equal(
    (await library.load(result.snapshot.sessions[0]!.id)).messages[0]?.blocks[0]?.type,
    "text",
  );
  assert(result.snapshot.diagnostics.some((item) => item.message.includes("rewind_marker")));
  assert(
    result.snapshot.diagnostics.some((item) => item.message.includes("compaction_checkpoint")),
  );
});

test("SQLite WAL-only writes change the Antigravity source fingerprint", async () => {
  const root = join(temporary, "antigravity-wal");
  await mkdir(root, { recursive: true });
  const path = join(root, "wal-session.db");
  const db = new DatabaseSync(path);
  try {
    db.exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0");
    db.exec("CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_payload BLOB NOT NULL)");
    const insert = db.prepare("INSERT INTO steps (idx, step_payload) VALUES (?, ?)");
    insert.run(1, field(19, textField(2, "First prompt")));
    const library = new HistoryLibrary({ roots: [{ source: "antigravity", path: root }] });
    assert.equal((await library.refresh()).status, "success");
    const before = library.list().sessions[0]!;
    const mainBefore = await stat(path, { bigint: true });
    insert.run(2, field(20, textField(1, "Second answer")));
    const mainAfter = await stat(path, { bigint: true });
    assert.equal(mainAfter.size, mainBefore.size);
    assert.equal(mainAfter.mtimeNs, mainBefore.mtimeNs);
    assert.equal((await library.refresh()).status, "success");
    const after = library.list().sessions[0]!;
    assert.notEqual(after.fingerprint, before.fingerprint);
    assert.equal(after.messageCount, 2);
  } finally {
    db.close();
  }
});

test("default history roots honor producer homes and discover archived Codex and Qoder workspaces", async () => {
  const home = join(temporary, "configured-home");
  const codexHome = join(temporary, "custom-codex-home");
  const grokHome = join(temporary, "custom-grok-home");
  const xdgHome = join(temporary, "custom-xdg-home");
  const configured = defaultRoots(home, {
    CODEX_HOME: codexHome,
    GROK_HOME: grokHome,
    XDG_CONFIG_HOME: xdgHome,
  });
  assert(
    configured.some(
      (root) => root.source === "codex" && root.path === join(codexHome, "archived_sessions"),
    ),
  );
  assert(
    configured.some((root) => root.source === "grok" && root.path === join(grokHome, "sessions")),
  );
  assert(
    configured.some(
      (root) => root.source === "claude" && root.path === join(xdgHome, "claude", "projects"),
    ),
  );
  assert(
    configured.some(
      (root) => root.source === "qoder" && root.path === join(home, ".qoderwork", "projects"),
    ),
  );
  await fixture(join(codexHome, "archived_sessions", "rollout-archived.jsonl"), [
    { type: "session_meta", payload: { id: "archived-id" } },
    {
      type: "response_item",
      payload: {
        type: "message",
        role: "user",
        content: [{ type: "input_text", text: "Archived" }],
      },
    },
  ]);
  await fixture(join(home, ".qoderwork", "projects", "-tmp", "work-id.jsonl"), [
    { type: "user", message: { role: "user", content: "Qoder work" } },
  ]);
  const library = new HistoryLibrary({
    roots: configured.filter(
      (root) =>
        root.path === join(codexHome, "archived_sessions") ||
        root.path === join(home, ".qoderwork", "projects"),
    ),
  });
  const result = await library.refresh();
  assert.equal(result.status, "success");
  assert.deepEqual(
    new Set(result.snapshot.sessions.map((item) => item.source)),
    new Set(["codex", "qoder"]),
  );
});
