import { useCallback, useEffect } from "react";
import type { IPlatformService } from "@ccbuddy/shared";
import type { WorkspaceMainView } from "./types.js";

/** App 保持主视图唯一所有权，平台菜单只通过已有导航入口请求切换。 */
export function useHistoryMainViewNavigation({
  platform,
  preserveNextSettingsExit,
  runVisibleWorkspaceCommand,
  onWorkspaceMainViewChange,
}: {
  platform: Pick<IPlatformService, "onOpenHistoryViewRequested">;
  preserveNextSettingsExit: () => void;
  runVisibleWorkspaceCommand: (command: () => void) => void;
  onWorkspaceMainViewChange: (view: WorkspaceMainView) => void;
}) {
  const openHistoryView = useCallback(
    (view: "list" | "timeline") => {
      // 修复原因：上游没有历史主视图，移植时丢失菜单订阅；设置层退出也不能把同一历史目标改回 chat。
      preserveNextSettingsExit();
      runVisibleWorkspaceCommand(() => {
        onWorkspaceMainViewChange(view === "list" ? "history-list" : "history-timeline");
      });
    },
    [onWorkspaceMainViewChange, preserveNextSettingsExit, runVisibleWorkspaceCommand],
  );
  useEffect(
    () => platform.onOpenHistoryViewRequested?.(openHistoryView),
    [openHistoryView, platform],
  );
}
