import assert from "node:assert/strict";
import test from "node:test";
import type { HistoryMessage } from "./contract.js";
import {
  findMatchingMessages,
  formatHistoryPayload,
  highlightSegments,
  looksLikePatch,
  matchExcerpt,
} from "./reader-utils.js";

test("multiline patch inputs keep source lines and diff markers", () => {
  const patch = "*** Begin Patch\n*** Update File: a.ts\n@@\n-old\n+new\n*** End Patch";
  const formatted = formatHistoryPayload({ patch, metadata: { cwd: "/work" } });
  assert.match(formatted, /patch:\n  \*\*\* Begin Patch\n  \*\*\* Update File/);
  assert.match(formatted, /\n  -old\n  \+new\n/);
  assert.equal(formatted.includes("\\n"), false);
  assert.equal(looksLikePatch(formatted), true);
  const circular: Record<string, unknown> = {};
  circular.self = circular;
  assert.equal(formatHistoryPayload(circular), "self: [Circular]");
});

test("search finds matching messages across text, reasoning, and tool payloads", () => {
  const messages: HistoryMessage[] = [
    {
      id: "one",
      sequence: 0,
      role: "user",
      timestamp: null,
      model: null,
      blocks: [{ type: "text", text: "修复故障" }],
    },
    {
      id: "two",
      sequence: 1,
      role: "assistant",
      timestamp: null,
      model: null,
      blocks: [{ type: "reasoning", text: "检查配置" }],
    },
    {
      id: "three",
      sequence: 2,
      role: "assistant",
      timestamp: null,
      model: null,
      blocks: [
        {
          type: "tool_call",
          toolName: "apply_patch",
          toolCallId: null,
          input: { patch: "+修复测试" },
        },
      ],
    },
    {
      id: "four",
      sequence: 3,
      role: "tool",
      timestamp: null,
      model: null,
      blocks: [{ type: "image", dataUrl: "data:image/png;base64,AA==" }],
    },
  ];
  assert.deepEqual(findMatchingMessages(messages, "修复", "zh-CN"), [0, 2]);
  assert.deepEqual(findMatchingMessages(messages, "配置", "zh-CN"), [1]);
  assert.deepEqual(findMatchingMessages(messages, "not-found", "en-US"), []);
  assert.deepEqual(findMatchingMessages(messages, "  ", "zh-CN"), []);
  assert.deepEqual(
    highlightSegments("Fix it, fix again", "fix", "en-US").filter((segment) => segment.match),
    [
      { text: "Fix", match: true },
      { text: "fix", match: true },
    ],
  );
});

test("search exposes a bounded excerpt for a hit beyond the initial text prefix", () => {
  const long = `${"a".repeat(20_000)}needle${"b".repeat(20_000)}`;
  const excerpt = matchExcerpt(long, "needle", "en-US", 16_000);
  assert.ok(excerpt?.includes("needle"));
  assert.ok((excerpt?.length ?? 0) < 500);
  assert.equal(matchExcerpt(long, "missing", "en-US", 16_000), null);
});
