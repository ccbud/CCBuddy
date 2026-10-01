import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type {
  HistoryLocale,
  HistoryRefreshEvent,
  HistoryRefreshProgress,
  HistoryRefreshTerminal,
  HistorySessionActions,
  HistorySessionDetail,
  HistorySnapshot,
} from "./contract.js";
import { HistoryReview } from "./HistoryReview.js";
import { HistoryRootsDialog, type HistoryRootsManagement } from "./HistoryRootsDialog.js";

export interface HistoryReadBridge {
  readonly protocolVersion: 1;
  list(): Promise<HistorySnapshot>;
  load(id: string): Promise<HistorySessionDetail>;
  refresh(): Promise<HistoryRefreshTerminal>;
  onRefreshEvent(listener: (event: HistoryRefreshEvent) => void): () => void;
}

const COPY = {
  "zh-CN": {
    refreshing: "正在扫描会话历史",
    refreshCancelled: "会话历史刷新已取消",
    refreshFailed: "会话历史刷新失败",
    refreshFailedWithDiagnostics: "会话历史刷新失败；请查看诊断信息",
    rootsUnreadable: "部分来源目录无法读取；其余会话可正常查看（见读取提示）",
    filesUnreadable: (count: number) =>
      `${count} 条会话记录无法读取；其余会话可正常查看（见读取提示）`,
    detailFailed: "无法读取会话",
    continueFailed: "无法在 CCbuddy 继续此会话",
  },
  "en-US": {
    refreshing: "Scanning session history",
    refreshCancelled: "Session history refresh was cancelled",
    refreshFailed: "Session history refresh failed",
    refreshFailedWithDiagnostics: "Session history refresh failed; see diagnostics",
    rootsUnreadable:
      "Some source folders could not be read; other sessions are available (see diagnostics)",
    filesUnreadable: (count: number) =>
      `${count} session records could not be read; other sessions are available (see diagnostics)`,
    detailFailed: "Could not read session",
    continueFailed: "Could not continue this session in CCbuddy",
  },
} as const;

export function HistoryReviewController({
  history,
  view,
  onViewChange,
  locale,
  actions,
  rootsManagement,
}: {
  history: HistoryReadBridge;
  view: "list" | "timeline";
  onViewChange: (view: "list" | "timeline") => void;
  locale: HistoryLocale;
  actions?: HistorySessionActions;
  rootsManagement?: HistoryRootsManagement;
}) {
  const [snapshot, setSnapshot] = useState<HistorySnapshot | null>(null);
  const [selectedSessionId, setSelectedSessionId] = useState<string | null>(null);
  const [detail, setDetail] = useState<HistorySessionDetail | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [detailError, setDetailError] = useState<string | null>(null);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [refreshError, setRefreshError] = useState<string | null>(null);
  const [refreshSeverity, setRefreshSeverity] = useState<"error" | "warning">("error");
  const [progress, setProgress] = useState<HistoryRefreshProgress | null>(null);
  const [continuing, setContinuing] = useState(false);
  const [continueError, setContinueError] = useState<string | null>(null);
  const [rootsOpen, setRootsOpen] = useState(false);
  const refreshRequest = useRef(0);
  const progressGeneration = useRef<number | null>(null);
  const copy = COPY[locale];

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
      if (terminal.status === "success") {
        setRefreshError(null);
      } else if (terminal.status === "cancelled") {
        setRefreshSeverity("error");
        setRefreshError(copy.refreshCancelled);
      } else {
        // 个别记录读不出来是常态（损坏行、旧版本数据库）；只要目录仍可读、会话已列出，就不用红色失败横幅吓人。
        const { diagnostics, sessions } = terminal.snapshot;
        const rootsFailed = diagnostics.some((item) => item.code === "unreadable_root");
        const unreadable = diagnostics.filter(
          (item) => item.code !== "malformed_record" && item.code !== "unreadable_root",
        ).length;
        if (sessions.length === 0) {
          setRefreshSeverity("error");
          setRefreshError(copy.refreshFailedWithDiagnostics);
        } else {
          setRefreshSeverity("warning");
          setRefreshError(rootsFailed ? copy.rootsUnreadable : copy.filesUnreadable(unreadable));
        }
      }
    } catch {
      if (request !== refreshRequest.current) return;
      setRefreshSeverity("error");
      setRefreshError(copy.refreshFailed);
    } finally {
      if (request === refreshRequest.current) {
        setIsRefreshing(false);
        setProgress(null);
      }
    }
  }, [
    history,
    copy.refreshCancelled,
    copy.refreshFailed,
    copy.refreshFailedWithDiagnostics,
    copy.rootsUnreadable,
    copy.filesUnreadable,
  ]);

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
    setContinueError(null);
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

  // 导入是用户发起的写路径；进行中与失败只属于这个视图，不进入只读快照。
  const wrappedActions = useMemo<HistorySessionActions | undefined>(() => {
    const continueSession = actions?.continueSession;
    if (!continueSession) return undefined;
    return {
      continueSession: async (target) => {
        setContinuing(true);
        setContinueError(null);
        try {
          await continueSession(target);
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          setContinueError(message ? `${copy.continueFailed}: ${message}` : copy.continueFailed);
        } finally {
          setContinuing(false);
        }
      },
    };
  }, [actions?.continueSession, copy.continueFailed]);

  const wrappedRoots = useMemo<HistoryRootsManagement | undefined>(() => {
    if (!rootsManagement) return undefined;
    return {
      ...rootsManagement,
      addRoot: async (root) => {
        await rootsManagement.addRoot(root);
        void refresh();
      },
      removeRoot: async (path) => {
        await rootsManagement.removeRoot(path);
        void refresh();
      },
    };
  }, [refresh, rootsManagement]);

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
          refreshSeverity={refreshSeverity}
          onSelectSession={setSelectedSessionId}
          onRefresh={() => void refresh()}
          locale={locale}
          actions={wrappedActions}
          continuing={continuing}
          continueError={continueError}
          onManageRoots={wrappedRoots ? () => setRootsOpen(true) : undefined}
        />
      </div>
      {wrappedRoots ? (
        <HistoryRootsDialog
          open={rootsOpen}
          onOpenChange={setRootsOpen}
          roots={snapshot?.roots ?? []}
          management={wrappedRoots}
          locale={locale}
        />
      ) : null}
    </div>
  );
}
