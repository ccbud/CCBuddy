// 侧栏项目下"正在创建 worktree"的任务行（docs/git/worktree.md §3.3）。
// 行集合只来自 Host 的创建记录；点击后切到项目 workspace，并在主区展示这条记录。
import { LoaderCircle, TriangleAlertIcon } from "lucide-react";
import { memo, useCallback } from "react";
import type { ManagedWorktreeCreation } from "@ccbuddy/shared";
import { TID_WORKTREE_CREATING_ROW } from "@ccbuddy/shared/test-ids";
import { cn } from "@/components/lib/utils.js";
import { useCCbuddyIntl } from "@/i18n/IntlProvider.js";
import { useTabStoreApi } from "@/store/TabStoreProvider.js";
import { useCCbuddySessionStore } from "@/store/ccbuddySessionStore.js";
import { useManagedWorktreeCreations } from "./useManagedWorktreeCreations.js";

export const ManagedWorktreeCreatingRows = memo(function ManagedWorktreeCreatingRows({
  projectId,
}: {
  projectId: string;
}) {
  const creations = useManagedWorktreeCreations().filter(
    (creation) => creation.projectId === projectId,
  );
  if (creations.length === 0) return null;
  return (
    <>
      {creations.map((creation) => (
        <CreatingRow key={creation.id} creation={creation} />
      ))}
    </>
  );
});

function CreatingRow({ creation }: { creation: ManagedWorktreeCreation }) {
  const { intl } = useCCbuddyIntl();
  const tabStore = useTabStoreApi();
  const viewWorktreeCreation = useCCbuddySessionStore((state) => state.viewWorktreeCreation);
  const active = useCCbuddySessionStore((state) => {
    const workspace = state.getWorkspaceState(creation.workspacePath);
    return workspace.activeTaskId === null && workspace.draftWorktreeCreationId === creation.id;
  });
  const open = useCallback(() => {
    const tabs = tabStore.getState();
    if (!tabs.activateTabByPath(creation.workspacePath)) tabs.addTab(creation.workspacePath);
    viewWorktreeCreation(creation.workspacePath, creation.id);
  }, [creation.id, creation.workspacePath, tabStore, viewWorktreeCreation]);
  const failed = creation.phase === "failed";
  const title =
    creation.promptText?.trim() ||
    intl.formatMessage({ id: "git.managedWorktree.creation.forkTitle" });
  return (
    <div className="py-px">
      <button
        type="button"
        data-testid={TID_WORKTREE_CREATING_ROW}
        data-phase={creation.phase}
        onClick={open}
        className={cn(
          "flex h-8 w-full min-w-0 items-center gap-2 rounded-lg px-2 text-left text-ui-base",
          active ? "bg-selected" : "hover:bg-surface-hover",
        )}
      >
        <span className="min-w-0 flex-1 truncate text-foreground">{title}</span>
        <span className="flex shrink-0 items-center gap-1 text-ui-sm text-foreground-subtle">
          {failed ? (
            <TriangleAlertIcon className="size-3.5 text-destructive" />
          ) : (
            <LoaderCircle className="size-3.5 animate-spin" />
          )}
          {intl.formatMessage({
            id: failed
              ? "git.managedWorktree.creation.failed"
              : "git.managedWorktree.creation.sidebarRow",
          })}
        </span>
      </button>
    </div>
  );
}
