import { useDeferredValue, useEffect, useMemo, useRef, useState } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { ChevronDown, ChevronUp, Search } from "lucide-react";
import { Button } from "../components/ui/button.js";
import type { HistoryLocale, HistorySessionDetail, HistorySessionSummary } from "./contract.js";
import { HistoryMessageRow, HistoryUsageStats } from "./HistoryContent.js";
import { formatHistoryDate, historyLabels, sourceLabel } from "./labels.js";
import { findMatchingMessages } from "./reader-utils.js";

export interface HistoryReaderProps {
  summary: HistorySessionSummary | null;
  detail: HistorySessionDetail | null;
  sessions?: readonly HistorySessionSummary[];
  loading?: boolean;
  error?: string | null;
  onSelectSession?: (sessionId: string) => void;
  locale?: HistoryLocale;
}

export function HistoryReader({
  summary,
  detail,
  sessions = [],
  loading = false,
  error = null,
  onSelectSession,
  locale = "zh-CN",
}: HistoryReaderProps) {
  const labels = historyLabels(locale);
  const scrollRef = useRef<HTMLDivElement>(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [activeResult, setActiveResult] = useState(0);
  const deferredQuery = useDeferredValue(searchQuery.trim());
  // 列表快照可能早于详情回读；文件追加后 fingerprint 不同仍是同一会话的有效详情。
  const currentDetail = !loading && detail?.summary.id === summary?.id ? detail : null;
  const displayedSummary = currentDetail?.summary ?? summary;
  const messages = currentDetail?.messages ?? [];
  const matches = useMemo(
    () => findMatchingMessages(messages, deferredQuery, locale),
    [messages, deferredQuery, locale],
  );
  const parent = displayedSummary?.parentSessionId
    ? sessions.find((item) => item.id === displayedSummary.parentSessionId)
    : null;
  const children = useMemo(
    () =>
      displayedSummary
        ? sessions.filter((item) => item.parentSessionId === displayedSummary.id)
        : [],
    [sessions, displayedSummary],
  );
  const virtualizer = useVirtualizer({
    count: messages.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => 160,
    getItemKey: (index) => messages[index]?.id ?? index,
    overscan: 5,
  });
  const virtualRows = virtualizer.getVirtualItems();

  useEffect(() => {
    if (scrollRef.current) scrollRef.current.scrollTop = 0;
    virtualizer.measure();
    setSearchQuery("");
    setActiveResult(0);
  }, [summary?.id]);

  useEffect(() => setActiveResult(0), [deferredQuery]);

  useEffect(() => {
    const messageIndex = matches[activeResult];
    if (deferredQuery && messageIndex !== undefined) {
      // 长消息可远高于视口；从行首定位，保证匹配摘要先进入视野。
      virtualizer.scrollToIndex(messageIndex, { align: "start" });
    }
  }, [activeResult, deferredQuery, matches, virtualizer]);

  function moveSearchResult(direction: number) {
    if (matches.length === 0) return;
    setActiveResult((current) => (current + direction + matches.length) % matches.length);
  }

  if (!displayedSummary) {
    return (
      <section
        className="flex h-full min-h-0 items-center justify-center bg-background p-6 text-ui-sm text-foreground-subtle"
        aria-label={labels.review}
      >
        {labels.chooseSession}
      </section>
    );
  }

  return (
    <section
      className="flex h-full min-h-0 min-w-0 flex-col bg-background"
      aria-label={`${displayedSummary.title || labels.unknownTitle} ${labels.readOnly}`}
    >
      <header className="border-b border-border px-4 py-3">
        <div className="mb-1 flex min-w-0 items-center gap-2">
          <h2
            className="min-w-0 flex-1 truncate text-ui-base font-semibold"
            title={displayedSummary.title}
          >
            {displayedSummary.title || labels.unknownTitle}
          </h2>
          <span className="shrink-0 text-ui-xs text-foreground-subtle">{labels.readOnly}</span>
        </div>
        <div className="flex flex-wrap gap-x-3 gap-y-1 text-ui-xs text-foreground-subtle">
          <span>{sourceLabel(displayedSummary.source)}</span>
          <span title={displayedSummary.cwd ?? undefined} className="max-w-full truncate font-mono">
            {displayedSummary.cwd || displayedSummary.project || labels.unknownProject}
          </span>
          <span>
            {displayedSummary.messageCount} {labels.messages}
          </span>
          {displayedSummary.model ? (
            <span className="font-mono">{displayedSummary.model}</span>
          ) : null}
          <time dateTime={displayedSummary.createdAt}>
            {formatHistoryDate(displayedSummary.createdAt, locale)}
          </time>
        </div>
        {displayedSummary.usage ? (
          <div className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1">
            <span className="text-ui-xs font-medium text-foreground-subtle">
              {labels.tokenUsage}
            </span>
            <HistoryUsageStats usage={displayedSummary.usage} locale={locale} />
          </div>
        ) : null}
        {(parent || children.length > 0) && onSelectSession ? (
          <nav className="mt-2 flex flex-wrap items-center gap-1" aria-label={labels.childAgents}>
            {parent ? (
              <Button variant="ghost" size="sm" onClick={() => onSelectSession(parent.id)}>
                {labels.parent}: {parent.title || labels.unknownTitle}
              </Button>
            ) : null}
            {children.length > 0 ? (
              <span className="mr-1 text-ui-xs text-foreground-subtle">{labels.childAgents}</span>
            ) : null}
            {children.map((child) => (
              <Button
                key={child.id}
                variant="ghost"
                size="sm"
                onClick={() => onSelectSession(child.id)}
              >
                {child.title || sourceLabel(child.source)}
              </Button>
            ))}
          </nav>
        ) : null}
        <div className="mt-2 flex min-w-0 flex-wrap items-center gap-2">
          <label className="flex h-8 min-w-32 flex-1 items-center gap-2 rounded-lg border border-input-border bg-input px-2 text-foreground-subtle focus-within:border-input-border-focused focus-within:bg-input-focused">
            <Search className="size-4 shrink-0" aria-hidden="true" />
            <input
              type="search"
              value={searchQuery}
              onChange={(event) => setSearchQuery(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter") {
                  event.preventDefault();
                  moveSearchResult(event.shiftKey ? -1 : 1);
                } else if (event.key === "Escape") {
                  setSearchQuery("");
                }
              }}
              disabled={loading || !currentDetail || messages.length === 0}
              placeholder={labels.searchInSession}
              aria-label={labels.searchInSession}
              className="min-w-0 flex-1 bg-transparent text-mobile-input-safe text-foreground outline-none placeholder:text-foreground-subtlest md:text-ui-sm"
            />
          </label>
          {deferredQuery ? (
            <span role="status" aria-live="polite" className="text-ui-xs text-foreground-subtle">
              {matches.length > 0
                ? `${Math.min(activeResult + 1, matches.length)} / ${matches.length} ${labels.matchingMessages}`
                : labels.noSearchResults}
            </span>
          ) : null}
          <Button
            type="button"
            size="icon-sm"
            variant="ghost"
            disabled={matches.length === 0}
            aria-label={labels.previousMatch}
            onClick={() => moveSearchResult(-1)}
          >
            <ChevronUp />
          </Button>
          <Button
            type="button"
            size="icon-sm"
            variant="ghost"
            disabled={matches.length === 0}
            aria-label={labels.nextMatch}
            onClick={() => moveSearchResult(1)}
          >
            <ChevronDown />
          </Button>
        </div>
      </header>

      {error ? (
        <div
          role="alert"
          className="m-4 rounded-xl border border-destructive bg-card p-4 text-ui-sm text-destructive"
        >
          <strong className="font-semibold">{labels.failed}</strong>
          <p className="mt-1 break-words">{error}</p>
        </div>
      ) : loading || !currentDetail ? (
        <div role="status" className="p-4 text-ui-sm text-foreground-subtle">
          {labels.loading}
        </div>
      ) : messages.length === 0 ? (
        <p className="p-4 text-ui-sm text-foreground-subtle">{labels.emptyDetail}</p>
      ) : (
        <div
          ref={scrollRef}
          tabIndex={0}
          className="min-h-0 flex-1 overflow-auto px-3 py-3 outline-none focus-visible:ring-2 focus-visible:ring-brand"
          aria-label={`${displayedSummary.title || labels.unknownTitle} · ${messages.length} ${labels.messages}`}
        >
          <div
            className="relative mx-auto w-full max-w-4xl"
            style={{ height: virtualizer.getTotalSize() }}
          >
            {virtualRows.map((row) => {
              const message = messages[row.index];
              if (!message) return null;
              return (
                <div
                  key={row.key}
                  ref={virtualizer.measureElement}
                  data-index={row.index}
                  className="absolute left-0 top-0 w-full pb-3"
                  style={{ transform: `translateY(${row.start}px)` }}
                >
                  <HistoryMessageRow
                    message={message}
                    locale={locale}
                    query={deferredQuery}
                    active={Boolean(deferredQuery) && row.index === matches[activeResult]}
                  />
                </div>
              );
            })}
          </div>
        </div>
      )}
      {currentDetail && currentDetail.diagnostics.length > 0 ? (
        <details className="border-t border-border px-4 py-2 text-ui-xs text-foreground-subtle">
          <summary className="cursor-pointer">
            {labels.diagnostics} · {currentDetail.diagnostics.length}
          </summary>
          <ul className="mt-2 space-y-1 pl-4">
            {currentDetail.diagnostics.map((item, index) => (
              <li key={`${item.code}:${item.path ?? ""}:${item.line ?? index}`}>{item.message}</li>
            ))}
          </ul>
        </details>
      ) : null}
    </section>
  );
}
