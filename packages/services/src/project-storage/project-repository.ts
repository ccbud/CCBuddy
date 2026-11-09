import { createHash, randomUUID } from "node:crypto";
import { basename } from "node:path";
import { resolveWorkspaceKey } from "@ccbuddy/shared";
import type {
  ProjectDirectories,
  ProjectRepositoryContract,
  ProjectTaskRef,
  ProjectTree,
  SaveProjectInput,
  VirtualProject,
} from "./contract.js";
import type { ProjectDataRepositoryContract } from "./purge/contract.js";
import { ensureHost, OWNERSHIP_DECIDED } from "./legacy-tasks.js";
import { assertRemoteProjectRoots, assertRemoteTaskDirectories } from "./remote-policy.js";
import {
  executionDirectoriesSchema,
  transaction,
  readProjects,
  requireProject,
  readTask,
  resolveDirectories,
  readTasks,
} from "./repository-queries.js";
import { ProjectTaskDataRepository } from "./task-data-repository.js";
export class ProjectRepository
  extends ProjectTaskDataRepository
  implements ProjectRepositoryContract, ProjectDataRepositoryContract
{
  readTree(options?: {
    includeDeleted?: boolean;
    includeDeletedTasks?: boolean;
    includeTasks?: boolean;
  }): ProjectTree {
    const read = () => ({
      projects: readProjects(this.db, options?.includeDeleted ?? false).filter(
        (project) => project.hostId === (this.ownerHostId ?? "local"),
      ),
      ...(options?.includeDeletedTasks
        ? {
            deletedTasks: this.db
              .prepare(`
        SELECT task_id AS taskId,workspace_path AS workspacePath,workspace_identity AS workspaceIdentity,host_id AS hostId
        FROM tasks WHERE host_id=? AND (deleted=1 OR coalesce(cli_deleted,0)=1)`)
              .all(this.ownerHostId ?? "local")
              .map((row) => ({
                taskId: String(row.taskId),
                workspacePath: String(row.workspacePath),
                hostId: String(row.hostId),
                ...(typeof row.workspaceIdentity === "string"
                  ? { workspaceIdentity: row.workspaceIdentity }
                  : {}),
              })),
          }
        : {}),
      tasks:
        options?.includeTasks === false
          ? []
          : readTasks(this.db).filter((task) => task.hostId === (this.ownerHostId ?? "local")),
    });
    return this.db.isTransaction ? read() : transaction(this.db, read, false);
  }

  saveProject(input: SaveProjectInput): VirtualProject {
    return transaction(this.db, () => {
      const old =
        input.id || input.restoreProjectId
          ? requireProject(this.db, input.id ?? input.restoreProjectId!)
          : undefined;
      if (input.id && old?.deleted) throw new Error("project.deleted");
      const hostId = this.ownerHostId ?? "local";
      if (old && old.hostId !== hostId) throw new Error("project.cross-host-move");
      if (input.hostId && input.hostId !== hostId) throw new Error("project.host-immutable");
      const roots = [...new Set(input.roots ?? old?.roots.map((root) => root.rootPath) ?? [])];
      assertRemoteProjectRoots(this.ownerHostId, roots, old);
      if (input.reuseExistingRoot) {
        if (hostId !== "local" || old || roots.length !== 1)
          throw new Error("project.invalid-directory-open");
        // 系统打开目录曾只建立 workspace，导致草稿没有项目；查找和创建必须在同一
        // 写事务内完成，避免多窗口并发右键创建重复项目。复用不改已有名称、roots 或排序。
        const existing = this.db
          .prepare(`
          SELECT p.project_id FROM projects p JOIN project_roots r ON r.project_id=p.project_id
          WHERE p.host_id=? AND p.deleted=0 AND r.root_path=?
          ORDER BY r.is_primary DESC,p.position,p.project_id LIMIT 1
        `)
          .get(hostId, roots[0]!);
        if (existing) return requireProject(this.db, String(existing.project_id));
      }
      if (
        input.restoreProjectId &&
        (!old?.deleted ||
          roots.length !== old.roots.length ||
          roots.some((root) => !old.roots.some((entry) => entry.rootPath === root)))
      )
        throw new Error("project.restore-roots-mismatch");
      const primary =
        input.primaryRoot ??
        old?.roots.find((root) => root.isPrimary && roots.includes(root.rootPath))?.rootPath ??
        roots[0];
      if (primary !== undefined && !roots.includes(primary))
        throw new Error("project.invalid-primary-root");
      const id = old?.id ?? randomUUID();
      const overridden =
        input.name !== undefined ? input.name.trim().length > 0 : (old?.nameOverridden ?? false);
      const baseName =
        input.name?.trim() ||
        (overridden ? old?.name : undefined) ||
        (roots[0] ? basename(roots[0]) : input.defaultName?.trim() || old?.name || "New project");
      let name = baseName;
      for (
        let suffix = 2;
        this.db
          .prepare(
            "SELECT 1 FROM projects WHERE host_id=? AND name=? AND deleted=0 AND project_id<>?",
          )
          .get(hostId, name, id);
        suffix++
      )
        name = `${baseName} (${suffix})`;
      const now = Date.now();
      // 原先用 max(position)+1 导致新建项目落在末尾；同一 Host 写事务内取最小值减一，保留已有顺序。
      this.db
        .prepare(`INSERT INTO projects(project_id,host_id,name,name_overridden,position,pinned,pinned_at,created_at,updated_at)
        VALUES(?,?,?,?,(SELECT coalesce(min(position),1)-1 FROM projects WHERE host_id=?),?,?,?,?)
        ON CONFLICT(project_id) DO UPDATE SET name=excluded.name,name_overridden=excluded.name_overridden,
        pinned=excluded.pinned,pinned_at=excluded.pinned_at,deleted=0,deleted_at=NULL,updated_at=excluded.updated_at`)
        .run(
          id,
          hostId,
          name,
          overridden ? 1 : 0,
          hostId,
          (input.pinned ?? old?.pinned) ? 1 : 0,
          (input.pinned ?? old?.pinned) ? now : null,
          now,
          now,
        );
      this.db.prepare("DELETE FROM project_roots WHERE project_id=?").run(id);
      roots.forEach((root, position) =>
        this.db
          .prepare(
            "INSERT INTO project_roots(project_id,root_path,position,is_primary) VALUES(?,?,?,?)",
          )
          .run(id, root, position, root === primary ? 1 : 0),
      );
      return requireProject(this.db, id);
    });
  }

  initializeProjectRoot(id: string, path: string): VirtualProject {
    return transaction(this.db, () => {
      const project = requireProject(this.db, id);
      if (project.hostId !== (this.ownerHostId ?? "local"))
        throw new Error("project.cross-host-move");
      if (project.deleted) throw new Error("project.deleted");
      assertRemoteProjectRoots(this.ownerHostId, [path], project);
      if (!project.roots.length) {
        this.db
          .prepare(
            "INSERT INTO project_roots(project_id,root_path,position,is_primary) VALUES(?,?,0,1)",
          )
          .run(id, path);
        this.db.prepare("UPDATE projects SET updated_at=? WHERE project_id=?").run(Date.now(), id);
      }
      return requireProject(this.db, id);
    });
  }

  deleteProject(id: string): void {
    this.db
      .prepare(
        "UPDATE projects SET deleted=1,deleted_at=?,updated_at=? WHERE project_id=? AND deleted=0 AND host_id=?",
      )
      .run(Date.now(), Date.now(), id, this.ownerHostId ?? "local");
  }

  hasProjectWorkspace(workspace: { workspacePath: string; workspaceIdentity?: string }): boolean {
    const host = this.ownerHostId ?? "local";
    // 默认任务迁移会清空任务归属，但保留已软删项目的 roots；只有活跃 root 能单独证明归属。
    // 用户删除项目后保留的任务仍由下方 project_id 判定，不能被重新划进共享池。
    return Boolean(
      this.db
        .prepare(`SELECT 1 FROM project_roots r JOIN projects p ON p.project_id=r.project_id
      WHERE p.host_id=? AND p.deleted=0 AND r.root_path=?
      UNION ALL SELECT 1 FROM tasks WHERE host_id=? AND workspace_key=? AND project_id IS NOT NULL LIMIT 1`)
        .get(host, workspace.workspacePath, host, resolveWorkspaceKey(workspace)),
    );
  }

  moveTask(input: { task: ProjectTaskRef; projectId: string; addMissingRoot?: boolean }): void {
    transaction(this.db, () => {
      const project = requireProject(this.db, input.projectId);
      if (project.deleted) throw new Error("project.deleted");
      const task = readTask(this.db, input.task);
      if (!task) throw new Error("project.task-not-found");
      if (project.hostId !== (this.ownerHostId ?? "local") || task.host_id !== project.hostId)
        throw new Error("project.cross-host-move");
      assertRemoteTaskDirectories(this.ownerHostId, project, String(task.root_path));
      if (!project.roots.some((root) => root.rootPath === task.root_path)) {
        if (!input.addMissingRoot) throw new Error("project.root-confirmation-required");
        this.db
          .prepare(
            "INSERT INTO project_roots(project_id,root_path,position,is_primary) VALUES(?,?,?,?)",
          )
          .run(
            project.id,
            String(task.root_path),
            project.roots.length,
            project.roots.length === 0 ? 1 : 0,
          );
      }
      this.db
        .prepare(
          "UPDATE tasks SET project_id=?,handoff_pending=handoff_pending | ? WHERE workspace_key=? AND task_id=?",
        )
        .run(project.id, OWNERSHIP_DECIDED, resolveWorkspaceKey(input.task), input.task.taskId);
    });
  }

  reorderProjects(ids: string[]): void {
    transaction(this.db, () => {
      if (new Set(ids).size !== ids.length) throw new Error("project.duplicate-order");
      ids.forEach((id, position) => {
        if (requireProject(this.db, id).hostId !== (this.ownerHostId ?? "local"))
          throw new Error("project.cross-host-move");
        this.db.prepare("UPDATE projects SET position=? WHERE project_id=?").run(position, id);
      });
    });
  }

  resolveSessionDirectories(task: ProjectTaskRef): ProjectDirectories {
    return transaction(this.db, () => resolveDirectories(this.db, task, this.ownerHostId), false);
  }

  private reserveForkedTask(input: {
    task: ProjectTaskRef;
    parentTaskId: string;
  }): ProjectDirectories {
    return transaction(this.db, () => {
      const parentRef = { ...input.task, taskId: input.parentTaskId };
      const parent = readTask(this.db, parentRef);
      if (
        !parent ||
        parent.deleted === 1 ||
        parent.cli_deleted === 1 ||
        input.task.taskId === input.parentTaskId
      )
        throw new Error("project.task-not-found");
      const directories = resolveDirectories(this.db, parentRef, this.ownerHostId);
      if (directories.workspacePath !== input.task.workspacePath)
        throw new Error("project.cwd-not-in-roots");
      const existing = readTask(this.db, input.task);
      if (
        existing &&
        (existing.host_id !== parent.host_id ||
          existing.root_path !== parent.root_path ||
          (existing.forked_from_task_id && existing.forked_from_task_id !== input.parentTaskId))
      )
        throw new Error("project.host-mismatch");
      if (!existing) {
        // fork 正文先由 CLI 提交；Host 在 ACK 对 UI 可见之前持久化父任务归属，避免立即打开时空归属。
        this.db
          .prepare(`INSERT INTO tasks(workspace_key,workspace_path,workspace_identity,task_id,created_at,updated_at,
          host_id,root_path,project_id,handoff_pending,execution_directories,forked_from_task_id)
          VALUES(?,?,?,?,0,0,?,?,?,?,?,?)`)
          .run(
            resolveWorkspaceKey(input.task),
            input.task.workspacePath,
            input.task.workspaceIdentity ?? null,
            input.task.taskId,
            String(parent.host_id),
            String(parent.root_path),
            directories.projectId,
            OWNERSHIP_DECIDED,
            parent.execution_directories ?? null,
            input.parentTaskId,
          );
      } else if (parent.host_id !== "local" && existing.project_id == null) {
        // sessions-index 可能先于 ACK 到达；只补同父链的缺失远端归属，重放不能覆盖用户移动。
        this.db
          .prepare(`UPDATE tasks SET project_id=?,handoff_pending=handoff_pending | ?
          WHERE workspace_key=? AND task_id=? AND project_id IS NULL`)
          .run(
            directories.projectId,
            OWNERSHIP_DECIDED,
            resolveWorkspaceKey(input.task),
            input.task.taskId,
          );
      }
      return resolveDirectories(this.db, input.task, this.ownerHostId);
    });
  }

  reserveCreatedTask(
    input: Parameters<ProjectRepositoryContract["reserveCreatedTask"]>[0],
  ): ProjectDirectories & { taskId: string } {
    if ("parentTaskId" in input)
      return { ...this.reserveForkedTask(input), taskId: input.task.taskId };
    return transaction(this.db, () => {
      const key = resolveWorkspaceKey(input.task);
      const host = ensureHost(this.db, key, this.ownerHostId);
      if (host !== (this.ownerHostId ?? "local")) throw new Error("project.cross-host-move");
      const command = input.creationCommand;
      const receipt = command
        ? this.db
            .prepare(
              "SELECT session_id FROM session_creation_commands WHERE workspace_key=? AND client_id=? AND command_id=?",
            )
            .get(key, command.clientId, command.commandId)
        : undefined;
      let taskId = input.task.taskId;
      if (receipt) {
        if (taskId !== undefined && taskId !== receipt.session_id)
          throw new Error("project.creation-id-conflict");
        taskId = String(receipt.session_id);
        if (!readTask(this.db, { ...input.task, taskId }))
          throw new Error("project.creation-task-missing");
      } else if (taskId === undefined && command) {
        // 3.16 的旧命令可能已落库；哈希只用于精确查旧行，绝不分配新的 session_ ID。
        const legacyId = `session_${createHash("sha256")
          .update(JSON.stringify([key, command.clientId, command.commandId]))
          .digest("hex")
          .slice(0, 32)}`;
        if (readTask(this.db, { ...input.task, taskId: legacyId })) taskId = legacyId;
      }
      const task = { ...input.task, taskId: taskId ?? `sess_${randomUUID()}` };
      if (!readTask(this.db, task)) {
        assertRemoteTaskDirectories(
          this.ownerHostId,
          input.projectId ? requireProject(this.db, input.projectId) : null,
          task.workspacePath,
          input.additionalDirectories,
        );
        if (input.projectId) {
          const project = requireProject(this.db, input.projectId);
          if (project.deleted && input.additionalDirectories === undefined)
            throw new Error("project.deleted");
          if (project.hostId !== host) throw new Error("project.cross-host-move");
          if (
            input.additionalDirectories === undefined &&
            !project.roots.some((root) => root.rootPath === task.workspacePath)
          )
            throw new Error("project.cwd-not-in-roots");
        }
        // 创建归属必须先于 CLI 首发；空事实不是假会话，列表只读取已有 CLI 事实的行。
        this.db
          .prepare(`INSERT INTO tasks(workspace_key,workspace_path,workspace_identity,task_id,created_at,updated_at,host_id,root_path,project_id,handoff_pending,execution_directories)
          VALUES(?,?,?,?,0,0,?,?,?,?,?)`)
          .run(
            key,
            task.workspacePath,
            task.workspaceIdentity ?? null,
            task.taskId,
            host,
            task.workspacePath,
            input.projectId,
            OWNERSHIP_DECIDED,
            input.additionalDirectories === undefined
              ? null
              : JSON.stringify(executionDirectoriesSchema.parse(input.additionalDirectories)),
          );
      }
      const directories = resolveDirectories(this.db, task, this.ownerHostId);
      // 旧客户端重试发生在 CLI 去重之前；同事务记录首次分配，避免产生额外任务预留。
      if (command && !receipt) {
        this.db
          .prepare(
            "INSERT INTO session_creation_commands(workspace_key,client_id,command_id,session_id) VALUES(?,?,?,?)",
          )
          .run(key, command.clientId, command.commandId, task.taskId);
      }
      return { ...directories, taskId: task.taskId };
    });
  }
}
