import { useEffect, useLayoutEffect, useRef } from "react";
import { useOptionalPlatform } from "@/hooks/usePlatform.js";
import type {
  AppNavigationHandler,
  ProjectSidebarProps,
  ProjectTaskNavigation,
  ProjectTree,
} from "@/project-sidebar/contract.js";

/** 桌面只登记既有导航 owner。 */
export function useAppControlNavigation(
  props: Pick<ProjectSidebarProps, "isDesktop">,
  tree: ProjectTree,
  navigate: ProjectTaskNavigation,
): void {
  const platform = useOptionalPlatform();
  const latest = useRef({ tree, navigate });
  useLayoutEffect(() => {
    latest.current = { tree, navigate };
  });
  useEffect(() => {
    if (!props.isDesktop || !platform?.onAppControlNavigation) return;
    const lifetime = new AbortController();
    const handler: AppNavigationHandler = async (target, signal) => {
      const activeSignal = AbortSignal.any([signal, lifetime.signal]);
      if (activeSignal.aborted)
        return { status: "unavailable", reason: "project.navigation-cancelled" };
      const { tree, navigate } = latest.current;
      const task = tree.tasks.find(
        (task) =>
          task.taskId === target.taskId &&
          (task.workspaceIdentity || task.workspacePath) ===
            (target.workspaceIdentity || target.workspacePath),
      );
      if (!task) return { status: "unavailable", reason: "project.task-not-found" };
      const result = await navigate(
        target.workspacePath,
        target.taskId,
        target.workspaceIdentity,
        undefined,
        task.unreadAt,
        { signal: activeSignal },
      );
      return activeSignal.aborted
        ? { status: "unavailable", reason: "project.navigation-cancelled" }
        : result;
    };
    const unregister = platform.onAppControlNavigation(handler);
    return () => {
      lifetime.abort();
      unregister();
    };
  }, [platform, props.isDesktop]);
}
