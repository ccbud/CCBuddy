import type { HistoryLocale, HistorySessionSummary, HistorySource } from "./contract.js";

export type TimelineZoom = "week" | "month" | "quarter" | "year";
export type TimelineGrouping = "directory" | "agent";

export interface TimelineWindow {
  start: number;
  end: number;
}

export interface TimelineBar {
  x: number;
  width: number;
}

export interface TimelineTick {
  time: number;
  label: string;
  major: boolean;
}

/** 窄窗口按轨道宽度减少刻度；相邻主刻度优先，避免日期文案互相覆盖。 */
export function selectTimelineTicks(
  ticks: readonly TimelineTick[],
  window: TimelineWindow,
  trackWidth: number,
  minimumSpacing = 56,
): TimelineTick[] {
  if (!Number.isFinite(trackWidth) || trackWidth <= 0 || window.end <= window.start) return [];
  const selected: TimelineTick[] = [];
  const position = (tick: TimelineTick) =>
    ((tick.time - window.start) / (window.end - window.start)) * trackWidth;
  for (const tick of ticks) {
    const x = position(tick);
    // 靠右边缘的标签会被裁成单个字，留出完整标签宽度。
    if (x < 0 || x > trackWidth - minimumSpacing) continue;
    const previous = selected.at(-1);
    if (previous && x - position(previous) < minimumSpacing) {
      if (tick.major && !previous.major) selected[selected.length - 1] = tick;
      continue;
    }
    selected.push(tick);
  }
  return selected;
}

export interface TimelineEntry {
  session: HistorySessionSummary;
  start: number;
  end: number;
}

export interface TimelineLane {
  id: string;
  label: string;
  source: HistorySource | null;
  entries: TimelineEntry[];
  lastActivity: number;
}

export interface TimelineGroup {
  id: string;
  label: string;
  subtitle: string | null;
  source: HistorySource | null;
  lanes: TimelineLane[];
  sessionCount: number;
  lastActivity: number;
}

const DAY = 86_400_000;
const ZOOM_SPANS: Record<TimelineZoom, number> = {
  week: 7 * DAY,
  month: 30 * DAY,
  quarter: 91 * DAY,
  year: 365 * DAY,
};

/** The anchor sits at 92% of the width, leaving a little room after today. */
export function createTimelineWindow(zoom: TimelineZoom, anchor = Date.now()): TimelineWindow {
  const span = ZOOM_SPANS[zoom];
  const end = anchor + span * 0.08;
  return { start: end - span, end };
}

export function shiftTimelineWindow(window: TimelineWindow, fraction: number): TimelineWindow {
  const delta = (window.end - window.start) * fraction;
  return { start: window.start + delta, end: window.end + delta };
}

/** Zoom keeps the visible right edge in place, as in the former CC Buddy calendar. */
export function zoomTimelineWindow(window: TimelineWindow, zoom: TimelineZoom): TimelineWindow {
  return { start: window.end - ZOOM_SPANS[zoom], end: window.end };
}

export function timelineBar(
  start: number,
  end: number,
  window: TimelineWindow,
  trackWidth: number,
  minimumWidth = 6,
): TimelineBar | null {
  if (
    !Number.isFinite(start) ||
    !Number.isFinite(end) ||
    !Number.isFinite(window.start) ||
    !Number.isFinite(window.end) ||
    !Number.isFinite(trackWidth) ||
    window.end <= window.start ||
    trackWidth <= 0 ||
    end < start ||
    end < window.start ||
    start > window.end
  ) {
    return null;
  }

  const span = window.end - window.start;
  const rawStart = ((start - window.start) / span) * trackWidth;
  const rawEnd = ((end - window.start) / span) * trackWidth;
  let x = Math.max(0, rawStart);
  let width = Math.min(trackWidth, rawEnd) - x;
  const minimum = Math.min(Math.max(0, minimumWidth), trackWidth);
  if (width < minimum) {
    width = minimum;
    x = Math.max(0, Math.min(x, trackWidth - minimum));
  }
  return { x, width: Math.min(width, trackWidth - x) };
}

/** Entries are searched in reverse paint order, so a visible overlap opens its top bar. */
export function hitTestTimelineEntry(
  entries: readonly TimelineEntry[],
  window: TimelineWindow,
  trackWidth: number,
  x: number,
  tolerance = 2,
): TimelineEntry | null {
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (!entry) continue;
    const bar = timelineBar(entry.start, entry.end, window, trackWidth);
    if (bar && x >= bar.x - tolerance && x <= bar.x + bar.width + tolerance) return entry;
  }
  return null;
}

function directoryKey(session: HistorySessionSummary): string {
  return session.cwd?.trim() || session.project.trim() || "—";
}

function directoryLabel(session: HistorySessionSummary): string {
  if (session.project.trim()) return session.project.trim();
  const directory = directoryKey(session);
  return directory.split(/[\\/]/).filter(Boolean).at(-1) || directory;
}

function entryFor(session: HistorySessionSummary): TimelineEntry | null {
  const start = Date.parse(session.createdAt);
  const last = Date.parse(session.lastActivity);
  if (!Number.isFinite(start) || !Number.isFinite(last)) return null;
  return { session, start, end: Math.max(start, last) };
}

/** One source of grouping truth for both rendering and calendar accessibility. */
export function buildTimelineGroups(
  sessions: readonly HistorySessionSummary[],
  grouping: TimelineGrouping,
  window: TimelineWindow,
): TimelineGroup[] {
  const buckets = new Map<string, TimelineEntry[]>();
  for (const session of sessions) {
    const entry = entryFor(session);
    if (!entry || entry.end < window.start || entry.start > window.end) continue;
    const key = grouping === "directory" ? directoryKey(session) : session.source;
    const bucket = buckets.get(key) ?? [];
    bucket.push(entry);
    buckets.set(key, bucket);
  }

  return [...buckets]
    .map(([id, members]): TimelineGroup => {
      const first = members[0]!;
      const laneBuckets = new Map<string, TimelineEntry[]>();
      for (const entry of members) {
        const key = grouping === "directory" ? entry.session.source : directoryKey(entry.session);
        const bucket = laneBuckets.get(key) ?? [];
        bucket.push(entry);
        laneBuckets.set(key, bucket);
      }
      const lanes = [...laneBuckets]
        .map(([laneID, laneEntries]): TimelineLane => {
          laneEntries.sort(
            (left, right) =>
              left.start - right.start || left.session.id.localeCompare(right.session.id),
          );
          return {
            id: laneID,
            label: grouping === "directory" ? laneID : directoryLabel(laneEntries[0]!.session),
            source: grouping === "directory" ? laneEntries[0]!.session.source : null,
            entries: laneEntries,
            lastActivity: laneEntries.reduce(
              (latest, entry) => Math.max(latest, entry.end),
              -Infinity,
            ),
          };
        })
        .sort(
          (left, right) =>
            right.lastActivity - left.lastActivity || left.label.localeCompare(right.label),
        );

      return {
        id,
        label: grouping === "directory" ? directoryLabel(first.session) : first.session.source,
        subtitle: grouping === "directory" ? first.session.cwd : null,
        source: grouping === "agent" ? first.session.source : null,
        lanes,
        sessionCount: members.length,
        lastActivity: members.reduce((latest, entry) => Math.max(latest, entry.end), -Infinity),
      };
    })
    .sort(
      (left, right) =>
        right.lastActivity - left.lastActivity || left.label.localeCompare(right.label),
    );
}

/** Calendar ticks are bounded even when a caller gives an absurd range. */
export function timelineTicks(
  window: TimelineWindow,
  zoom: TimelineZoom,
  locale: HistoryLocale = "zh-CN",
  timeZone?: string,
): TimelineTick[] {
  if (!Number.isFinite(window.start) || !Number.isFinite(window.end) || window.end <= window.start)
    return [];
  const utc = timeZone === "UTC";
  const date = new Date(window.start);
  if (zoom === "year") {
    if (utc) {
      date.setUTCDate(1);
      date.setUTCHours(0, 0, 0, 0);
    } else {
      date.setDate(1);
      date.setHours(0, 0, 0, 0);
    }
  } else {
    if (utc) date.setUTCHours(0, 0, 0, 0);
    else date.setHours(0, 0, 0, 0);
    if (zoom === "quarter") {
      const day = utc ? date.getUTCDay() : date.getDay();
      if (utc) date.setUTCDate(date.getUTCDate() - ((day + 6) % 7));
      else date.setDate(date.getDate() - ((day + 6) % 7));
    }
  }

  const formatter = new Intl.DateTimeFormat(locale, {
    month: "short",
    ...(zoom === "year" ? {} : { day: "numeric" }),
    ...(timeZone ? { timeZone } : {}),
  });
  const ticks: TimelineTick[] = [];
  for (let index = 0; index < 400 && date.getTime() <= window.end; index += 1) {
    const time = date.getTime();
    const day = utc ? date.getUTCDate() : date.getDate();
    const month = utc ? date.getUTCMonth() : date.getMonth();
    const weekday = utc ? date.getUTCDay() : date.getDay();
    if (time >= window.start) {
      ticks.push({
        time,
        label: formatter.format(date),
        major:
          zoom === "year"
            ? month % 3 === 0
            : zoom === "quarter"
              ? day <= 7
              : zoom === "month"
                ? day === 1
                : weekday === 1,
      });
    }
    if (zoom === "year") {
      if (utc) date.setUTCMonth(date.getUTCMonth() + 1);
      else date.setMonth(date.getMonth() + 1);
    } else {
      const days = zoom === "quarter" ? 7 : zoom === "month" ? 3 : 1;
      if (utc) date.setUTCDate(date.getUTCDate() + days);
      else date.setDate(date.getDate() + days);
    }
  }
  return ticks;
}
