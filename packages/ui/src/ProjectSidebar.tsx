import { useState } from "react";
import { useConfirmDialog } from "@/hooks/useConfirmDialog.js";
import {
  Archive,
  ArrowUp,
  FolderPlus,
  MoreHorizontal,
  RefreshCw,
  Pencil,
  Pin,
  Plus,
  RotateCcw,
  Trash2,
} from "lucide-react";
import type { VirtualProject } from "@ccbuddy/services";
import type { CreateTaskRequest } from "@/app-shell/types.js";
import { useRemoteWorkspaceSessionStore } from "@/store/remoteWorkspaceSessionStore.js";
import { useProjectTree } from "@/hooks/useProjectTree.js";
import { useCCbuddyIntl } from "@/i18n/IntlProvider.js";
import { Button } from "@/components/ui/button.js";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu.js";
import { ProjectEditorDialog } from "@/ProjectEditorDialog.js";

export function ProjectSidebar({
  onCreateTask,
  onSelectTask,
  remoteSessionId,
  onSelectRemoteProject,
}: {
  remoteSessionId?: string;
  onSelectRemoteProject?(sessionId: string, path: string): Promise<void>;
  onCreateTask(request?: CreateTaskRequest): void;
  onSelectTask(
    path: string,
    taskId: string,
    identity?: string,
    remoteSessionId?: string,
    unreadAt?: number,
  ): void;
}) {
  const manager = useProjectTree(remoteSessionId);
  const [navigationError, setNavigationError] = useState<string | null>(null);
  const bindWorkspace = async (path: string, identity?: string) => {
    if (!remoteSessionId) return undefined;
    if (!identity || !onSelectRemoteProject) throw new Error("project.host-offline");
    let state = useRemoteWorkspaceSessionStore.getState();
    if (!state.sessionIdByWorkspaceIdentity[identity]) {
      await onSelectRemoteProject(remoteSessionId, path);
      state = useRemoteWorkspaceSessionStore.getState();
    }
    const bound = state.sessionIdByWorkspaceIdentity[identity];
    if (!bound || !state.sessionsById[bound]) throw new Error("project.host-offline");
    return bound;
  };
  const navigate = async (operation: () => Promise<void>) => {
    try {
      await operation();
      setNavigationError(null);
    } catch (error) {
      setNavigationError(String(error));
    }
  };
  const confirm = useConfirmDialog();
  const { intl } = useCCbuddyIntl();
  const message = (key: string) => intl.formatMessage({ id: `projectManager.${key}` });
  const [editing, setEditing] = useState<VirtualProject | null | undefined>();
  const [removed, setRemoved] = useState(false);
  const [archived, setArchived] = useState(false);
  const [deletionResult, setDeletionResult] = useState<string | null>(null);
  const purge = async (project: VirtualProject) => {
    const measured = await manager.measure(project.id);
    if (!measured) return;
    const bytes = measured.projects.reduce(
      (sum, entry) => sum + entry.sessionBytes + entry.memoryBytes + entry.checkpointBytes,
      0,
    );
    if (
      !(await confirm({
        title: message("purge"),
        description: intl.formatMessage(
          { id: "projectManager.purgeConfirm" },
          { name: project.name, bytes },
        ),
        confirmLabel: message("purge"),
        confirmVariant: "destructive",
        testId: "project-purge-confirm",
      }))
    )
      return;
    const result = await manager.purge(project.id);
    if (result)
      setDeletionResult(intl.formatMessage({ id: "projectManager.purgeResult" }, { ...result }));
  };
  if (!manager.available) return null;
  const projects = manager.tree.projects.filter((project) => project.deleted === removed);
  const ordered = [...projects].sort(
    (left, right) => Number(right.pinned) - Number(left.pinned) || left.position - right.position,
  );
  const iconButton = "size-6 shrink-0 text-foreground-subtle hover:text-foreground";
  return (
    <section className="mb-2 text-ui-base" data-testid="virtual-projects">
      <div className="flex items-center gap-1 px-2 py-1 text-foreground-subtle">
        <span className="min-w-0 flex-1 truncate">
          {message(manager.remote ? "remoteTitle" : "title")}
        </span>
        <Button
          variant="ghost"
          size="icon"
          className={iconButton}
          aria-label={message("archives")}
          aria-pressed={archived}
          onClick={() => setArchived(!archived)}
        >
          <Archive className="size-3.5" />
        </Button>
        <Button
          variant="ghost"
          size="icon"
          className={iconButton}
          aria-label={message("removed")}
          aria-pressed={removed}
          onClick={() => setRemoved(!removed)}
        >
          <Trash2 className="size-3.5" />
        </Button>
        <Button
          variant="ghost"
          size="icon"
          className={iconButton}
          aria-label={message("create")}
          disabled={manager.readOnly || manager.busy}
          onClick={() => setEditing(null)}
          data-testid="project-create"
        >
          <FolderPlus className="size-3.5" />
        </Button>
      </div>
      {deletionResult && (
        <div role="status" className="break-words px-2 text-ui-caption text-foreground-subtle">
          {deletionResult}
        </div>
      )}
      {navigationError && (
        <div role="alert" className="break-words px-2 text-ui-caption text-destructive">
          {navigationError}
        </div>
      )}
      {manager.error && (
        <div role="alert" className="break-words px-2 text-ui-caption text-destructive">
          {manager.error}
        </div>
      )}
      {!ordered.length && (
        <div className="px-2 py-1 text-ui-caption text-foreground-subtle">{message("empty")}</div>
      )}
      {ordered.map((project, index) => (
        <details
          key={project.id}
          open
          className="rounded-md"
          data-testid="project-node"
          data-project-id={project.id}
        >
          <summary className="flex cursor-pointer items-center gap-1 rounded-md px-2 py-1 hover:bg-surface-hover">
            <span
              className="min-w-0 flex-1 truncate"
              title={project.roots.map((root) => root.rootPath).join("\n")}
            >
              {project.name}
            </span>
            {project.primaryRootStatus && project.primaryRootStatus !== "available" && (
              <span className="text-ui-caption text-destructive">{message("missing")}</span>
            )}
            {!removed && (
              <Button
                variant="ghost"
                size="icon"
                className={iconButton}
                disabled={
                  manager.busy ||
                  project.primaryRootStatus === "missing" ||
                  project.primaryRootStatus === "unavailable"
                }
                aria-label={message("newTask")}
                onClick={(event) => {
                  event.preventDefault();
                  void navigate(async () => {
                    const prepared = await manager.prepare(project.id);
                    if (prepared) {
                      await bindWorkspace(prepared.workspacePath, prepared.workspaceIdentity);
                      onCreateTask({
                        projectId: manager.readOnly ? undefined : project.id,
                        targetWorkspace: prepared,
                      });
                    }
                  });
                }}
                data-testid="project-new-task"
              >
                <Plus className="size-3.5" />
              </Button>
            )}
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button
                  variant="ghost"
                  size="icon"
                  className={iconButton}
                  disabled={manager.busy || manager.readOnly}
                  aria-label={message("actions")}
                  data-testid="project-actions"
                  onClick={(event) => event.stopPropagation()}
                >
                  <MoreHorizontal className="size-3.5" />
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end" onClick={(event) => event.stopPropagation()}>
                {removed ? (
                  <>
                    <DropdownMenuItem onSelect={() => void manager.restore(project.id)}>
                      <RotateCcw className="size-3.5" />
                      {message("restore")}
                    </DropdownMenuItem>
                    <DropdownMenuItem
                      disabled={manager.remote}
                      variant="destructive"
                      onSelect={() => void purge(project)}
                      data-testid="project-purge"
                    >
                      <Trash2 className="size-3.5" />
                      {message("purge")}
                    </DropdownMenuItem>
                  </>
                ) : (
                  <>
                    <DropdownMenuItem onSelect={() => setEditing(project)}>
                      <Pencil className="size-3.5" />
                      {message("edit")}
                    </DropdownMenuItem>
                    <DropdownMenuItem
                      onSelect={() =>
                        void manager.save({ id: project.id, pinned: !project.pinned })
                      }
                    >
                      <Pin className="size-3.5" />
                      {message("pin")}
                    </DropdownMenuItem>
                    <DropdownMenuItem
                      disabled={index === 0}
                      onSelect={() => {
                        const ids = ordered.map((item) => item.id);
                        [ids[index - 1], ids[index]] = [ids[index]!, ids[index - 1]!];
                        void manager.reorder(ids);
                      }}
                    >
                      <ArrowUp className="size-3.5" />
                      {message("up")}
                    </DropdownMenuItem>
                    <DropdownMenuItem onSelect={() => void manager.remove(project.id)}>
                      <Trash2 className="size-3.5" />
                      {message("remove")}
                    </DropdownMenuItem>
                  </>
                )}
              </DropdownMenuContent>
            </DropdownMenu>
          </summary>
          <ul className="ml-3 border-l border-border pl-1">
            {manager.tree.tasks
              .filter(
                (task) => task.projectId === project.id && Boolean(task.archived) === archived,
              )
              .map((task) => (
                <li
                  key={`${task.workspaceIdentity ?? task.workspacePath}:${task.taskId}`}
                  className="flex items-center gap-1"
                >
                  <button
                    className="min-w-0 flex-1 truncate rounded-md px-2 py-1 text-left hover:bg-surface-hover"
                    title={task.workspacePath}
                    onClick={() =>
                      void navigate(async () => {
                        const bound = await bindWorkspace(
                          task.workspacePath,
                          task.workspaceIdentity,
                        );
                        onSelectTask(
                          task.workspacePath,
                          task.taskId,
                          task.workspaceIdentity,
                          bound,
                          task.unreadAt,
                        );
                      })
                    }
                  >
                    {task.title || task.taskId}
                  </button>
                  <Button
                    variant="ghost"
                    size="icon"
                    className={iconButton}
                    disabled={manager.busy}
                    aria-label={message("pin")}
                    aria-pressed={task.pinned}
                    onClick={() => void manager.pin(task)}
                  >
                    <Pin className="size-3" />
                  </Button>
                  <Button
                    variant="ghost"
                    size="icon"
                    className={iconButton}
                    disabled={manager.busy}
                    aria-label={message(task.archived ? "unarchive" : "archive")}
                    onClick={() => void manager.archive(task)}
                  >
                    <Archive className="size-3" />
                  </Button>
                  <Button
                    variant="ghost"
                    size="icon"
                    className={iconButton}
                    disabled={manager.busy}
                    aria-label={message("restart")}
                    onClick={() =>
                      void navigate(async () => {
                        await bindWorkspace(task.workspacePath, task.workspaceIdentity);
                        await manager.restart(task);
                      })
                    }
                  >
                    <RefreshCw className="size-3" />
                  </Button>
                  <select
                    className="w-7 bg-transparent text-ui-caption"
                    aria-label={message("move")}
                    value=""
                    disabled={manager.busy || manager.readOnly}
                    onChange={(event) => {
                      const target = manager.tree.projects.find(
                        (item) => item.id === event.target.value,
                      );
                      if (target)
                        void (async () => {
                          const missing = !target.roots.some(
                            (root) => root.rootPath === task.workspacePath,
                          );
                          if (
                            missing &&
                            !(await confirm({
                              title: message("addRoot"),
                              description: task.workspacePath,
                            }))
                          )
                            return;
                          await manager.move(task, target.id, missing);
                        })();
                    }}
                  >
                    <option value="">↗</option>
                    {manager.tree.projects
                      .filter(
                        (item) =>
                          !item.deleted && item.hostId === task.hostId && item.id !== project.id,
                      )
                      .map((item) => (
                        <option value={item.id} key={item.id}>
                          {item.name}
                        </option>
                      ))}
                  </select>
                </li>
              ))}
          </ul>
        </details>
      ))}
      {editing !== undefined && (
        <ProjectEditorDialog
          key={editing?.id ?? "new"}
          project={editing}
          busy={manager.busy}
          error={manager.error}
          onSave={manager.save}
          onClose={() => setEditing(undefined)}
        />
      )}
    </section>
  );
}
