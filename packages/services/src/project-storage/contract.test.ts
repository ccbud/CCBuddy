import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";
import { projectStorage } from "./index.js";
import { createLegacyDatabase } from "./test-database.js";

it("migrates only saved workspaces, keeps groups and does not repeat first assignment", async () => {
  const root = await mkdtemp(join(tmpdir(), "ccbuddy-project-migration-"));
  const db = new DatabaseSync(join(root, "tasks.sqlite"));
  try {
    createLegacyDatabase(db);
    db.prepare(
      "INSERT INTO tasks(workspace_key,workspace_path,task_id,title,provider,created_at,updated_at) VALUES(?,?,?,?,?,?,?)",
    ).run("/saved", "/saved", "existing", "Existing", "glm", 1, 2);
    const context = {
      backupDirectories: [join(root, "backup")],
      settings: {
        recentProjects: ["/must-not-revive"],
        lastWorkspaceSession: [{ kind: "local" as const, workspacePath: "/saved" }],
      },
    };
    await projectStorage.migrate(db, context);
    const repository = projectStorage.repository(db);
    const tree = repository.readTree();
    expect(tree.projects.map((project) => project.roots[0]?.rootPath)).toEqual(["/saved"]);
    expect(tree.tasks[0]?.taskId).toBe("existing");
    expect(tree.tasks[0]?.projectId).toBe(tree.projects[0]?.id);
    const other = repository.saveProject({ name: "Other", roots: [] });
    db.prepare("UPDATE tasks SET project_id=NULL WHERE task_id='existing'").run();
    await projectStorage.migrate(db, context);
    expect(repository.readTree().tasks[0]?.projectId).toBeNull();
    expect(repository.readTree().projects).toHaveLength(2);
    expect(other.roots).toEqual([]);
    expect(
      db.prepare("SELECT name FROM sqlite_master WHERE name='task_groups'").get(),
    ).toBeDefined();
  } finally {
    db.close();
    await rm(root, { recursive: true, force: true });
  }
});

it("reserves one task identity, preserves cwd across project edits and rejects cross-host moves", async () => {
  const root = await mkdtemp(join(tmpdir(), "ccbuddy-project-reservation-"));
  const db = new DatabaseSync(join(root, "tasks.sqlite"));
  try {
    createLegacyDatabase(db);
    await projectStorage.migrate(db, { backupDirectories: [join(root, "backup")] });
    const repository = projectStorage.repository(db);
    const project = repository.saveProject({
      name: "Project",
      roots: ["/one", "/two"],
      primaryRoot: "/one",
    });
    const input = {
      task: { workspacePath: "/one" },
      projectId: project.id,
      additionalDirectories: ["/two"],
      creationCommand: { clientId: "desktop", commandId: "create" },
    };
    const first = repository.reserveCreatedTask(input);
    expect(repository.reserveCreatedTask(input)).toEqual(first);
    repository.saveProject({ id: project.id, roots: ["/two"], primaryRoot: "/two" });
    expect(
      repository.resolveSessionDirectories({ workspacePath: "/one", taskId: first.taskId }),
    ).toMatchObject({ workspacePath: "/one", additionalDirectories: ["/two"] });
    expect(() =>
      projectStorage
        .repository(db, "remote:ssh:host:22:user")
        .moveTask({ task: { workspacePath: "/one", taskId: first.taskId }, projectId: project.id }),
    ).toThrow();
    repository.deleteProject(project.id);
    expect(repository.readTree().projects).toEqual([]);
    expect(repository.readTree({ includeDeleted: true }).projects[0]?.deleted).toBe(true);
    expect(
      repository.resolveSessionDirectories({ workspacePath: "/one", taskId: first.taskId })
        .workspacePath,
    ).toBe("/one");
    const restored = repository.saveProject({ restoreProjectId: project.id, roots: ["/two"] });
    expect(restored.deleted).toBe(false);
  } finally {
    db.close();
    await rm(root, { recursive: true, force: true });
  }
});

it("archives by CLI age without touching pinned or genuinely active tasks", async () => {
  const root = await mkdtemp(join(tmpdir(), "ccbuddy-project-archive-"));
  const db = new DatabaseSync(join(root, "tasks.sqlite"));
  try {
    createLegacyDatabase(db);
    for (const id of ["old-error", "pinned", "active", "recent"]) {
      db.prepare(
        "INSERT INTO tasks(workspace_key,workspace_path,task_id,title,provider,created_at,updated_at,task_status,pinned,unread_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
      ).run(
        "/project",
        "/project",
        id,
        id,
        "glm",
        1,
        id === "recent" ? 200 : 2,
        "error",
        id === "pinned" ? 1 : 0,
        3,
      );
    }
    await projectStorage.migrate(db, { backupDirectories: [join(root, "backup")] });
    const repo = projectStorage.repository(db);
    expect(
      repo.archiveInactive({
        cutoff: 100,
        activeTasks: [{ workspacePath: "/project", taskId: "active" }],
      }),
    ).toEqual([{ workspacePath: "/project", workspaceIdentity: undefined, taskId: "old-error" }]);
    expect(
      repo
        .readTree()
        .tasks.filter((task) => task.archived)
        .map((task) => task.taskId),
    ).toEqual(["old-error"]);
  } finally {
    db.close();
    await rm(root, { recursive: true, force: true });
  }
});
