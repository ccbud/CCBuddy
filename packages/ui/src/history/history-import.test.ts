import assert from "node:assert/strict";
import test from "node:test";
import type { HistorySessionDetail } from "./contract.js";
import { buildHistoryImportMessages } from "./history-import.js";

function detail(messages: HistorySessionDetail["messages"]): HistorySessionDetail {
  return {
    summary: {
      id: "catalog-a",
      source: "codex",
      sessionId: "producer-a",
      title: "Fix build",
      project: "project",
      cwd: "/tmp/project",
      createdAt: "2026-09-24T00:00:00.000Z",
      lastActivity: "2026-09-24T01:00:00.000Z",
      messageCount: messages.length,
      model: null,
      parentSessionId: null,
      isSubagent: false,
      fingerprint: "stamp",
    },
    messages,
    diagnostics: [],
  };
}

test("tool calls fold into assistant turns, reasoning and context are dropped, same roles merge", () => {
  const plan = buildHistoryImportMessages(
    detail([
      {
        id: "1",
        sequence: 0,
        role: "system",
        timestamp: null,
        model: null,
        blocks: [{ type: "text", text: "hidden context" }],
      },
      {
        id: "2",
        sequence: 1,
        role: "user",
        timestamp: "2026-09-24T00:00:00.000Z",
        model: null,
        blocks: [{ type: "text", text: "Fix the build" }],
      },
      {
        id: "3",
        sequence: 2,
        role: "assistant",
        timestamp: "2026-09-24T00:01:00.000Z",
        model: null,
        blocks: [
          { type: "reasoning", text: "thinking hard" },
          { type: "tool_call", toolName: "Bash", toolCallId: "c1", input: { cmd: "pnpm build" } },
        ],
      },
      {
        id: "4",
        sequence: 3,
        role: "tool",
        timestamp: null,
        model: null,
        blocks: [{ type: "tool_result", toolCallId: "c1", output: "ok", isError: false }],
      },
      {
        id: "5",
        sequence: 4,
        role: "assistant",
        timestamp: null,
        model: null,
        blocks: [{ type: "text", text: "Done." }],
      },
    ]),
    { locale: "en-US" },
  );
  assert.equal(plan.omitted, 0);
  assert.deepEqual(
    plan.messages.map((message) => [message.role, message.content, message.timestamp]),
    [
      ["user", "Fix the build", Date.parse("2026-09-24T00:00:00.000Z")],
      [
        "assistant",
        "[Tool call: Bash]\ncmd: pnpm build\n\n[Tool result]\nok\n\nDone.",
        Date.parse("2026-09-24T00:01:00.000Z"),
      ],
    ],
  );
});

test("tool payloads are capped and the oldest turns are dropped first while keeping the task statement", () => {
  const long = "x".repeat(5_000);
  const plan = buildHistoryImportMessages(
    detail([
      {
        id: "1",
        sequence: 0,
        role: "user",
        timestamp: null,
        model: null,
        blocks: [{ type: "text", text: "Task" }],
      },
      {
        id: "2",
        sequence: 1,
        role: "assistant",
        timestamp: null,
        model: null,
        blocks: [{ type: "text", text: long }],
      },
      {
        id: "3",
        sequence: 2,
        role: "user",
        timestamp: null,
        model: null,
        blocks: [{ type: "text", text: "Follow-up" }],
      },
      {
        id: "4",
        sequence: 3,
        role: "assistant",
        timestamp: null,
        model: null,
        blocks: [{ type: "tool_result", toolCallId: null, output: long, isError: true }],
      },
    ]),
    { locale: "zh-CN", maxToolChars: 100, maxTotalChars: 3_000 },
  );
  assert.equal(plan.omitted, 1);
  // 丢掉中间的长回复后，两条用户消息合并成一轮，首条带省略说明。
  assert.deepEqual(
    plan.messages.map((message) => [message.role, message.content]),
    [
      ["user", "（导入自 Codex；较早的 1 条消息因篇幅省略）\n\nTask\n\nFollow-up"],
      ["assistant", `[工具失败]\n${"x".repeat(100)}…（已截断）`],
    ],
  );
});

test("Claude slash-command and IDE blocks never reach the imported transcript", () => {
  const plan = buildHistoryImportMessages(
    detail([
      {
        id: "1",
        sequence: 0,
        role: "user",
        timestamp: null,
        model: null,
        blocks: [
          {
            type: "text",
            text: "<command-name>/effort</command-name>\n<local-command-stdout>max</local-command-stdout>",
          },
        ],
      },
      {
        id: "2",
        sequence: 1,
        role: "user",
        timestamp: null,
        model: null,
        blocks: [{ type: "text", text: "<ide_opened_file>x.ts</ide_opened_file>\n拉取最新的代码" }],
      },
    ]),
    { locale: "zh-CN" },
  );
  assert.deepEqual(
    plan.messages.map((message) => [message.role, message.content]),
    [["user", "拉取最新的代码"]],
  );
});

test("an empty transcript yields no messages", () => {
  assert.deepEqual(buildHistoryImportMessages(detail([])), {
    messages: [],
    omitted: 0,
    totalChars: 0,
  });
});
