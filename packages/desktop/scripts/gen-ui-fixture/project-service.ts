import { ipcMain } from "electron";
import { DatabaseSync } from "node:sqlite";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { createProjectDataPort } from "../../../services/src/project/index.js";
import { createProjectDataRepository } from "../../../services/src/project-storage/index.js";
import { createProjectService } from "../../../services/src/project/index.js";
import { projectStorage } from "../../../services/src/project-storage/index.js";
import { createLegacyDatabase } from "../../../services/src/project-storage/test-database.js";
import { installRemoteProjectFixture } from "./remote-project-service.js";

export async function installProjectFixture(root: string) {
  await installRemoteProjectFixture(root);
  const db = new DatabaseSync(join(root, "projects.sqlite"));
  createLegacyDatabase(db);
  db.exec(
    "CREATE TABLE automations (workspace_key TEXT, workspace_path TEXT); CREATE TABLE off_peak_tasks (workspace_key TEXT, workspace_path TEXT)",
  );
  await projectStorage.migrate(db, { backupDirectories: [join(root, "project-backups")] });
  const directories = [join(root, "primary"), join(root, "secondary")];
  await Promise.all(directories.map((path) => mkdir(path, { recursive: true })));
  const service = createProjectService({
    repository: async () => projectStorage.repository(db),
    workspaceDirectory: join(root, "workspaces"),
    data: {
      repository: async () => createProjectDataRepository(db),
      port: createProjectDataPort({
        agent: {
          measure: async () => ({ sessions: [], memory: [] }),
          purge: async () => ({ deleted: [], kept: [], failed: [], memory: [] }),
        },
        checkpointDirectory: (path) =>
          join(root, "checkpoints", path === directories[0] ? "primary" : "secondary"),
      }),
    },
  });
  ipcMain.handle("fixture-project", async (_, method: keyof typeof service, input: never) => {
    return (service[method] as (input: unknown) => unknown)(input);
  });
  ipcMain.handle("fixture-project-directories", () => directories);
}
