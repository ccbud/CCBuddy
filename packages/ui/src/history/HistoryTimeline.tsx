import { useEffect, useMemo, useRef, useState } from "react";
import type { PointerEvent } from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { Button } from "../components/ui/button.js";
import type { HistoryLocale, HistorySessionSummary, HistorySource } from "./contract.js";
import { HISTORY_SOURCES } from "./contract.js";
import { SourceDot } from "./HistorySessionList.js";
import { HoverCard, LaneTrack, type HoverPoint } from "./HistoryTimelineLane.js";
import { formatHistoryDate, historyLabels, sourceLabel } from "./labels.js";
import {
  buildTimelineGroups,
  createTimelineWindow,
  selectTimelineTicks,
  shiftTimelineWindow,
  timelineTicks,
  zoomTimelineWindow,
} from "./timeline-layout.js";
import type {
  TimelineEntry,
  TimelineGrouping,
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
  const [hovered, setHovered] = useState<{ entry: TimelineEntry; point: HoverPoint | null } | null>(
    null,
  );
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
  const presentSources = useMemo(() => {
    const present = new Set<HistorySource>(sessions.map((session) => session.source));
    return HISTORY_SOURCES.filter((source) => present.has(source));
  }, [sessions]);

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

  const handleHover = (entry: TimelineEntry | null, point: HoverPoint | null) =>
    setHovered(entry ? { entry, point } : null);

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
      {presentSources.length > 0 ? (
        <div
          className="flex flex-wrap items-center gap-x-3 gap-y-1 border-b border-border/50 px-3 py-1 text-ui-xs text-foreground-subtle"
          aria-label={labels.sources}
        >
          {presentSources.map((source) => (
            <span key={source} className="flex items-center gap-1">
              <SourceDot source={source} />
              {sourceLabel(source)}
            </span>
          ))}
        </div>
      ) : null}
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
                  {group.source ? <SourceDot source={group.source} /> : null}
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
                      {lane.source ? <SourceDot source={lane.source} /> : null}
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
                        onHover={handleHover}
                      />
                    </div>
                  </div>
                ))}
              </div>
            ))
          )}
        </div>
      </div>
      {hovered?.point ? (
        <HoverCard entry={hovered.entry} point={hovered.point} locale={locale} />
      ) : null}
      <div
        className="min-h-9 border-t border-border px-3 py-2 text-ui-xs text-foreground-subtle"
        role="status"
        aria-live="polite"
      >
        {hovered
          ? `${hovered.entry.session.title || labels.unknownTitle} · ${sourceLabel(hovered.entry.session.source)} · ${hovered.entry.session.cwd || hovered.entry.session.project || labels.unknownProject} · ${formatHistoryDate(hovered.entry.start, locale)}`
          : labels.keyboardHint}
      </div>
    </section>
  );
}
