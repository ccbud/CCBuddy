import assert from "node:assert/strict";
import test from "node:test";
import type { HistorySessionSummary } from "./contract.js";
import {
  buildTimelineGroups,
  createTimelineWindow,
  hitTestTimelineEntry,
  selectTimelineTicks,
  shiftTimelineWindow,
  timelineBar,
  timelineTicks,
  zoomTimelineWindow,
} from "./timeline-layout.js";

const instant = (value: string) => Date.parse(value);
const august = { start: instant("2026-08-01T00:00:00Z"), end: instant("2026-08-11T00:00:00Z") };

function session(
  id: string,
  source: HistorySessionSummary["source"],
  cwd: string | null,
  createdAt: string,
  lastActivity: string,
): HistorySessionSummary {
  return {
    id,
    source,
    sessionId: id,
    title: id,
    project: cwd?.split("/").at(-1) ?? "",
    cwd,
    createdAt,
    lastActivity,
    messageCount: 1,
    model: null,
    parentSessionId: null,
    isSubagent: false,
    fingerprint: id,
  };
}

test("window puts today inside the right edge; pan and zoom preserve their anchors", () => {
  const now = instant("2026-08-27T00:00:00Z");
  const original = createTimelineWindow("month", now);
  assert.ok((now - original.start) / (original.end - original.start) > 0.9);
  assert.ok(now < original.end);

  const shifted = shiftTimelineWindow(original, -0.25);
  assert.equal(shifted.start - original.start, -(original.end - original.start) * 0.25);
  assert.equal(shifted.end - original.end, shifted.start - original.start);

  const zoomed = zoomTimelineWindow(original, "year");
  assert.equal(zoomed.end, original.end);
  assert.equal(zoomed.end - zoomed.start, 365 * 86_400_000);
});

test("bars clip to the window and instantaneous sessions retain a six-pixel target", () => {
  assert.deepEqual(
    timelineBar(instant("2026-07-20T00:00:00Z"), instant("2026-08-03T00:00:00Z"), august, 1000),
    { x: 0, width: 200 },
  );
  assert.deepEqual(timelineBar(august.end, august.end, august, 500), { x: 494, width: 6 });
  assert.equal(timelineBar(august.end + 1, august.end + 2, august, 500), null);
});

test("hit testing prefers the last painted overlapping session", () => {
  const first = session("first", "claude", "/work/a", "2026-08-02", "2026-08-06");
  const second = session("second", "codex", "/work/a", "2026-08-03", "2026-08-05");
  const entries =
    buildTimelineGroups([first, second], "directory", august)[0]?.lanes.flatMap(
      (lane) => lane.entries,
    ) ?? [];
  assert.equal(hitTestTimelineEntry(entries, august, 1000, 400)?.session.id, "second");
  assert.equal(hitTestTimelineEntry(entries, august, 1000, 800), null);
});

test("directory and agent grouping invert the group and lane dimensions", () => {
  const rows = [
    session("a", "claude", "/work/alpha", "2026-08-02", "2026-08-03"),
    session("b", "codex", "/work/alpha", "2026-08-03", "2026-08-04"),
    session("c", "claude", "/work/beta", "2026-08-04", "2026-08-05"),
    session("outside", "grok", "/work/gamma", "2026-07-01", "2026-07-02"),
  ];
  const byDirectory = buildTimelineGroups(rows, "directory", august);
  assert.equal(byDirectory.length, 2);
  assert.equal(byDirectory.find((group) => group.id === "/work/alpha")?.lanes.length, 2);
  const byAgent = buildTimelineGroups(rows, "agent", august);
  assert.equal(byAgent.length, 2);
  assert.equal(byAgent.find((group) => group.id === "claude")?.lanes.length, 2);
});

test("ticks remain bounded and year ticks emphasize quarter starts", () => {
  const year = { start: instant("2026-01-01T00:00:00Z"), end: instant("2026-12-31T00:00:00Z") };
  const ticks = timelineTicks(year, "year", "en-US", "UTC");
  assert.equal(ticks.length, 12);
  assert.equal(ticks.filter((tick) => tick.major).length, 4);
  assert.ok(
    timelineTicks({ start: 0, end: 1000 * 365 * 86_400_000 }, "week", "en-US", "UTC").length <= 400,
  );
});

test("narrow tracks keep major dates without overlapping tick labels", () => {
  const range = { start: 0, end: 100 };
  const ticks = [
    { time: 0, label: "start", major: false },
    { time: 10, label: "near", major: false },
    { time: 25, label: "month", major: true },
    { time: 60, label: "later", major: false },
    { time: 65, label: "quarter", major: true },
    { time: 95, label: "clipped", major: false },
  ];
  assert.deepEqual(
    selectTimelineTicks(ticks, range, 200).map((tick) => tick.label),
    ["month", "quarter"],
  );
  assert.deepEqual(selectTimelineTicks(ticks, range, 0), []);
});
