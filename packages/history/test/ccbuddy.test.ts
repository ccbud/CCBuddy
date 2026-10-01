import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, before, test } from "node:test";
import { HistoryLibrary, parseHistorySnapshot } from "../src/module.ts";
import { partBlocks } from "../src/adapters/ccbuddy-parts.ts";
import { defaultRoots, detectClaudeProfileRoots } from "../src/adapters/discovery.ts";

let home = "";

async function claudeFixture(path: string, sessionId: string, text: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(
    path,
    `${JSON.stringify({
      type: "user",
      sessionId,
      cwd: "/tmp/project",
      timestamp: "2026-09-24T08:00:00Z",
      message: { role: "user", content: text },
    })}\n`,
  );
}

function createSessionDatabase(path: string): void {
  const database = new DatabaseSync(path);
  database.exec(`
    CREATE TABLE session (
      id text primary key, project_id text not null, workspace_id text, parent_id text,
      slug text not null, directory text not null, path text, title text not null,
      version text not null, time_created integer not null, time_updated integer not null,
      task_type text not null default 'interactive', title_source text not null default 'first_input'
    );
    CREATE TABLE message (
      id text primary key, session_id text not null, time_created integer not null,
      time_updated integer not null, data text not null, sequence integer
    );
    CREATE TABLE part (
      id text primary key, message_id text not null, session_id text not null,
      time_created integer not null, time_updated integer not null, data text not null, sequence integer
    );
  `);
  const session = database.prepare(
    "INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, task_type, title_source) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
  );
  session.run(
    "sess_a",
    "proj",
    null,
    "a",
    "/tmp/project",
    "New session",
    "1",
    1_000,
    5_000,
    "interactive",
    "default",
  );
  session.run(
    "sess_b",
    "proj",
    "sess_a",
    "b",
    "/tmp/project",
    "Explore repo",
    "1",
    2_000,
    3_000,
    "subagent",
    "generated",
  );
  const message = database.prepare(
    "INSERT INTO message (id, session_id, time_created, time_updated, data, sequence) VALUES (?, ?, ?, ?, ?, ?)",
  );
  const part = database.prepare(
    "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data, sequence) VALUES (?, ?, ?, ?, ?, ?, ?)",
  );
  message.run(
    "msg_1",
    "sess_a",
    1_000,
    1_000,
    JSON.stringify({ role: "user", time: { created: 1_000 } }),
    0,
  );
  part.run(
    "part_1",
    "msg_1",
    "sess_a",
    1_000,
    1_000,
    JSON.stringify({ type: "text", text: "Fix the login bug" }),
    0,
  );
  message.run(
    "msg_2",
    "sess_a",
    1_500,
    2_000,
    JSON.stringify({
      role: "assistant",
      time: { created: 1_500, completed: 2_000 },
      modelId: "glm-5",
      tokens: { input: 120, output: 30, cache: { read: 10, write: 5 } },
    }),
    1,
  );
  part.run("part_2", "msg_2", "sess_a", 1_500, 1_500, JSON.stringify({ type: "step-start" }), 0);
  part.run(
    "part_3",
    "msg_2",
    "sess_a",
    1_501,
    1_501,
    JSON.stringify({ type: "reasoning", text: "Check the auth middleware" }),
    1,
  );
  part.run(
    "part_4",
    "msg_2",
    "sess_a",
    1_502,
    1_502,
    JSON.stringify({
      type: "tool",
      callID: "call_1",
      tool: "Read",
      state: {
        status: "completed",
        input: { path: "auth.ts" },
        output: "export const auth = 1",
        title: "auth.ts",
      },
    }),
    2,
  );
  part.run(
    "part_5",
    "msg_2",
    "sess_a",
    1_503,
    1_503,
    JSON.stringify({ type: "text", text: "The middleware drops the token." }),
    3,
  );
  message.run(
    "msg_3",
    "sess_a",
    3_000,
    3_000,
    JSON.stringify({
      role: "user",
      time: { created: 3_000 },
      synthetic: true,
      visibility: "model-only",
    }),
    2,
  );
  part.run(
    "part_6",
    "msg_3",
    "sess_a",
    3_000,
    3_000,
    JSON.stringify({ type: "text", text: "<shared context>" }),
    0,
  );
  message.run(
    "msg_4",
    "sess_b",
    2_000,
    2_000,
    JSON.stringify({ role: "user", time: { created: 2_000 } }),
    0,
  );
  part.run(
    "part_7",
    "msg_4",
    "sess_b",
    2_000,
    2_000,
    JSON.stringify({ type: "text", text: "List the routes" }),
    0,
  );
  database.close();
}

before(async () => {
  home = await mkdtemp(join(tmpdir(), "ccbuddy-history-home-"));
  const databaseDirectory = join(home, ".ccbuddy", "cli", "db");
  await mkdir(databaseDirectory, { recursive: true });
  createSessionDatabase(join(databaseDirectory, "db.sqlite"));
  await claudeFixture(
    join(home, ".claude-config", "work", "projects", "-tmp-project", "profile-session.jsonl"),
    "profile-session",
    "From the work profile",
  );
  await claudeFixture(
    join(home, ".claude-env", "projects", "-tmp-project", "env-session.jsonl"),
    "env-session",
    "From CLAUDE_CONFIG_DIR",
  );
  await claudeFixture(
    join(home, "custom-root", "-tmp-project", "custom-session.jsonl"),
    "custom-session",
    "From a custom root",
  );
});

after(async () => {
  await rm(home, { recursive: true, force: true });
});

test("default roots include CCbuddy's own database and CLAUDE_CONFIG_DIR", () => {
  const roots = defaultRoots(home, { CLAUDE_CONFIG_DIR: join(home, ".claude-env") });
  assert.deepEqual(roots[0], {
    source: "ccbuddy",
    path: join(home, ".ccbuddy", "cli", "db"),
    origin: "default",
  });
  assert(
    roots.some(
      (root) =>
        root.source === "claude" &&
        root.origin === "environment" &&
        root.path === join(home, ".claude-env", "projects"),
    ),
  );
});

test("Claude profile directories beside ~/.claude are detected", async () => {
  const roots = await detectClaudeProfileRoots(home);
  assert.deepEqual(
    new Set(roots.map((root) => root.path)),
    new Set([
      join(home, ".claude-config", "work", "projects"),
      join(home, ".claude-env", "projects"),
    ]),
  );
  assert(roots.every((root) => root.origin === "profile"));
});

test("CCbuddy sessions, Claude profiles and custom roots appear in one catalog", async () => {
  const library = new HistoryLibrary({
    homeDirectory: home,
    environment: { CLAUDE_CONFIG_DIR: join(home, ".claude-env") },
    extraRoots: () => [{ source: "claude", path: join(home, "custom-root") }],
  });
  const result = await library.refresh();
  assert.equal(result.status, "success");
  const snapshot = parseHistorySnapshot(result.snapshot);
  assert.deepEqual(
    new Set(snapshot.sessions.map((session) => `${session.source}:${session.sessionId}`)),
    new Set([
      "ccbuddy:sess_a",
      "ccbuddy:sess_b",
      "claude:profile-session",
      "claude:env-session",
      "claude:custom-session",
    ]),
  );
  const roots = new Map(snapshot.roots.map((root) => [root.path, root]));
  assert.equal(roots.get(join(home, ".ccbuddy", "cli", "db"))?.available, true);
  assert.equal(roots.get(join(home, ".claude", "projects"))?.available, false);
  // 环境变量先于目录探测登记，同一目录只保留一条且来源是 environment。
  assert.equal(roots.get(join(home, ".claude-env", "projects"))?.origin, "environment");
  assert.equal(roots.get(join(home, ".claude-config", "work", "projects"))?.origin, "profile");
  assert.equal(roots.get(join(home, "custom-root"))?.origin, "custom");

  const parent = snapshot.sessions.find((session) => session.sessionId === "sess_a");
  const child = snapshot.sessions.find((session) => session.sessionId === "sess_b");
  assert(parent && child);
  assert.equal(parent.title, "Fix the login bug");
  assert.equal(parent.project, "project");
  assert.equal(parent.cwd, "/tmp/project");
  assert.equal(parent.model, "glm-5");
  assert.equal(parent.messageCount, 3);
  assert.deepEqual(parent.usage, {
    inputTokens: 120,
    outputTokens: 30,
    cacheReadTokens: 10,
    cacheWriteTokens: 5,
  });
  assert.equal(parent.createdAt, new Date(1_000).toISOString());
  assert.equal(parent.lastActivity, new Date(5_000).toISOString());
  assert.equal(child.title, "Explore repo");
  assert.equal(child.isSubagent, true);
  assert.equal(child.parentSessionId, parent.id);

  const detail = await library.load(parent.id);
  assert.deepEqual(
    detail.messages.map((message) => [message.role, message.blocks.map((block) => block.type)]),
    [
      ["user", ["text"]],
      ["assistant", ["reasoning", "tool_call", "tool_result", "text"]],
      ["system", ["text"]],
    ],
  );
  assert.equal(detail.messages[1]?.model, "glm-5");
  assert.deepEqual(detail.messages[1]?.usage, parent.usage);
  const toolCall = detail.messages[1]?.blocks[1];
  assert(toolCall?.type === "tool_call");
  assert.equal(toolCall.toolName, "Read");
  assert.deepEqual(toolCall.input, { path: "auth.ts" });
});

test("titles skip Claude's slash-command and IDE control blocks", async () => {
  const { visibleUserText, firstUserTitle } = await import("../src/domain/value.ts");
  assert.equal(
    visibleUserText(
      "<command-name>/effort</command-name>\n<command-message>effort</command-message>\n<local-command-stdout>Set effort</local-command-stdout>",
    ),
    "",
  );
  assert.equal(
    firstUserTitle([
      {
        id: "1",
        sequence: 1,
        role: "user",
        timestamp: null,
        model: null,
        blocks: [{ type: "text", text: "<command-name>/effort</command-name>" }],
      },
      {
        id: "2",
        sequence: 2,
        role: "user",
        timestamp: null,
        model: null,
        blocks: [
          {
            type: "text",
            text: "<ide_opened_file>a.ts</ide_opened_file>\n忽略本地变更 拉取最新的代码",
          },
        ],
      },
    ]),
    "忽略本地变更 拉取最新的代码",
  );
});

test("agent parts map to reader blocks and bookkeeping parts are skipped", () => {
  assert.deepEqual(
    partBlocks({
      type: "tool",
      callID: "c1",
      tool: "Bash",
      state: { status: "error", input: { cmd: "ls" }, error: "boom" },
    }),
    [
      { type: "tool_call", toolName: "Bash", toolCallId: "c1", input: { cmd: "ls" } },
      { type: "tool_result", toolCallId: "c1", output: "boom", isError: true },
    ],
  );
  assert.deepEqual(partBlocks({ type: "file", url: "data:image/png;base64,AAAA" }), [
    { type: "image", dataUrl: "data:image/png;base64,AAAA" },
  ]);
  assert.deepEqual(partBlocks({ type: "snapshot", snapshot: "abc" }), []);
  assert.deepEqual(partBlocks({ type: "subtask", description: "Scan tests", prompt: "..." }), [
    { type: "text", text: "[subtask] Scan tests" },
  ]);
});
