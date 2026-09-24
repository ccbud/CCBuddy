import { useCallback, useEffect, useRef, useState } from "react";
import type {
  HistoryLocale,
  HistoryRefreshEvent,
  HistoryRefreshProgress,
  HistoryRefreshTerminal,
  HistorySessionDetail,
  HistorySnapshot,
} from "./contract.js";
import { HistoryReview } from "./HistoryReview.js";

export interface HistoryReadBridge {
  readonly protocolVersion: 1;
  list(): Promise<HistorySnapshot>;
  load(id: string): Promise<HistorySessionDetail>;
  refresh(): Promise<HistoryRefreshTerminal>;
  onRefreshEvent(listener: (event: HistoryRefreshEvent) => void): () => void;
}

export function HistoryReviewController({
  history,
  view,
  onViewChange,
  locale,
}: {
  history: HistoryReadBridge;
  view: "list" | "timeline";
  onViewChange: (view: "list" | "timeline") => void;
  locale: HistoryLocale;
}) {
  const [snapshot, setSnapshot] = useState<HistorySnapshot | null>(null);
  const [selectedSessionId, setSelectedSessionId] = useState<string | null>(null);
  const [detail, setDetail] = useState<HistorySessionDetail | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [detailError, setDetailError] = useState<string | null>(null);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [refreshError, setRefreshError] = useState<string | null>(null);
  const [progress, setProgress] = useState<HistoryRefreshProgress | null>(null);
  const refreshRequest = useRef(0);
  const progressGeneration = useRef<number | null>(null);
  const copy =
    locale === "zh-CN"
      ? {
          refreshing: "正在扫描会话历史",
          refreshCancelled: "会话历史刷新已取消",
          refreshFailed: "会话历史刷新失败",
          refreshFailedWithDiagnostics: "会话历史刷新失败；请查看诊断信息",
          detailFailed: "无法读取会话",
        }
      : {
          refreshing: "Scanning session history",
          refreshCancelled: "Session history refresh was cancelled",
          refreshFailed: "Session history refresh failed",
          refreshFailedWithDiagnostics: "Session history refresh failed; see diagnostics",
          detailFailed: "Could not read session",
        };

  const refresh = useCallback(async () => {
    const request = ++refreshRequest.current;
    progressGeneration.current = null;
    setIsRefreshing(true);
    setRefreshError(null);
    setProgress(null);
    try {
      const terminal = await history.refresh();
      if (request !== refreshRequest.current) return;
      setSnapshot(terminal.snapshot);
      setRefreshError(
        terminal.status === "success"
          ? null
          : terminal.status === "cancelled"
            ? copy.refreshCancelled
            : copy.refreshFailedWithDiagnostics,
      );
    } catch {
      if (request !== refreshRequest.current) return;
      setRefreshError(copy.refreshFailed);
    } finally {
      if (request === refreshRequest.current) {
        setIsRefreshing(false);
        setProgress(null);
      }
    }
  }, [history, copy.refreshCancelled, copy.refreshFailed, copy.refreshFailedWithDiagnostics]);

  useEffect(() => {
    let active = true;
    void history
      .list()
      .then((initial) => {
        if (active) {
          setSnapshot((current) =>
            current && current.version > initial.version ? current : initial,
          );
        }
      })
      // 首次列表读取仅用于提前显示缓存；刷新结果是最终状态，不能让较晚失败的列表请求覆盖成功刷新。
      .catch(() => {});
    const unsubscribe = history.onRefreshEvent((event) => {
      if (!active || event.type !== "progress") return;
      // 旧视图触发的扫描可能在重进历史页时才发进度；只接受单调更新的代次。
      if (progressGeneration.current !== null && event.generation < progressGeneration.current)
        return;
      progressGeneration.current = event.generation;
      setProgress(event);
    });
    void refresh();
    return () => {
      active = false;
      ++refreshRequest.current;
      unsubscribe();
    };
  }, [history, refresh]);

  useEffect(() => {
    if (!selectedSessionId) {
      setDetail(null);
      setDetailError(null);
      setDetailLoading(false);
      return;
    }
    if (snapshot && !snapshot.sessions.some((session) => session.id === selectedSessionId)) {
      setSelectedSessionId(null);
      return;
    }
    let active = true;
    setDetail(null);
    setDetailError(null);
    setDetailLoading(true);
    void history
      .load(selectedSessionId)
      .then((result) => {
        if (active) setDetail(result);
      })
      .catch(() => {
        if (active) setDetailError(copy.detailFailed);
      })
      .finally(() => {
        if (active) setDetailLoading(false);
      });
    return () => {
      active = false;
    };
  }, [history, selectedSessionId, snapshot?.version, copy.detailFailed]);

  return (
    <div className="flex h-full min-h-0 flex-col">
      {isRefreshing && progress ? (
        <div className="px-4 py-1 text-ui-xs" role="status" aria-live="polite">
          {`${copy.refreshing} ${progress.completed}/${progress.total}`}
        </div>
      ) : null}
      <div className="min-h-0 flex-1">
        <HistoryReview
          view={view}
          onViewChange={onViewChange}
          snapshot={snapshot}
          selectedSessionId={selectedSessionId}
          detail={detail}
          detailLoading={detailLoading}
          detailError={detailError}
          isRefreshing={isRefreshing}
          refreshError={refreshError}
          onSelectSession={setSelectedSessionId}
          onRefresh={() => void refresh()}
          locale={locale}
        />
      </div>
    </div>
  );
}
