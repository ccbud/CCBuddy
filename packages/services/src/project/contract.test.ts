import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, vi } from "vitest";
import type { ProjectRepositoryContract, VirtualProject } from "../project-storage/contract.js";
import { createProjectService } from "./index.js";

it("validates roots on the owning Host and never recreates a missing configured root", async () => {
  const root = await mkdtemp(join(tmpdir(), "ccbuddy-project-service-"));
  const primary = join(root, "primary");
  await mkdir(primary);
  const project: VirtualProject = {
    id: "project",
    hostId: "local",
    name: "Project",
    nameOverridden: true,
    roots: [{ rootPath: primary, position: 0, isPrimary: true }],
    position: 0,
    pinned: false,
    deleted: false,
    createdAt: 1,
    updatedAt: 1,
  };
  const readTree = vi.fn(() => ({ projects: [project], tasks: [] }));
  const saveProject = vi.fn(() => project);
  const afterChange = vi.fn(async () => {});
  const repository = { readTree, saveProject } as unknown as ProjectRepositoryContract;
  const service = createProjectService({
    repository: async () => repository,
    workspaceDirectory: join(root, "workspace"),
    afterChange,
  });
  try {
    await expect(service.saveProject({ roots: ["relative"] })).rejects.toThrow(
      "project.absolute-path-required",
    );
    expect(saveProject).not.toHaveBeenCalled();
    await service.saveProject({ roots: [primary] });
    expect(afterChange).toHaveBeenCalledOnce();
    expect(await service.prepareSession({ projectId: project.id })).toMatchObject({
      workspacePath: primary,
      projectId: project.id,
    });
    await rm(primary, { recursive: true });
    expect((await service.readTree()).projects[0]?.primaryRootStatus).toBe("missing");
    await expect(service.prepareSession({ projectId: project.id })).rejects.toThrow(
      "project.primaryRootMissing",
    );
    await expect(service.readTree({ hostId: "remote" })).rejects.toThrow("project.host-offline");
    expect(afterChange).toHaveBeenCalledOnce();
    project.deleted = true;
    await service.restoreProject(project.id);
    expect(saveProject).toHaveBeenLastCalledWith({
      restoreProjectId: project.id,
      roots: [primary],
    });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

it("routes remote commands without loading the local database", async () => {
  const repository = vi.fn();
  const remoteRead = vi.fn(async () => ({ projects: [], tasks: [] }));
  const service = createProjectService({
    repository,
    workspaceDirectory: "/unused",
    resolveHost: async () => ({ readTree: remoteRead }) as never,
  });
  await service.readTree({ hostId: "remote", includeDeleted: true });
  expect(remoteRead).toHaveBeenCalledWith({ includeDeleted: true, includeDeletedTasks: undefined });
  expect(repository).not.toHaveBeenCalled();
});
