import { describe, expect, it, vi } from "vitest";
import { buildRemoteWorkspaceIdentity } from "@ccbuddy/shared";
import type { IServiceAccessor } from "#src/accessor.js";
import type { VirtualProject } from "./contract.js";
import { createRemoteProjectService } from "./remote-service.js";

const target = { kind: "ssh" as const, host: "example", username: "user" };
const entry = {
  id: "project",
  hostId: "local",
  name: "Remote",
  roots: [{ rootPath: "/remote", isPrimary: true, position: 0 }],
  pinned: false,
  deleted: false,
  position: 0,
  createdAt: 1,
  updatedAt: 1,
  nameOverridden: true,
} satisfies VirtualProject;

describe("remote project capability boundary", () => {
  it("uses explicit capability and preserves the physical target without starting an Agent", async () => {
    const info = vi.fn(async () => ({
      homedir: "/home",
      platform: "linux",
      virtualProjects: true,
    }));
    const readTree = vi.fn(async () => ({
      projects: [entry],
      tasks: [{ taskId: "task", workspacePath: "/remote", hostId: "local", projectId: "project" }],
    }));
    const prepareSession = vi.fn(async () => ({
      workspacePath: "/remote",
      projectId: "project",
      additionalDirectories: [],
    }));
    const services = {
      systemService: { info },
      projectService: { readTree, prepareSession },
    } as unknown as IServiceAccessor;
    const remote = createRemoteProjectService({ services, target });
    const tree = await remote.readTree();
    expect(tree.projects[0]!.hostId).toBe("remote:ssh:example:22:user");
    expect(tree.tasks[0]!.workspaceIdentity).toBe(buildRemoteWorkspaceIdentity("/remote", target));
    expect(await remote.prepareSession({ projectId: "project" })).toEqual({
      workspacePath: "/remote",
      projectId: "project",
      additionalDirectories: [],
      workspaceIdentity: buildRemoteWorkspaceIdentity("/remote", target),
    });
    expect(info).toHaveBeenCalledOnce();
    expect(prepareSession).toHaveBeenCalledWith({ projectId: "project", hostId: undefined });
  });

  it("falls back to a read-only single-root projection without probing an unknown RPC method", async () => {
    const services = {
      systemService: { info: async () => ({ homedir: "/home", platform: "linux" }) },
      settingService: {
        get: async () => ({
          lastWorkspaceSession: [{ kind: "local", workspacePath: "/remote" }],
          recentProjects: [],
        }),
      },
      ccbuddyTaskService: {
        listTasks: async () => [],
        listPinnedTasks: async () => [],
        listArchivedTasks: async () => [],
      },
      projectService: new Proxy(
        {},
        {
          get: () => {
            throw new Error("Unknown RPC must not be touched");
          },
        },
      ),
    } as unknown as IServiceAccessor;
    const remote = createRemoteProjectService({ services, target });
    expect((await remote.readTree()).legacySingleRoot).toBe(true);
    await expect(remote.saveProject({ name: "No write", roots: ["/remote"] })).rejects.toThrow(
      "legacy-read-only",
    );
  });

  it("rejects cross-host, multi-root and data destruction before any RPC write", async () => {
    const services = {} as IServiceAccessor;
    const remote = createRemoteProjectService({ services, target });
    await expect(remote.saveProject({ hostId: "other", roots: ["/remote"] })).rejects.toThrow(
      "cross-host",
    );
    await expect(remote.saveProject({ roots: ["/one", "/two"] })).rejects.toThrow("single-root");
    await expect(remote.saveProject({ roots: [] })).rejects.toThrow("single-root");
    await expect(remote.deleteProjectData("project")).rejects.toThrow("local-only");
    await expect(remote.measureProjectData(["project"])).rejects.toThrow("local-only");
  });

  it("does not treat a failed capability lookup as an older server", async () => {
    const info = vi
      .fn()
      .mockRejectedValueOnce(new Error("disconnected"))
      .mockResolvedValue({ virtualProjects: true });
    const readTree = vi.fn(async () => ({ projects: [], tasks: [] }));
    const services = {
      systemService: { info },
      projectService: { readTree },
    } as unknown as IServiceAccessor;
    const remote = createRemoteProjectService({ services, target });
    await expect(remote.readTree()).rejects.toThrow("disconnected");
    expect(readTree).not.toHaveBeenCalled();
    await expect(remote.readTree()).resolves.toMatchObject({ projects: [] });
    expect(info).toHaveBeenCalledTimes(2);
  });
});
