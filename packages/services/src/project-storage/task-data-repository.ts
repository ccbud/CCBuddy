import type { DatabaseSync } from "node:sqlite";
import { resolveWorkspaceKey, isRemoteWorkspaceIdentity } from "@ccbuddy/shared";
import type { AutoArchiveInput, ProjectTaskRef } from "./contract.js";
import { transaction, readTask, readProjects, tableExists } from "./repository-queries.js";
export class ProjectTaskDataRepository {
  constructor(
    protected readonly db: DatabaseSync,
    protected readonly ownerHostId?: string,
  ) {}
  archiveInactive(input: AutoArchiveInput): ProjectTaskRef[] {
    return transaction(this.db, () => {
      const active = new Set(
        input.activeTasks.map((task) => JSON.stringify([resolveWorkspaceKey(task), task.taskId])),
      );
      // 2026-09-15 裁决：纯按 CLI 最后活动时间归档，不再看 last_outcome 与未读；
      // 只有置顶和 syncer 观察到的运行中会话除外。旧判据把 error / 无结果的老会话永远留在列表里。
      const candidates = this.db
        .prepare(`SELECT workspace_key,workspace_path,workspace_identity,task_id FROM tasks
        WHERE archived=0 AND pinned=0 AND deleted=0 AND coalesce(cli_deleted,0)=0
        AND cli_updated_at < ? AND host_id=?`)
        .all(input.cutoff, this.ownerHostId ?? "local");
      const result: ProjectTaskRef[] = [];
      for (const row of candidates) {
        if (active.has(JSON.stringify([row.workspace_key, row.task_id]))) continue;
        this.db
          .prepare("UPDATE tasks SET archived=1 WHERE workspace_key=? AND task_id=?")
          .run(row.workspace_key!, row.task_id!);
        result.push({
          workspacePath: String(row.workspace_path),
          taskId: String(row.task_id),
          workspaceIdentity:
            row.workspace_identity === row.workspace_key
              ? String(row.workspace_identity)
              : isRemoteWorkspaceIdentity(String(row.workspace_key))
                ? String(row.workspace_key)
                : undefined,
        });
      }
      return result;
    });
  }

  readProjectTaskRefs(id: string): Array<ProjectTaskRef & { cwd: string }> {
    return this.db
      .prepare("SELECT * FROM tasks WHERE project_id=? AND host_id=? ORDER BY task_id")
      .all(id, this.ownerHostId ?? "local")
      .map((row) => ({
        taskId: String(row.task_id),
        workspacePath: String(row.workspace_path),
        ...(row.workspace_identity == null
          ? {}
          : { workspaceIdentity: String(row.workspace_identity) }),
        cwd: String(row.root_path ?? row.workspace_path),
      }));
  }

  readTaskDirectories(): Array<{ projectId: string | null; cwd: string }> {
    return this.db
      .prepare(
        "SELECT DISTINCT project_id, coalesce(root_path, workspace_path) AS cwd FROM tasks WHERE host_id=? AND deleted=0",
      )
      .all(this.ownerHostId ?? "local")
      .map((row) => ({
        projectId: row.project_id == null ? null : String(row.project_id),
        cwd: String(row.cwd),
      }));
  }

  purgeTasks(tasks: readonly ProjectTaskRef[]): void {
    const host = this.ownerHostId ?? "local";
    // 分组准入表只在新版本库里存在；旧库或测试库缺表时没有可删的行。
    const admissions = tableExists(this.db, "task_group_admissions");
    transaction(this.db, () => {
      for (const task of tasks) {
        const key = resolveWorkspaceKey(task);
        const row = readTask(this.db, task);
        if (row && row.host_id !== host) continue;
        this.db
          .prepare("DELETE FROM tasks WHERE workspace_key=? AND task_id=?")
          .run(key, task.taskId);
        this.db
          .prepare("DELETE FROM task_group_members WHERE workspace_key=? AND task_id=?")
          .run(key, task.taskId);
        if (admissions)
          this.db
            .prepare("DELETE FROM task_group_admissions WHERE workspace_key=? AND task_id=?")
            .run(key, task.taskId);
      }
    });
  }

  markTasksDeleted(tasks: readonly ProjectTaskRef[]): void {
    const host = this.ownerHostId ?? "local";
    transaction(this.db, () => {
      for (const task of tasks)
        this.db
          .prepare(
            "UPDATE tasks SET deleted=1,cli_deleted=1,handoff_pending=handoff_pending & ~1 WHERE workspace_key=? AND task_id=? AND host_id=?",
          )
          .run(resolveWorkspaceKey(task), task.taskId, host);
    });
  }

  purgeProjectIfUnreferenced(id: string): boolean {
    return transaction(this.db, () => {
      const project = readProjects(this.db).find((entry) => entry.id === id);
      if (!project?.deleted || project.hostId !== (this.ownerHostId ?? "local")) return false;
      // 被保留的运行中会话、定时与闲时定义仍指向它时保持软删除：删掉会让它们指向不存在的项目。
      const referenced = ["tasks", "automations", "off_peak_tasks"].some(
        (table) =>
          this.db.prepare(`SELECT 1 FROM ${table} WHERE project_id=? LIMIT 1`).get(id) !==
          undefined,
      );
      if (referenced) return false;
      this.db.prepare("DELETE FROM project_roots WHERE project_id=?").run(id);
      this.db.prepare("DELETE FROM projects WHERE project_id=?").run(id);
      return true;
    });
  }
}
