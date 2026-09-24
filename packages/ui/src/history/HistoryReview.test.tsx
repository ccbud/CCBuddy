import assert from "node:assert/strict";
import test from "node:test";
import { renderToStaticMarkup } from "react-dom/server";
import { HistoryReview } from "./HistoryReview.js";
import type { HistorySnapshot } from "./contract.js";

const snapshot: HistorySnapshot = {
  protocolVersion: 1,
  version: 1,
  sessions: [],
  diagnostics: [],
  complete: true,
};

test("history navigation selects the requested calendar or session list view", () => {
  const common = {
    snapshot,
    selectedSessionId: null,
    detail: null,
    onSelectSession: () => {},
    onViewChange: () => {},
    locale: "zh-CN" as const,
  };
  const calendar = renderToStaticMarkup(<HistoryReview {...common} view="timeline" />);
  const sessions = renderToStaticMarkup(<HistoryReview {...common} view="list" />);

  assert.match(calendar, /data-testid="history-timeline-scroll"/);
  assert.doesNotMatch(calendar, /aria-label="按标题、项目或路径筛选"/);
  assert.match(sessions, /aria-label="按标题、项目或路径筛选"/);
  assert.doesNotMatch(sessions, /data-testid="history-timeline-scroll"/);
});
