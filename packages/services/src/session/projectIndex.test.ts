import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";
import { TaskIndexRepo } from "./taskIndexRepo.js";
import { markTasksStoragePrepared } from "./tasksDatabase/prepared.js";
import { runTasksDatabaseMigrations } from "./tasksDatabase/migrations.js";
import type { CCbuddyTaskMeta } from "@ccbuddy/shared";

it("upgrades prepared databases and keeps project ownership separate from CLI snapshots", async () => {
  const root = await mkdtemp(join(tmpdir(), "ccbuddy-project-index-"));
  const path = join(root, "tasks.sqlite");
  const db = new DatabaseSync(path);
  runTasksDatabaseMigrations(db);
  markTasksStoragePrepared(path);
  db.close();
  let settingsReads = 0;
  const repo = new TaskIndexRepo(path, 5000, {
    readSettings: async () => {
      settingsReads++;
      return {
        recentProjects: [],
        lastWorkspaceSession: [{ kind: "local", workspacePath: "/saved" }],
      };
    },
  });
  const meta: CCbuddyTaskMeta = {
    taskId: "session",
    traceId: "trace",
    title: "CLI title",
    provider: "glm",
    workspacePath: "/saved",
    createdAt: 10,
    updatedAt: 20,
    mode: "default",
  };
  try {
    const projects = await repo.getProjectRepository();
    expect(settingsReads).toBe(1);
    const project = projects.readTree().projects[0]!;
    projects.reserveCreatedTask({ task: meta, projectId: project.id });
    await repo.syncTaskMeta({ meta });
    expect(projects.readTree().tasks[0]).toMatchObject({
      taskId: "session",
      projectId: project.id,
      title: "CLI title",
    });
    await repo.updateTaskState({
      ...meta,
      patch: { pinned: true, archived: true, title: "My title", titleOverridden: true },
    });
    const other = projects.saveProject({ name: "Other", roots: ["/saved"] });
    projects.moveTask({ task: meta, projectId: other.id });
    await repo.syncTaskMeta({ meta: { ...meta, title: "New CLI title", updatedAt: 30 } });
    expect(projects.readTree().tasks[0]).toMatchObject({
      projectId: other.id,
      pinned: true,
      archived: true,
      title: "My title",
      updatedAt: 30,
    });
    await repo.applyAgentPatch({ ...meta, patch: { status: "completed", updatedAt: 40 } });
    expect(projects.readTree().tasks[0]).toMatchObject({ status: "completed", updatedAt: 40 });
    repo.close();
    const reopened = await repo.getProjectRepository();
    expect(settingsReads).toBe(2);
    expect(reopened.readTree().tasks[0]?.projectId).toBe(other.id);
  } finally {
    repo.close();
    await rm(root, { recursive: true, force: true });
  }
});
