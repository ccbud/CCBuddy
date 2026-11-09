import { ipcMain } from "electron";
import { DatabaseSync } from "node:sqlite";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { buildRemoteWorkspaceIdentity } from "@ccbuddy/shared";
import type { IServiceAccessor } from "../../../services/src/accessor.js";
import {
  createProjectService,
  createRemoteProjectService,
} from "../../../services/src/project/index.js";
import { projectStorage } from "../../../services/src/project-storage/index.js";
import { createLegacyDatabase } from "../../../services/src/project-storage/test-database.js";

export async function installRemoteProjectFixture(root: string) {
  const db = new DatabaseSync(join(root, "remote-projects.sqlite"));
  createLegacyDatabase(db);
  db.exec(
    "CREATE TABLE automations (workspace_key TEXT, workspace_path TEXT); CREATE TABLE off_peak_tasks (workspace_key TEXT, workspace_path TEXT)",
  );
  await projectStorage.migrate(db, { backupDirectories: [join(root, "remote-backups")] });
  const directory = join(root, "remote-project");
  await mkdir(directory, { recursive: true });
  const service = createProjectService({
    repository: async () => projectStorage.repository(db),
    workspaceDirectory: join(root, "remote-workspaces"),
    singleRootOnly: true,
  });
  const project = await service.saveProject({ name: "Remote fixture", roots: [directory] });
  const target = { kind: "ssh" as const, host: "fixture", username: "fixture" };
  const identity = buildRemoteWorkspaceIdentity(directory, target);
  const services = (legacy: boolean) =>
    ({
      systemService: {
        info: async () => ({
          homedir: root,
          platform: "linux",
          ...(!legacy ? { virtualProjects: true } : {}),
        }),
      },
      projectService: service,
      settingService: {
        get: async () => ({
          lastWorkspaceSession: [{ kind: "local", workspacePath: directory }],
          recentProjects: [],
        }),
      },
      ccbuddyTaskService: {
        listTasks: async () => [],
        listPinnedTasks: async () => [],
        listArchivedTasks: async () => [],
      },
    }) as unknown as IServiceAccessor;
  const current = createRemoteProjectService({ services: services(false), target });
  const legacy = createRemoteProjectService({ services: services(true), target });
  ipcMain.handle(
    "fixture-remote-project",
    async (_, method: string, input: never, old: boolean) => {
      if (method === "config") return { directory, identity, projectId: project.id };
      const port = old ? legacy : current;
      return (port[method as keyof typeof port] as (input: unknown) => unknown)(input);
    },
  );
}
