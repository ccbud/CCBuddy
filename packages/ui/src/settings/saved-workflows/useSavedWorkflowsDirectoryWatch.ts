import { useEffect } from "react";
import type { IFileWatcherService } from "@ccbuddy/services";
import { logger } from "@/logger.js";

const WATCH_DEBOUNCE_MS = 300;

/**
 * 目录监听：对话里 SaveWorkflow 落盘后中枢自动更新。
 * 目录不存在时 watch 会失败——那是常态（大多数项目没保存过工作流），静默跳过，靠切标签 / 手动
 * 刷新补上。非递归：只看这一层（Linux 上递归 fs.watch 有既知问题）。服务实例变化（远程重连）时
 * effect 依赖变化会拆掉旧 watcher 重建，旧 host 的 id 不会泄漏。
 *
 * 项目组和全局组都使用协议 list 返回的绝对目录。工作区状态 key 由 Agent 根据逻辑 identity
 * 决定，Renderer 不能从物理 workspacePath 重算。
 */
export function useSavedWorkflowsDirectoryWatch({
  fileWatcherService,
  directory,
  enabled,
  refresh,
}: {
  fileWatcherService: IFileWatcherService;
  directory?: string | null | undefined;
  enabled: boolean;
  refresh: (options: { bypassCache?: boolean }) => Promise<void>;
}): void {
  const resolvedDirectory = directory ?? null;
  useEffect(() => {
    if (!enabled || !resolvedDirectory) return;
    let disposed = false;
    let watchId: string | null = null;
    let subscription: { dispose: () => void } | null = null;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const directoryPath = resolvedDirectory;
    void fileWatcherService
      .watch({ path: directoryPath })
      .then(({ id }) => {
        if (disposed) {
          void fileWatcherService.unwatch({ id });
          return;
        }
        watchId = id;
        subscription = fileWatcherService.onDynamicChange(id)(() => {
          if (timer) clearTimeout(timer);
          timer = setTimeout(() => {
            timer = null;
            void refresh({ bypassCache: true });
          }, WATCH_DEBOUNCE_MS);
        });
      })
      .catch((error: unknown) => {
        logger.debug("[SavedWorkflows] 监听工作流目录失败（目录可能尚不存在）", {
          path: directoryPath,
          error: error instanceof Error ? error.message : String(error),
        });
      });
    return () => {
      disposed = true;
      if (timer) clearTimeout(timer);
      subscription?.dispose();
      if (watchId) void fileWatcherService.unwatch({ id: watchId });
    };
  }, [enabled, fileWatcherService, refresh, resolvedDirectory]);
}
