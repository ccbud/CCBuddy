import { useEffect, useMemo, useRef, useState } from "react";
import type { KeyboardEvent } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { ArrowDownUp, Search } from "lucide-react";
import type { HistoryLocale, HistorySessionSummary, HistorySource } from "./contract.js";
import { HISTORY_SOURCES } from "./contract.js";
import {
  distinctHistoryProjects,
  formatHistoryDuration,
  groupHistorySessions,
  relativeHistoryTime,
  type HistorySortKey,
} from "./history-grouping.js";
import { historyLabels, sourceColor, sourceLabel } from "./labels.js";

export interface HistorySessionListProps {
  sessions: readonly HistorySessionSummary[];
  selectedSessionId: string | null;
  onSelectSession: (sessionId: string) => void;
  locale?: HistoryLocale;
  /** Injected for deterministic tests; defaults to the current time. */
  now?: number;
}

type ListRow =
  | { kind: "header"; key: string; label: string; count: number }
  | { kind: "session"; key: string; session: HistorySessionSummary; index: number };

const HEADER_HEIGHT = 32;
const SESSION_HEIGHT = 72;

export function SourceDot({
  source,
  className = "",
}: {
  source: HistorySource;
  className?: string;
}) {
  return (
    <span
      aria-hidden="true"
      className={`inline-block size-2 shrink-0 rounded-full ${className}`}
      style={{ backgroundColor: sourceColor(source) }}
    />
  );
}

export function HistorySessionList({
  sessions,
  selectedSessionId,
  onSelectSession,
  locale = "zh-CN",
  now,
}: HistorySessionListProps) {
  const labels = historyLabels(locale);
  const [query, setQuery] = useState("");
  const [sources, setSources] = useState<ReadonlySet<HistorySource>>(() => new Set());
  const [project, setProject] = useState("");
  const [sort, setSort] = useState<HistorySortKey>("recent");
  const [activeIndex, setActiveIndex] = useState(0);
  const scrollRef = useRef<HTMLDivElement>(null);
  // 每次渲染都取 Date.now() 会让分组/行列表永远是新引用，虚拟列表随之重算再触发渲染，形成死循环；
  // 相对时间只在列表数据变化时重新取当前时刻。
  const currentTime = useMemo(() => now ?? Date.now(), [now, sessions]);

  const sourceCounts = useMemo(() => {
    const counts = new Map<HistorySource, number>();
    for (const session of sessions)
      counts.set(session.source, (counts.get(session.source) ?? 0) + 1);
    return counts;
  }, [sessions]);
  const projects = useMemo(() => distinctHistoryProjects(sessions), [sessions]);

  const visibleSessions = useMemo(() => {
    const term = query.trim().toLocaleLowerCase(locale);
    return sessions.filter((session) => {
      if (sources.size > 0 && !sources.has(session.source)) return false;
      if (project && (session.project || session.cwd || "") !== project) return false;
      if (!term) return true;
      return [
        session.title,
        session.project,
        session.cwd ?? "",
        sourceLabel(session.source),
        session.model ?? "",
      ].some((value) => value.toLocaleLowerCase(locale).includes(term));
    });
  }, [locale, project, query, sessions, sources]);

  const rows = useMemo<ListRow[]>(() => {
    const result: ListRow[] = [];
    let index = 0;
    for (const group of groupHistorySessions(visibleSessions, sort, currentTime, locale)) {
      result.push({
        kind: "header",
        key: `header:${group.id}`,
        label: group.label,
        count: group.sessions.length,
      });
      for (const session of group.sessions) {
        result.push({ kind: "session", key: session.id, session, index });
        index += 1;
      }
    }
    return result;
  }, [currentTime, locale, sort, visibleSessions]);
  const sessionRows = useMemo(
    () =>
      rows.filter((row): row is Extract<ListRow, { kind: "session" }> => row.kind === "session"),
    [rows],
  );

  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: (index) => (rows[index]?.kind === "header" ? HEADER_HEIGHT : SESSION_HEIGHT),
    getItemKey: (index) => rows[index]?.key ?? index,
    overscan: 10,
  });
  const virtualRows = virtualizer.getVirtualItems();

  useEffect(() => {
    setActiveIndex((current) => Math.min(current, Math.max(0, sessionRows.length - 1)));
  }, [sessionRows.length]);

  function focusSession(index: number) {
    setActiveIndex(index);
    const rowIndex = rows.findIndex((row) => row.kind === "session" && row.index === index);
    if (rowIndex >= 0) virtualizer.scrollToIndex(rowIndex, { align: "auto" });
  }

  function handleListKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (sessionRows.length === 0) return;
    let next = activeIndex;
    if (event.key === "ArrowDown") next = Math.min(sessionRows.length - 1, activeIndex + 1);
    else if (event.key === "ArrowUp") next = Math.max(0, activeIndex - 1);
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = sessionRows.length - 1;
    else if (event.key === "Enter" || event.key === " ") {
      if (event.target === event.currentTarget) {
        event.preventDefault();
        const row = sessionRows[activeIndex];
        if (row) onSelectSession(row.session.id);
      }
      return;
    } else return;
    event.preventDefault();
    focusSession(next);
  }

  function toggleSource(source: HistorySource) {
    setSources((current) => {
      const next = new Set(current);
      if (next.has(source)) next.delete(source);
      else next.add(source);
      return next;
    });
    setActiveIndex(0);
  }

  const availableSources = HISTORY_SOURCES.filter((source) => sourceCounts.has(source));

  return (
    <section className="flex h-full min-h-0 min-w-0 flex-col bg-surface" aria-label={labels.list}>
      <div className="flex flex-col gap-2 border-b border-border p-3">
        <div className="flex items-baseline justify-between gap-2">
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
        {availableSources.length > 1 ? (
          <div
            className="flex flex-wrap gap-1"
            role="group"
            aria-label={labels.allAgents}
            data-testid="history-source-filter"
          >
            {availableSources.map((source) => {
              const active = sources.has(source);
              return (
                <button
                  key={source}
                  type="button"
                  aria-pressed={active}
                  onClick={() => toggleSource(source)}
                  className={`flex h-6 items-center gap-1.5 rounded-full border px-2 text-ui-xs transition-colors ${active ? "border-brand bg-selected text-foreground" : "border-border text-foreground-subtle hover:bg-hover hover:text-foreground"}`}
                >
                  <SourceDot source={source} />
                  <span>{sourceLabel(source)}</span>
                  <span className="text-foreground-subtlest">{sourceCounts.get(source)}</span>
                </button>
              );
            })}
          </div>
        ) : null}
        <div className="flex items-center gap-2">
          {projects.length > 1 ? (
            <select
              value={project}
              onChange={(event) => {
                setProject(event.target.value);
                setActiveIndex(0);
              }}
              aria-label={labels.allProjects}
              className="h-7 min-w-0 flex-1 rounded-lg border border-input-border bg-input px-2 text-mobile-input-safe text-foreground outline-none focus-visible:border-input-border-focused md:text-ui-sm"
            >
              <option value="">{labels.allProjects}</option>
              {projects.map((item) => (
                <option key={item} value={item}>
                  {item}
                </option>
              ))}
            </select>
          ) : (
            <span className="flex-1" />
          )}
          <button
            type="button"
            onClick={() => setSort((current) => (current === "recent" ? "created" : "recent"))}
            className="flex h-7 shrink-0 items-center gap-1 rounded-lg border border-border px-2 text-ui-xs text-foreground-subtle hover:bg-hover hover:text-foreground"
            aria-label={sort === "recent" ? labels.sortRecent : labels.sortCreated}
          >
            <ArrowDownUp className="size-3.5" aria-hidden="true" />
            {sort === "recent" ? labels.sortRecent : labels.sortCreated}
          </button>
        </div>
      </div>
      {visibleSessions.length === 0 ? (
        <div className="px-3 py-6 text-ui-sm text-foreground-subtle">
          <p>{sessions.length === 0 ? labels.noSessions : labels.noMatches}</p>
          {sessions.length === 0 ? (
            <p className="mt-1 text-ui-xs text-foreground-subtlest">{labels.noSessionsHint}</p>
          ) : null}
        </div>
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
            {virtualRows.map((virtualRow) => {
              const row = rows[virtualRow.index];
              if (!row) return null;
              if (row.kind === "header") {
                return (
                  <div
                    key={virtualRow.key}
                    role="presentation"
                    className="absolute left-0 top-0 flex h-8 w-full items-center gap-2 bg-surface px-3 text-ui-xs font-medium text-foreground-subtle"
                    style={{ transform: `translateY(${virtualRow.start}px)` }}
                  >
                    <span>{row.label}</span>
                    <span className="text-foreground-subtlest">{row.count}</span>
                  </div>
                );
              }
              const { session } = row;
              const selected = session.id === selectedSessionId;
              const active = row.index === activeIndex;
              const duration = formatHistoryDuration(
                session.createdAt,
                session.lastActivity,
                locale,
              );
              return (
                <button
                  key={virtualRow.key}
                  id={`history-session-row-${row.index}`}
                  type="button"
                  role="option"
                  aria-selected={selected}
                  tabIndex={-1}
                  className={`absolute left-0 top-0 flex h-18 w-full flex-col justify-center gap-1 border-l-2 px-3 text-left outline-none hover:bg-surface-hover ${selected ? "bg-card-selected" : active ? "bg-hover" : ""}`}
                  style={{
                    transform: `translateY(${virtualRow.start}px)`,
                    borderLeftColor: selected ? sourceColor(session.source) : "transparent",
                  }}
                  onClick={() => {
                    setActiveIndex(row.index);
                    onSelectSession(session.id);
                  }}
                >
                  <span className="flex min-w-0 items-center gap-2">
                    <span className="min-w-0 flex-1 truncate text-ui-base font-medium">
                      {session.title || labels.unknownTitle}
                    </span>
                    <time
                      dateTime={session.lastActivity}
                      className="shrink-0 text-ui-xs text-foreground-subtlest"
                    >
                      {relativeHistoryTime(
                        sort === "created" ? session.createdAt : session.lastActivity,
                        currentTime,
                        locale,
                      )}
                    </time>
                  </span>
                  <span className="flex min-w-0 items-center gap-2 text-ui-xs text-foreground-subtle">
                    <span className="flex shrink-0 items-center gap-1">
                      <SourceDot source={session.source} />
                      {sourceLabel(session.source)}
                    </span>
                    <span
                      className="min-w-0 flex-1 truncate"
                      title={session.cwd ?? session.project}
                    >
                      {session.project || session.cwd || labels.unknownProject}
                    </span>
                    {session.isSubagent ? (
                      <span className="shrink-0 rounded-full border border-border px-1.5 text-ui-xs">
                        {labels.childAgents}
                      </span>
                    ) : null}
                  </span>
                  <span className="flex min-w-0 items-center gap-2 text-ui-xs text-foreground-subtlest">
                    <span className="shrink-0">
                      {session.messageCount} {labels.messages}
                    </span>
                    {duration ? <span className="shrink-0">· {duration}</span> : null}
                    {session.model ? (
                      <span className="min-w-0 truncate font-mono" title={session.model}>
                        · {session.model}
                      </span>
                    ) : null}
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
