import assert from "node:assert/strict";
import test from "node:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { HistorySessionDetail, HistorySessionSummary } from "./contract.js";
import { HistoryReader } from "./HistoryReader.js";

const summary: HistorySessionSummary = {
  id: "catalog-a",
  source: "codex",
  sessionId: "producer-a",
  title: "Before append",
  project: "project",
  cwd: "/project",
  createdAt: "2026-09-24T00:00:00.000Z",
  lastActivity: "2026-09-24T00:00:00.000Z",
  messageCount: 1,
  model: null,
  parentSessionId: null,
  isSubagent: false,
  fingerprint: "first-stamp",
};

const detail: HistorySessionDetail = {
  summary: {
    ...summary,
    title: "After append",
    messageCount: 2,
    fingerprint: "second-stamp",
  },
  messages: [
    {
      id: "message-1",
      sequence: 0,
      role: "user",
      timestamp: null,
      model: null,
      blocks: [{ type: "text", text: "First" }],
    },
    {
      id: "message-2",
      sequence: 1,
      role: "assistant",
      timestamp: null,
      model: null,
      blocks: [{ type: "text", text: "Second" }],
    },
  ],
  diagnostics: [],
};

test("reader accepts a newer detail for the same catalog session", () => {
  const html = renderToStaticMarkup(
    <HistoryReader summary={summary} detail={detail} locale="en-US" />,
  );
  assert.match(html, />After append<\/h2>/);
  assert.match(html, />2 messages</);
  assert.doesNotMatch(html, />Loading/);
});

test("reader hides an old detail while a newer request is pending", () => {
  const html = renderToStaticMarkup(
    <HistoryReader summary={summary} detail={detail} loading locale="en-US" />,
  );
  assert.match(html, />Before append<\/h2>/);
  assert.match(html, />1 messages</);
  assert.doesNotMatch(html, />After append<\/h2>/);
});

test("reader shows known token totals and omits unknown usage", () => {
  const known = renderToStaticMarkup(
    <HistoryReader
      summary={{
        ...summary,
        usage: { inputTokens: 1200, outputTokens: 450, cacheReadTokens: 300, cacheWriteTokens: 0 },
      }}
      detail={null}
      locale="en-US"
    />,
  );
  assert.match(known, /Token usage/);
  assert.match(known, /Input 1,200/);
  assert.match(known, /Output 450/);
  assert.match(known, /Cache read 300/);
  assert.doesNotMatch(known, /Cache write/);

  const unknown = renderToStaticMarkup(
    <HistoryReader summary={summary} detail={null} locale="en-US" />,
  );
  assert.doesNotMatch(unknown, /Token usage/);
});
