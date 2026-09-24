import { useEffect, useMemo, useRef, useState } from "react";
import type { KeyboardEvent, PointerEvent } from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { Button } from "../components/ui/button.js";
import type { HistoryLocale, HistorySessionSummary } from "./contract.js";
import { formatHistoryDate, historyLabels, sourceLabel } from "./labels.js";
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
import type {
  TimelineEntry,
  TimelineGrouping,
  TimelineLane,
  TimelineWindow,
  TimelineZoom,
} from "./timeline-layout.js";

export interface HistoryTimelineProps {
  sessions: readonly HistorySessionSummary[];
  selectedSessionId: string | null;
  onOpenSession: (sessionId: string) => void;
  locale?: HistoryLocale;
}

const zoomOptions: readonly TimelineZoom[] = ["week", "month", "quarter", "year"];
const trackHeight = 32;

function LaneTrack({
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
  onHover: (entry: TimelineEntry | null) => void;
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
    const brand = style.getPropertyValue("--color-brand").trim() || foreground;
    const border = style.getPropertyValue("--color-border").trim() || foreground;
    context.fillStyle = border;
    context.globalAlpha = 0.45;
    context.fillRect(0, trackHeight - 1, width, 1);
    context.globalAlpha = 1;

    for (const entry of lane.entries) {
      const bar = timelineBar(entry.start, entry.end, range, width);
      if (!bar) continue;
      const selected = entry.session.id === selectedSessionId;
      const active = entry.session.id === hoveredID || entry.session.id === focused?.session.id;
      context.beginPath();
      context.roundRect(bar.x, 7, bar.width, 18, Math.min(5, bar.width / 2));
      context.fillStyle = brand;
      context.globalAlpha = selected ? 0.78 : active ? 0.56 : 0.3;
      context.fill();
      context.globalAlpha = 1;
      context.lineWidth = selected || active ? 1.5 : 0.75;
      context.strokeStyle = brand;
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
    onHover(entry);
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
    onHover(lane.entries[next] ?? null);
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
        onHover(lane.entries[index] ?? null);
      }}
      onBlur={() => {
        setFocusedIndex(null);
        onHover(null);
      }}
      onKeyDown={handleKeyDown}
      onPointerMove={handlePointerMove}
      onPointerLeave={() => {
        setHoveredID(null);
        onHover(null);
      }}
    />
  );
}

export function HistoryTimeline({
  sessions,
  selectedSessionId,
  onOpenSession,
  locale = "zh-CN",
}: HistoryTimelineProps) {
  const labels = historyLabels(locale);
  const [zoom, setZoom] = useState<TimelineZoom>("month");
  const [grouping, setGrouping] = useState<TimelineGrouping>("directory");
  const [range, setRange] = useState<TimelineWindow>(() => createTimelineWindow("month"));
  const [trackWidth, setTrackWidth] = useState(0);
  const [themeRevision, setThemeRevision] = useState(0);
  const [hovered, setHovered] = useState<TimelineEntry | null>(null);
  const trackRef = useRef<HTMLDivElement>(null);
  const panRef = useRef<{ clientX: number; range: TimelineWindow } | null>(null);
  const groups = useMemo(
    () => buildTimelineGroups(sessions, grouping, range),
    [sessions, grouping, range],
  );
  const ticks = useMemo(() => timelineTicks(range, zoom, locale), [range, zoom, locale]);
  const visibleTicks = useMemo(
    () => selectTimelineTicks(ticks, range, trackWidth),
    [ticks, range, trackWidth],
  );

  useEffect(() => {
    const track = trackRef.current;
    if (!track) return;
    const update = () => setTrackWidth(track.getBoundingClientRect().width);
    update();
    const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(update);
    observer?.observe(track);
    return () => observer?.disconnect();
  }, []);

  useEffect(() => {
    const observer = new MutationObserver(() => setThemeRevision((value) => value + 1));
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["class", "style", "data-theme"],
    });
    return () => observer.disconnect();
  }, []);

  function pan(event: PointerEvent<HTMLDivElement>) {
    const origin = panRef.current;
    if (!origin || trackWidth <= 0) return;
    setRange(shiftTimelineWindow(origin.range, -(event.clientX - origin.clientX) / trackWidth));
  }

  return (
    <section
      className="flex h-full min-h-0 min-w-0 flex-col bg-background"
      aria-label={labels.timeline}
    >
      <div className="flex flex-wrap items-center gap-2 border-b border-border px-3 py-2">
        <h2 className="mr-auto text-ui-base font-semibold">{labels.timeline}</h2>
        <div className="flex items-center gap-1" role="group" aria-label={labels.groupDirectory}>
          <Button
            size="sm"
            variant={grouping === "directory" ? "secondary" : "ghost"}
            aria-pressed={grouping === "directory"}
            onClick={() => setGrouping("directory")}
          >
            {labels.groupDirectory}
          </Button>
          <Button
            size="sm"
            variant={grouping === "agent" ? "secondary" : "ghost"}
            aria-pressed={grouping === "agent"}
            onClick={() => setGrouping("agent")}
          >
            {labels.groupAgent}
          </Button>
        </div>
        <div className="flex items-center gap-1" role="group" aria-label={labels.timeline}>
          {zoomOptions.map((option) => (
            <Button
              key={option}
              size="sm"
              variant={zoom === option ? "secondary" : "ghost"}
              aria-pressed={zoom === option}
              onClick={() => {
                setZoom(option);
                setRange((current) => zoomTimelineWindow(current, option));
              }}
            >
              {labels[option]}
            </Button>
          ))}
        </div>
        <div className="flex items-center gap-1">
          <Button
            size="icon-sm"
            variant="ghost"
            aria-label={labels.previous}
            onClick={() => setRange((current) => shiftTimelineWindow(current, -0.25))}
          >
            <ChevronLeft />
          </Button>
          <Button size="sm" variant="ghost" onClick={() => setRange(createTimelineWindow(zoom))}>
            {labels.today}
          </Button>
          <Button
            size="icon-sm"
            variant="ghost"
            aria-label={labels.next}
            onClick={() => setRange((current) => shiftTimelineWindow(current, 0.25))}
          >
            <ChevronRight />
          </Button>
        </div>
      </div>
      <div className="min-h-0 flex-1 overflow-auto" data-testid="history-timeline-scroll">
        <div className="min-w-0">
          <div className="sticky top-0 z-10 flex h-9 border-b border-border bg-background-alt text-ui-xs text-foreground-subtle">
            <span className="w-28 shrink-0 px-3 py-2 sm:w-44">
              {grouping === "directory" ? labels.groupDirectory : labels.groupAgent}
            </span>
            <div
              ref={trackRef}
              className="relative h-full min-w-0 flex-1 cursor-grab touch-pan-y active:cursor-grabbing"
              aria-label={`${formatHistoryDate(range.start, locale)} – ${formatHistoryDate(range.end, locale)}`}
              onPointerDown={(event) => {
                panRef.current = { clientX: event.clientX, range };
                event.currentTarget.setPointerCapture(event.pointerId);
              }}
              onPointerMove={pan}
              onPointerUp={(event) => {
                pan(event);
                panRef.current = null;
                event.currentTarget.releasePointerCapture(event.pointerId);
              }}
              onPointerCancel={() => {
                panRef.current = null;
              }}
            >
              {visibleTicks.map((tick) => (
                <span
                  key={tick.time}
                  className={`absolute top-2 whitespace-nowrap border-l pl-1 ${tick.major ? "border-border text-foreground" : "border-border/50"}`}
                  style={{
                    left: `${((tick.time - range.start) / (range.end - range.start)) * 100}%`,
                  }}
                >
                  {tick.label}
                </span>
              ))}
            </div>
          </div>
          {groups.length === 0 ? (
            <p className="px-4 py-8 text-ui-sm text-foreground-subtle">{labels.emptyWindow}</p>
          ) : (
            groups.map((group) => (
              <div key={group.id}>
                <div className="flex h-9 items-center gap-2 border-b border-border bg-surface px-3 text-ui-sm font-medium">
                  <span className="truncate" title={group.subtitle ?? group.label}>
                    {group.source ? sourceLabel(group.source) : group.label}
                  </span>
                  <span className="text-ui-xs text-foreground-subtle">{group.sessionCount}</span>
                </div>
                {group.lanes.map((lane) => (
                  <div
                    key={`${group.id}:${lane.id}`}
                    className="flex h-8 border-b border-border/50"
                  >
                    <div className="flex w-28 shrink-0 items-center gap-2 px-3 text-ui-xs text-foreground-subtle sm:w-44">
                      <span className="min-w-0 truncate" title={lane.label}>
                        {lane.source ? sourceLabel(lane.source) : lane.label}
                      </span>
                      <span className="ml-auto shrink-0">{lane.entries.length}</span>
                    </div>
                    <div className="min-w-0 flex-1">
                      <LaneTrack
                        lane={lane}
                        range={range}
                        width={trackWidth}
                        selectedSessionId={selectedSessionId}
                        themeRevision={themeRevision}
                        locale={locale}
                        onOpenSession={onOpenSession}
                        onHover={setHovered}
                      />
                    </div>
                  </div>
                ))}
              </div>
            ))
          )}
        </div>
      </div>
      <div
        className="min-h-9 border-t border-border px-3 py-2 text-ui-xs text-foreground-subtle"
        role="status"
        aria-live="polite"
      >
        {hovered
          ? `${hovered.session.title || labels.unknownTitle} · ${sourceLabel(hovered.session.source)} · ${hovered.session.cwd || hovered.session.project || labels.unknownProject} · ${formatHistoryDate(hovered.start, locale)}`
          : labels.keyboardHint}
      </div>
    </section>
  );
}
