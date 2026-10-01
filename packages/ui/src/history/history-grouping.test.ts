import assert from "node:assert/strict";
import test from "node:test";
import type { HistorySessionSummary } from "./contract.js";
import {
  distinctHistoryProjects,
  formatHistoryDuration,
  groupHistorySessions,
  relativeHistoryTime,
} from "./history-grouping.js";

const now = new Date(2026, 8, 30, 15, 0, 0).getTime();

function session(
  id: string,
  lastActivity: Date,
  overrides: Partial<HistorySessionSummary> = {},
): HistorySessionSummary {
  return {
    id,
    source: "claude",
    sessionId: id,
    title: id,
    project: "project",
    cwd: "/tmp/project",
    createdAt: lastActivity.toISOString(),
    lastActivity: lastActivity.toISOString(),
    messageCount: 1,
    model: null,
    parentSessionId: null,
    isSubagent: false,
    fingerprint: id,
    ...overrides,
  };
}

test("sessions group into today, yesterday, this week, this month and older months", () => {
  const groups = groupHistorySessions(
    [
      session("old", new Date(2026, 5, 2)),
      session("today", new Date(2026, 8, 30, 9)),
      session("yesterday", new Date(2026, 8, 29, 23)),
      session("week", new Date(2026, 8, 26)),
      session("month", new Date(2026, 8, 3)),
      session("older", new Date(2026, 6, 20)),
    ],
    "recent",
    now,
    "zh-CN",
  );
  assert.deepEqual(
    groups.map((group) => [group.label, group.sessions.map((item) => item.id)]),
    [
      ["今天", ["today"]],
      ["昨天", ["yesterday"]],
      ["本周", ["week"]],
      ["本月", ["month"]],
      ["2026年7月", ["older"]],
      ["2026年6月", ["old"]],
    ],
  );
});

test("sorting by creation time uses createdAt for both order and buckets", () => {
  const groups = groupHistorySessions(
    [
      session("a", new Date(2026, 8, 30, 10), { createdAt: new Date(2026, 8, 1).toISOString() }),
      session("b", new Date(2026, 8, 29), { createdAt: new Date(2026, 8, 30, 8).toISOString() }),
    ],
    "created",
    now,
    "en-US",
  );
  assert.deepEqual(
    groups.map((group) => [group.label, group.sessions.map((item) => item.id)]),
    [
      ["Today", ["b"]],
      ["This month", ["a"]],
    ],
  );
});

test("relative time stays short and falls back to a date after a week", () => {
  assert.equal(relativeHistoryTime(new Date(now - 30_000).toISOString(), now, "en-US"), "now");
  assert.equal(
    relativeHistoryTime(new Date(now - 5 * 60_000).toISOString(), now, "en-US"),
    "5 minutes ago",
  );
  assert.equal(
    relativeHistoryTime(new Date(now - 3 * 3_600_000).toISOString(), now, "zh-CN"),
    "3小时前",
  );
  assert.equal(relativeHistoryTime(new Date(2026, 7, 1).toISOString(), now, "en-US"), "Aug 1");
  assert.equal(relativeHistoryTime("not a date", now, "zh-CN"), "时间未知");
});

test("duration omits sub-minute spans and uses compact units", () => {
  assert.equal(
    formatHistoryDuration("2026-09-30T10:00:00Z", "2026-09-30T10:00:30Z", "en-US"),
    null,
  );
  assert.equal(
    formatHistoryDuration("2026-09-30T10:00:00Z", "2026-09-30T10:12:00Z", "en-US"),
    "12m",
  );
  assert.equal(
    formatHistoryDuration("2026-09-30T10:00:00Z", "2026-09-30T12:05:00Z", "en-US"),
    "2h 5m",
  );
  assert.equal(
    formatHistoryDuration("2026-09-28T10:00:00Z", "2026-09-30T10:00:00Z", "en-US"),
    "2d",
  );
});

test("distinct projects are ordered by how many sessions they hold", () => {
  const projects = distinctHistoryProjects([
    session("a", new Date(now), { project: "alpha" }),
    session("b", new Date(now), { project: "beta" }),
    session("c", new Date(now), { project: "beta" }),
    session("d", new Date(now), { project: "", cwd: null }),
  ]);
  assert.deepEqual(projects, ["beta", "alpha"]);
});
