import { useCallback, useEffect, useRef, useState } from "react";
import type { ProjectTask, ProjectTree, SaveProjectInput } from "@ccbuddy/services";
import { useRemoteWorkspaceSessionStore } from "@/store/remoteWorkspaceSessionStore.js";
import { useBaseWorkspaceServices } from "@/hooks/useWorkspaceServices.js";

export function useProjectTree(remoteSessionId?: string) {
  const base = useBaseWorkspaceServices();
  const remote = useRemoteWorkspaceSessionStore((state) =>
    remoteSessionId ? state.sessionsById[remoteSessionId]?.services : undefined,
  );
  const boundIdentities = useRemoteWorkspaceSessionStore(
    (state) => state.sessionIdByWorkspaceIdentity,
  );
  const services = remoteSessionId ? remote : base;
  const service = services?.projectService;
  const activeService = useRef(service);
  activeService.current = service;
  const [tree, setTree] = useState<ProjectTree>({ projects: [], tasks: [] });
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const sequence = useRef(0);
  const refresh = useCallback(async () => {
    if (!service) return;
    const request = ++sequence.current;
    try {
      const result = await service.readTree({ includeDeleted: true });
      if (request === sequence.current && activeService.current === service) {
        setTree(result);
        setError(null);
      }
    } catch (failure) {
      if (request === sequence.current && activeService.current === service)
        setError(String(failure));
    }
  }, [service]);
  useEffect(() => {
    setTree({ projects: [], tasks: [] });
    void refresh();
    const subscription = services?.broadcastService?.onMessage((message) => {
      if (message.channel === "project:changed" || message.channel.includes("task")) void refresh();
    });
    return () => {
      sequence.current++;
      subscription?.dispose();
    };
  }, [refresh, services]);
  const workspaces = JSON.stringify([
    ...new Set([
      ...(!remoteSessionId
        ? tree.projects.flatMap((project) =>
            project.roots.map((root) => JSON.stringify({ workspacePath: root.rootPath })),
          )
        : []),
      ...tree.tasks
        .filter(
          (task) =>
            !remoteSessionId || (task.workspaceIdentity && boundIdentities[task.workspaceIdentity]),
        )
        .map((task) =>
          JSON.stringify({
            workspacePath: task.workspacePath,
            workspaceIdentity: task.workspaceIdentity,
          }),
        ),
    ]),
  ]);
  useEffect(() => {
    if (!services) return;
    const subscriptions = (JSON.parse(workspaces) as string[]).map((encoded) =>
      services!.ccbuddyTaskService.onDynamicWorkspaceEvent(JSON.parse(encoded))(
        () => void refresh(),
      ),
    );
    return () => subscriptions.forEach((subscription) => subscription.dispose());
  }, [refresh, services?.ccbuddyTaskService, workspaces]);
  const run = useCallback(
    async <Result>(operation: () => Promise<Result>): Promise<Result | undefined> => {
      setBusy(true);
      try {
        const result = await operation();
        await refresh();
        return result;
      } catch (failure) {
        setError(String(failure));
        return undefined;
      } finally {
        setBusy(false);
      }
    },
    [refresh],
  );
  return {
    available: Boolean(service),
    readOnly: tree.legacySingleRoot === true,
    remote: Boolean(remoteSessionId),
    tree,
    error,
    busy,
    refresh,
    restart: (task: ProjectTask) =>
      run(() =>
        services!.ccbuddyAgentService.restartSessionRuntime({ ...task, sessionId: task.taskId }),
      ),
    save: (input: SaveProjectInput) => run(() => service!.saveProject(input)),
    remove: (id: string) => run(() => service!.deleteProject(id)),
    restore: (id: string) => run(() => service!.restoreProject(id)),
    measure: (id: string) => run(() => service!.measureProjectData([id])),
    purge: (id: string) => run(() => service!.deleteProjectData(id)),
    prepare: (id: string) => run(() => service!.prepareSession({ projectId: id })),
    reorder: (ids: string[]) => run(() => service!.reorderProjects(ids)),
    move: (task: ProjectTask, projectId: string, addMissingRoot: boolean) =>
      run(() => service!.moveTask({ task, projectId, addMissingRoot })),
    archive: (task: ProjectTask) =>
      run(() =>
        task.archived
          ? services!.ccbuddyTaskService.unarchiveTask(task)
          : services!.ccbuddyTaskService.archiveTask(task),
      ),
    pin: (task: ProjectTask) =>
      run(() => services!.ccbuddyTaskService.setTaskPinned({ ...task, pinned: !task.pinned })),
  };
}
