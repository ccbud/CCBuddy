import { useEffect, useMemo, useRef, useState } from "react";
import type { KeyboardEvent } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { Search } from "lucide-react";
import type { HistoryLocale, HistorySessionSummary, HistorySource } from "./contract.js";
import { formatHistoryDate, historyLabels, sourceLabel } from "./labels.js";

export interface HistorySessionListProps {
  sessions: readonly HistorySessionSummary[];
  selectedSessionId: string | null;
  onSelectSession: (sessionId: string) => void;
  locale?: HistoryLocale;
}

const sources: readonly HistorySource[] = [
  "claude",
  "codex",
  "qoder",
  "grok",
  "copilot",
  "antigravity",
];

export function HistorySessionList({
  sessions,
  selectedSessionId,
  onSelectSession,
  locale = "zh-CN",
}: HistorySessionListProps) {
  const labels = historyLabels(locale);
  const [query, setQuery] = useState("");
  const [source, setSource] = useState<HistorySource | "all">("all");
  const [activeIndex, setActiveIndex] = useState(0);
  const scrollRef = useRef<HTMLDivElement>(null);
  const visibleSessions = useMemo(() => {
    const term = query.trim().toLocaleLowerCase(locale);
    return sessions
      .filter((session) => {
        if (source !== "all" && session.source !== source) return false;
        if (!term) return true;
        return [
          session.title,
          session.project,
          session.cwd ?? "",
          sourceLabel(session.source),
          session.model ?? "",
        ].some((value) => value.toLocaleLowerCase(locale).includes(term));
      })
      .sort((left, right) => {
        const a = Date.parse(left.lastActivity);
        const b = Date.parse(right.lastActivity);
        if (Number.isFinite(a) && Number.isFinite(b) && a !== b) return b - a;
        return left.id.localeCompare(right.id);
      });
  }, [locale, query, sessions, source]);
  const virtualizer = useVirtualizer({
    count: visibleSessions.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => 72,
    getItemKey: (index) => visibleSessions[index]?.id ?? index,
    overscan: 8,
  });
  const virtualRows = virtualizer.getVirtualItems();

  useEffect(() => {
    setActiveIndex((current) => Math.min(current, Math.max(0, visibleSessions.length - 1)));
  }, [visibleSessions.length]);

  function handleListKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (visibleSessions.length === 0) return;
    let next = activeIndex;
    if (event.key === "ArrowDown") next = Math.min(visibleSessions.length - 1, activeIndex + 1);
    else if (event.key === "ArrowUp") next = Math.max(0, activeIndex - 1);
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = visibleSessions.length - 1;
    else if (event.key === "Enter" || event.key === " ") {
      if (event.target === event.currentTarget) {
        event.preventDefault();
        const session = visibleSessions[activeIndex];
        if (session) onSelectSession(session.id);
      }
      return;
    } else return;
    event.preventDefault();
    setActiveIndex(next);
    virtualizer.scrollToIndex(next, { align: "auto" });
  }

  return (
    <section className="flex h-full min-h-0 min-w-0 flex-col bg-surface" aria-label={labels.list}>
      <div className="border-b border-border p-3">
        <div className="mb-2 flex items-baseline justify-between gap-2">
          <h2 className="text-ui-base font-semibold">{labels.list}</h2>
          <span className="text-ui-xs text-foreground-subtle">
            {visibleSessions.length} {labels.sessionOf}
          </span>
        </div>
        <label className="flex h-8 items-center gap-2 rounded-lg border border-input-border bg-input px-2 text-foreground-subtle focus-within:border-input-border-focused focus-within:bg-input-focused">
          <Search className="size-4 shrink-0" aria-hidden="true" />
          <input
            type="search"
            value={query}
            onChange={(event) => {
              setQuery(event.target.value);
              setActiveIndex(0);
            }}
            placeholder={labels.filterSessions}
            aria-label={labels.filterSessions}
            className="min-w-0 flex-1 bg-transparent text-mobile-input-safe text-foreground outline-none placeholder:text-foreground-subtlest md:text-ui-base"
          />
        </label>
        <select
          value={source}
          onChange={(event) => {
            setSource(event.target.value as HistorySource | "all");
            setActiveIndex(0);
          }}
          aria-label={labels.allAgents}
          className="mt-2 h-7 w-full rounded-lg border border-input-border bg-input px-2 text-mobile-input-safe text-foreground outline-none focus-visible:border-input-border-focused md:text-ui-sm"
        >
          <option value="all">{labels.allAgents}</option>
          {sources.map((item) => (
            <option key={item} value={item}>
              {sourceLabel(item)}
            </option>
          ))}
        </select>
      </div>
      {visibleSessions.length === 0 ? (
        <p className="px-3 py-6 text-ui-sm text-foreground-subtle">
          {sessions.length === 0 ? labels.noSessions : labels.noMatches}
        </p>
      ) : (
        <div
          ref={scrollRef}
          className="min-h-0 flex-1 overflow-auto outline-none focus-visible:ring-2 focus-visible:ring-brand"
          tabIndex={0}
          role="listbox"
          aria-label={labels.list}
          aria-activedescendant={`history-session-row-${activeIndex}`}
          onKeyDown={handleListKeyDown}
        >
          <div className="relative w-full" style={{ height: virtualizer.getTotalSize() }}>
            {virtualRows.map((row) => {
              const session = visibleSessions[row.index];
              if (!session) return null;
              const selected = session.id === selectedSessionId;
              const active = row.index === activeIndex;
              return (
                <button
                  key={row.key}
                  id={`history-session-row-${row.index}`}
                  type="button"
                  role="option"
                  aria-selected={selected}
                  tabIndex={-1}
                  className={`absolute left-0 top-0 flex h-18 w-full flex-col justify-center gap-1 border-b border-border/50 px-3 text-left outline-none hover:bg-surface-hover ${selected ? "bg-card-selected" : active ? "bg-hover" : ""}`}
                  style={{ transform: `translateY(${row.start}px)` }}
                  onClick={() => {
                    setActiveIndex(row.index);
                    onSelectSession(session.id);
                  }}
                >
                  <span className="flex min-w-0 items-center gap-2">
                    <span className="min-w-0 flex-1 truncate text-ui-base font-medium">
                      {session.title || labels.unknownTitle}
                    </span>
                    {session.isSubagent ? (
                      <span className="text-ui-xs text-foreground-subtle">
                        {labels.childAgents}
                      </span>
                    ) : null}
                  </span>
                  <span className="flex min-w-0 items-center gap-2 text-ui-xs text-foreground-subtle">
                    <span className="shrink-0">{sourceLabel(session.source)}</span>
                    <span
                      className="min-w-0 flex-1 truncate"
                      title={session.cwd ?? session.project}
                    >
                      {session.project || session.cwd || labels.unknownProject}
                    </span>
                  </span>
                  <span className="flex items-center justify-between gap-2 text-ui-xs text-foreground-subtlest">
                    <span>
                      {session.messageCount} {labels.messages}
                    </span>
                    <time dateTime={session.lastActivity}>
                      {formatHistoryDate(session.lastActivity, locale)}
                    </time>
                  </span>
                </button>
              );
            })}
          </div>
        </div>
      )}
    </section>
  );
}
