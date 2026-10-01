import { useEffect, useRef, useState } from "react";
import type { KeyboardEvent, PointerEvent } from "react";
import type { HistoryLocale } from "./contract.js";
import { SourceDot } from "./HistorySessionList.js";
import { formatHistoryDuration } from "./history-grouping.js";
import { formatHistoryDate, historyLabels, sourceColor, sourceLabel } from "./labels.js";
import { hitTestTimelineEntry, timelineBar } from "./timeline-layout.js";
import type { TimelineEntry, TimelineLane, TimelineWindow } from "./timeline-layout.js";

export interface HoverPoint {
  x: number;
  y: number;
}

const trackHeight = 32;

export function LaneTrack({
  lane,
  range,
  width,
  selectedSessionId,
  themeRevision,
  locale,
  onOpenSession,
  onHover,
}: {
  lane: TimelineLane;
  range: TimelineWindow;
  width: number;
  selectedSessionId: string | null;
  themeRevision: number;
  locale: HistoryLocale;
  onOpenSession: (sessionId: string) => void;
  onHover: (entry: TimelineEntry | null, point: HoverPoint | null) => void;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [hoveredID, setHoveredID] = useState<string | null>(null);
  const [focusedIndex, setFocusedIndex] = useState<number | null>(null);
  const labels = historyLabels(locale);
  const focused = focusedIndex == null ? null : (lane.entries[focusedIndex] ?? null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || width <= 0) return;
    const context = canvas.getContext("2d");
    if (!context) return;
    const ratio = globalThis.devicePixelRatio || 1;
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(trackHeight * ratio);
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    context.clearRect(0, 0, width, trackHeight);

    const style = getComputedStyle(canvas);
    const foreground = style.color;
    const border = style.getPropertyValue("--color-border").trim() || foreground;
    context.fillStyle = border;
    context.globalAlpha = 0.45;
    context.fillRect(0, trackHeight - 1, width, 1);
    context.globalAlpha = 1;

    // 今天的位置画一条虚线，让"最近发生了什么"一眼可见。
    const today = Date.now();
    if (today >= range.start && today <= range.end) {
      const x = ((today - range.start) / (range.end - range.start)) * width;
      context.save();
      context.setLineDash([3, 3]);
      context.strokeStyle = foreground;
      context.globalAlpha = 0.35;
      context.lineWidth = 1;
      context.beginPath();
      context.moveTo(x, 0);
      context.lineTo(x, trackHeight);
      context.stroke();
      context.restore();
    }

    for (const entry of lane.entries) {
      const bar = timelineBar(entry.start, entry.end, range, width);
      if (!bar) continue;
      const selected = entry.session.id === selectedSessionId;
      const active = entry.session.id === hoveredID || entry.session.id === focused?.session.id;
      const color = sourceColor(entry.session.source);
      context.beginPath();
      context.roundRect(bar.x, 7, bar.width, 18, Math.min(5, bar.width / 2));
      context.fillStyle = color;
      context.globalAlpha = selected ? 0.85 : active ? 0.6 : 0.35;
      context.fill();
      context.globalAlpha = 1;
      context.lineWidth = selected || active ? 1.5 : 0.75;
      context.strokeStyle = color;
      context.stroke();
      if (bar.width < 72) continue;
      context.save();
      context.beginPath();
      context.rect(bar.x + 4, 7, Math.max(0, bar.width - 8), 18);
      context.clip();
      context.font = `500 ${style.fontSize} ${style.fontFamily}`;
      context.fillStyle = foreground;
      context.textBaseline = "middle";
      context.fillText(entry.session.title || labels.unknownTitle, bar.x + 7, 16, bar.width - 12);
      context.restore();
    }
  }, [
    focused?.session.id,
    hoveredID,
    labels.unknownTitle,
    lane.entries,
    range,
    selectedSessionId,
    themeRevision,
    width,
  ]);

  function entryAt(clientX: number): TimelineEntry | null {
    const canvas = canvasRef.current;
    if (!canvas) return null;
    const bounds = canvas.getBoundingClientRect();
    return hitTestTimelineEntry(lane.entries, range, bounds.width, clientX - bounds.left);
  }

  function handlePointerMove(event: PointerEvent<HTMLCanvasElement>) {
    const entry = entryAt(event.clientX);
    setHoveredID(entry?.session.id ?? null);
    onHover(entry, entry ? { x: event.clientX, y: event.clientY } : null);
  }

  function handleKeyDown(event: KeyboardEvent<HTMLCanvasElement>) {
    if (lane.entries.length === 0) return;
    const current = focusedIndex ?? 0;
    let next = current;
    if (event.key === "ArrowRight") next = Math.min(lane.entries.length - 1, current + 1);
    else if (event.key === "ArrowLeft") next = Math.max(0, current - 1);
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = lane.entries.length - 1;
    else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      const entry = lane.entries[current];
      if (entry) onOpenSession(entry.session.id);
      return;
    } else return;

    event.preventDefault();
    setFocusedIndex(next);
    onHover(lane.entries[next] ?? null, null);
  }

  const focusLabel = focused
    ? `${focused.session.title || labels.unknownTitle}, ${sourceLabel(focused.session.source)}, ${formatHistoryDate(focused.start, locale)}`
    : `${lane.entries.length} ${labels.sessionOf}`;
  return (
    <canvas
      ref={canvasRef}
      className="block h-8 w-full cursor-pointer text-ui-xs text-foreground outline-none focus-visible:ring-2 focus-visible:ring-brand"
      role="button"
      tabIndex={0}
      aria-label={`${lane.label}: ${focusLabel}. ${labels.keyboardHint}`}
      aria-keyshortcuts="ArrowLeft ArrowRight Home End Enter Space"
      onClick={(event) => {
        const entry = entryAt(event.clientX);
        if (entry) onOpenSession(entry.session.id);
      }}
      onFocus={() => {
        const selectedIndex = lane.entries.findIndex(
          (entry) => entry.session.id === selectedSessionId,
        );
        const index = selectedIndex >= 0 ? selectedIndex : 0;
        setFocusedIndex(index);
        onHover(lane.entries[index] ?? null, null);
      }}
      onBlur={() => {
        setFocusedIndex(null);
        onHover(null, null);
      }}
      onKeyDown={handleKeyDown}
      onPointerMove={handlePointerMove}
      onPointerLeave={() => {
        setHoveredID(null);
        onHover(null, null);
      }}
    />
  );
}

export function HoverCard({
  entry,
  point,
  locale,
}: {
  entry: TimelineEntry;
  point: HoverPoint;
  locale: HistoryLocale;
}) {
  const labels = historyLabels(locale);
  const session = entry.session;
  const duration = formatHistoryDuration(session.createdAt, session.lastActivity, locale);
  // 固定定位跟随指针；靠右/靠下时翻到另一侧，避免被窗口裁掉。
  const width = 288;
  const flipX = typeof window !== "undefined" && point.x + width + 24 > window.innerWidth;
  const flipY = typeof window !== "undefined" && point.y + 160 > window.innerHeight;
  return (
    <div
      role="tooltip"
      className="pointer-events-none fixed z-50 w-72 rounded-lg border border-border bg-card p-3 text-ui-xs text-foreground shadow-lg"
      style={{
        left: flipX ? point.x - width - 12 : point.x + 12,
        top: flipY ? point.y - 12 : point.y + 12,
        transform: flipY ? "translateY(-100%)" : undefined,
      }}
    >
      <div className="flex min-w-0 items-center gap-2">
        <SourceDot source={session.source} />
        <span className="min-w-0 flex-1 truncate text-ui-sm font-medium">
          {session.title || labels.unknownTitle}
        </span>
      </div>
      <div className="mt-1 truncate font-mono text-foreground-subtle">
        {session.cwd || session.project || labels.unknownProject}
      </div>
      <div className="mt-1 flex flex-wrap gap-x-2 text-foreground-subtle">
        <span>{sourceLabel(session.source)}</span>
        <span>
          {session.messageCount} {labels.messages}
        </span>
        {duration ? <span>{duration}</span> : null}
      </div>
      <div className="mt-1 text-foreground-subtlest">
        {formatHistoryDate(entry.start, locale)}
        {entry.end - entry.start > 60_000 ? ` – ${formatHistoryDate(entry.end, locale)}` : ""}
      </div>
    </div>
  );
}
