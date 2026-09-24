import { useMemo } from "react";
import { CalendarDays, List, RefreshCw } from "lucide-react";
import { Button } from "../components/ui/button.js";
import type { HistoryLocale, HistorySessionDetail, HistorySnapshot } from "./contract.js";
import { HistoryReader } from "./HistoryReader.js";
import { HistorySessionList } from "./HistorySessionList.js";
import { HistoryTimeline } from "./HistoryTimeline.js";
import { historyLabels } from "./labels.js";

export interface HistoryReviewProps {
  view: "list" | "timeline";
  onViewChange: (view: "list" | "timeline") => void;
  snapshot: HistorySnapshot | null;
  selectedSessionId: string | null;
  detail: HistorySessionDetail | null;
  detailLoading?: boolean;
  detailError?: string | null;
  isRefreshing?: boolean;
  refreshError?: string | null;
  onSelectSession: (sessionId: string) => void;
  onRefresh?: () => void;
  locale?: HistoryLocale;
}

/** The caller owns source data, refresh generation, and detail selection. This view owns only presentation state. */
export function HistoryReview({
  view,
  onViewChange,
  snapshot,
  selectedSessionId,
  detail,
  detailLoading = false,
  detailError = null,
  isRefreshing = false,
  refreshError = null,
  onSelectSession,
  onRefresh,
  locale = "zh-CN",
}: HistoryReviewProps) {
  const labels = historyLabels(locale);
  const sessions = snapshot?.sessions ?? [];
  const summary = useMemo(
    () => sessions.find((session) => session.id === selectedSessionId) ?? null,
    [selectedSessionId, sessions],
  );

  return (
    <main
      className="flex h-full min-h-0 min-w-0 flex-col bg-background text-ui-base text-foreground"
      aria-label={labels.review}
    >
      <header className="flex flex-wrap items-center gap-2 border-b border-border bg-header px-3 py-2">
        <h1 className="mr-auto text-ui-lg font-semibold">{labels.review}</h1>
        <div className="flex items-center gap-1" role="group" aria-label={labels.review}>
          <Button
            variant={view === "list" ? "secondary" : "ghost"}
            size="sm"
            aria-pressed={view === "list"}
            onClick={() => onViewChange("list")}
          >
            <List className="size-4" />
            {labels.list}
          </Button>
          <Button
            variant={view === "timeline" ? "secondary" : "ghost"}
            size="sm"
            aria-pressed={view === "timeline"}
            onClick={() => onViewChange("timeline")}
          >
            <CalendarDays className="size-4" />
            {labels.timeline}
          </Button>
        </div>
        {onRefresh ? (
          <Button
            variant="outline"
            size="sm"
            onClick={onRefresh}
            disabled={isRefreshing}
            aria-label={isRefreshing ? labels.refreshing : labels.refresh}
          >
            <RefreshCw className={`size-4 ${isRefreshing ? "animate-spin" : ""}`} />
            {isRefreshing ? labels.refreshing : labels.refresh}
          </Button>
        ) : null}
      </header>
      {refreshError ? (
        <p
          role="alert"
          className="border-b border-destructive px-3 py-2 text-ui-sm text-destructive"
        >
          {refreshError}
        </p>
      ) : null}
      {snapshot && !snapshot.complete ? (
        <p
          role="status"
          className="border-b border-border bg-surface px-3 py-2 text-ui-sm text-foreground-subtle"
        >
          {labels.incomplete}
        </p>
      ) : null}
      {snapshot && snapshot.diagnostics.length > 0 ? (
        <details className="border-b border-border px-3 py-2 text-ui-xs text-foreground-subtle">
          <summary className="cursor-pointer">
            {labels.diagnostics} · {snapshot.diagnostics.length}
          </summary>
          <ul className="mt-2 space-y-1 pl-4">
            {snapshot.diagnostics.map((diagnostic, index) => (
              <li key={`${diagnostic.code}:${diagnostic.path ?? ""}:${diagnostic.line ?? index}`}>
                {diagnostic.message}
              </li>
            ))}
          </ul>
        </details>
      ) : null}
      {!snapshot ? (
        <div
          role={refreshError ? "alert" : "status"}
          className="flex min-h-0 flex-1 items-center justify-center p-6 text-ui-sm text-foreground-subtle"
        >
          {refreshError || labels.loading}
        </div>
      ) : (
        <div className="flex min-h-0 min-w-0 flex-1 flex-col lg:flex-row">
          <div
            className={`min-h-56 min-w-0 shrink-0 border-b border-border lg:min-h-0 lg:border-b-0 lg:border-r ${view === "list" ? "h-72 lg:h-full lg:w-80" : "h-96 lg:h-full lg:basis-3/5"}`}
          >
            {view === "list" ? (
              <HistorySessionList
                sessions={sessions}
                selectedSessionId={selectedSessionId}
                onSelectSession={onSelectSession}
                locale={locale}
              />
            ) : (
              <HistoryTimeline
                sessions={sessions}
                selectedSessionId={selectedSessionId}
                onOpenSession={onSelectSession}
                locale={locale}
              />
            )}
          </div>
          <div className="min-h-72 min-w-0 flex-1 lg:min-h-0">
            <HistoryReader
              summary={summary}
              detail={detail}
              sessions={sessions}
              loading={detailLoading}
              error={detailError}
              onSelectSession={onSelectSession}
              locale={locale}
            />
          </div>
        </div>
      )}
    </main>
  );
}
