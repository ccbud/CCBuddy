import type { HistoryLocale, HistorySessionSummary } from "./contract.js";
import { historyLabels } from "./labels.js";

export type HistorySortKey = "recent" | "created";

export interface HistoryListGroup {
  id: string;
  label: string;
  sessions: HistorySessionSummary[];
}

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

function startOfDay(time: number): number {
  const date = new Date(time);
  date.setHours(0, 0, 0, 0);
  return date.getTime();
}

/** Calendar bucket for the list: today, yesterday, this week, this month, then one bucket per month. */
export function historyDateBucket(
  value: string,
  now: number,
  locale: HistoryLocale,
): { id: string; label: string; order: number } {
  const labels = historyLabels(locale);
  const time = Date.parse(value);
  if (!Number.isFinite(time)) return { id: "unknown", label: labels.unknownDate, order: 5 };
  const today = startOfDay(now);
  const day = startOfDay(time);
  if (day >= today) return { id: "today", label: labels.groupToday, order: 0 };
  if (day >= today - DAY) return { id: "yesterday", label: labels.groupYesterday, order: 1 };
  if (day >= today - 6 * DAY) return { id: "week", label: labels.groupThisWeek, order: 2 };
  const nowDate = new Date(now);
  const date = new Date(time);
  if (date.getFullYear() === nowDate.getFullYear() && date.getMonth() === nowDate.getMonth()) {
    return { id: "month", label: labels.groupThisMonth, order: 3 };
  }
  const id = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`;
  return {
    id,
    label: new Intl.DateTimeFormat(locale, { year: "numeric", month: "long" }).format(date),
    // 年月桶按时间倒序排在固定桶后面；order 只决定同一 bucket 族内的相对顺序。
    order: 4,
  };
}

export function sortHistorySessions(
  sessions: readonly HistorySessionSummary[],
  sort: HistorySortKey,
): HistorySessionSummary[] {
  const key = sort === "created" ? "createdAt" : "lastActivity";
  return [...sessions].sort((left, right) => {
    const a = Date.parse(left[key]);
    const b = Date.parse(right[key]);
    if (Number.isFinite(a) && Number.isFinite(b) && a !== b) return b - a;
    return left.id.localeCompare(right.id);
  });
}

/** Groups already-sorted sessions; month buckets follow the fixed buckets in descending time order. */
export function groupHistorySessions(
  sessions: readonly HistorySessionSummary[],
  sort: HistorySortKey,
  now: number,
  locale: HistoryLocale,
): HistoryListGroup[] {
  const key = sort === "created" ? "createdAt" : "lastActivity";
  const groups = new Map<string, HistoryListGroup & { order: number; time: number }>();
  for (const session of sortHistorySessions(sessions, sort)) {
    const bucket = historyDateBucket(session[key], now, locale);
    let group = groups.get(bucket.id);
    if (!group) {
      group = {
        id: bucket.id,
        label: bucket.label,
        sessions: [],
        order: bucket.order,
        time: Date.parse(session[key]) || 0,
      };
      groups.set(bucket.id, group);
    }
    group.sessions.push(session);
  }
  return [...groups.values()]
    .sort((left, right) => left.order - right.order || right.time - left.time)
    .map(({ id, label, sessions: items }) => ({ id, label, sessions: items }));
}

/** "3 minutes ago" style text for list rows; falls back to a short date beyond a week. */
export function relativeHistoryTime(value: string, now: number, locale: HistoryLocale): string {
  const time = Date.parse(value);
  if (!Number.isFinite(time)) return historyLabels(locale).unknownDate;
  const elapsed = Math.max(0, now - time);
  const relative = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });
  if (elapsed < MINUTE) return relative.format(0, "second");
  if (elapsed < HOUR) return relative.format(-Math.round(elapsed / MINUTE), "minute");
  if (elapsed < DAY) return relative.format(-Math.round(elapsed / HOUR), "hour");
  if (elapsed < 7 * DAY) return relative.format(-Math.round(elapsed / DAY), "day");
  return new Intl.DateTimeFormat(locale, { month: "short", day: "numeric" }).format(new Date(time));
}

/** Session span as a compact duration; null for instantaneous or unknown spans. */
export function formatHistoryDuration(
  createdAt: string,
  lastActivity: string,
  locale: HistoryLocale,
): string | null {
  const start = Date.parse(createdAt);
  const end = Date.parse(lastActivity);
  if (!Number.isFinite(start) || !Number.isFinite(end) || end - start < MINUTE) return null;
  const minutes = Math.round((end - start) / MINUTE);
  const hours = Math.floor(minutes / 60);
  const days = Math.floor(hours / 24);
  const unit = (value: number, kind: "day" | "hour" | "minute") =>
    new Intl.NumberFormat(locale, { style: "unit", unit: kind, unitDisplay: "narrow" }).format(
      value,
    );
  if (days >= 1)
    return hours % 24 ? `${unit(days, "day")} ${unit(hours % 24, "hour")}` : unit(days, "day");
  if (hours >= 1)
    return minutes % 60
      ? `${unit(hours, "hour")} ${unit(minutes % 60, "minute")}`
      : unit(hours, "hour");
  return unit(minutes, "minute");
}

export function distinctHistoryProjects(sessions: readonly HistorySessionSummary[]): string[] {
  const counts = new Map<string, number>();
  for (const session of sessions) {
    const project = session.project || session.cwd || "";
    if (!project) continue;
    counts.set(project, (counts.get(project) ?? 0) + 1);
  }
  return [...counts.entries()]
    .sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]))
    .map(([project]) => project);
}
