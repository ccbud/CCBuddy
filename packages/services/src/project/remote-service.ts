import {
  buildRemoteWorkspaceIdentity,
  remoteHostIdFromWorkspaceIdentity,
  type RemoteTarget,
} from "@ccbuddy/shared";
import type { IServiceAccessor } from "#src/accessor.js";
import type { IProjectService, VirtualProject, ProjectTask } from "./contract.js";
import { createLegacySingleRootProjectService } from "./legacy-single-root.js";

export function createRemoteProjectService(options: {
  services: IServiceAccessor;
  target: RemoteTarget;
}): IProjectService {
  const { services, target } = options;
  const identity = (path: string) => buildRemoteWorkspaceIdentity(path, target);
  const hostId = remoteHostIdFromWorkspaceIdentity(identity("/"))!;
  const verifyHost = (requested?: string) => {
    if (requested && requested !== hostId) throw new Error("project.cross-host-move");
  };
  const project = (entry: VirtualProject): VirtualProject => ({ ...entry, hostId });
  const task = (entry: ProjectTask): ProjectTask => ({
    ...entry,
    hostId,
    workspaceIdentity: identity(entry.workspacePath),
  });
  const legacy = createLegacySingleRootProjectService({
    hostId,
    directories: {
      info: () => services.systemService.info(),
      read: (input) => services.fileService.readdir(input),
    },
    readSettings: () => services.settingService.get(),
    readTasks: ({ kind, workspacePath }) =>
      kind === "pinned"
        ? services.ccbuddyTaskService.listPinnedTasks({ workspacePath })
        : kind === "archived"
          ? services.ccbuddyTaskService.listArchivedTasks({ workspacePath })
          : services.ccbuddyTaskService.listTasks({ workspacePath }),
    ensureConversation: async () => {
      throw new Error("project.remote-project-required");
    },
  });
  let capability: Promise<boolean> | undefined;
  const supported = () =>
    (capability ??= services.systemService
      .info()
      .then((info) => info.virtualProjects === true)
      .catch((error) => {
        capability = undefined;
        throw error;
      }));
  const port = async () => {
    if (!(await supported())) return legacy;
    if (!services.projectService) throw new Error("project.host-offline");
    return services.projectService;
  };
  const localParams = async (requested?: string) => {
    verifyHost(requested);
    return (await supported()) ? undefined : hostId;
  };
  const unavailable = async (): Promise<never> => {
    throw new Error("project.data-local-only");
  };
  return {
    async readDirectory(params) {
      const source = await port();
      return source.readDirectory({ ...params, hostId: await localParams(params?.hostId) });
    },
    async readProjects(params) {
      const source = await port();
      return (
        await source.readProjects({ ...params, hostId: await localParams(params?.hostId) })
      ).map(project);
    },
    async readTree(params) {
      const source = await port();
      const tree = await source.readTree({ ...params, hostId: await localParams(params?.hostId) });
      return {
        ...tree,
        projects: tree.projects.map(project),
        tasks: tree.tasks.map(task),
        deletedTasks: tree.deletedTasks?.map((entry) => ({
          ...entry,
          hostId,
          workspaceIdentity: identity(entry.workspacePath),
        })),
      };
    },
    async saveProject(input) {
      verifyHost(input.hostId);
      if (
        (!input.id && !input.restoreProjectId && input.roots?.length !== 1) ||
        (input.roots && input.roots.length !== 1)
      )
        throw new Error("project.remote-single-root-required");
      const source = await port();
      return project(
        await source.saveProject({ ...input, hostId: await localParams(input.hostId) }),
      );
    },
    async deleteProject(id, requested) {
      await (await port()).deleteProject(id, await localParams(requested));
    },
    async restoreProject(id, requested) {
      return project(await (await port()).restoreProject(id, await localParams(requested)));
    },
    async reorderProjects(ids, requested) {
      await (await port()).reorderProjects(ids, await localParams(requested));
    },
    async moveTask(input) {
      if (input.task.workspaceIdentity)
        verifyHost(remoteHostIdFromWorkspaceIdentity(input.task.workspaceIdentity) ?? "invalid");
      const source = await port();
      const projects = await source.readProjects({});
      const destination = projects.find((entry) => entry.id === input.projectId);
      if (
        destination &&
        !destination.roots.some((root) => root.rootPath === input.task.workspacePath)
      )
        throw new Error("project.remote-single-root-required");
      await source.moveTask({
        ...input,
        hostId: await localParams(input.hostId),
        task: input.task,
      });
    },
    async prepareSession(params) {
      if (!params?.projectId) throw new Error("project.remote-project-required");
      const source = await port();
      const directories = await source.prepareSession({
        ...params,
        hostId: await localParams(params.hostId),
      });
      if (directories.additionalDirectories.length)
        throw new Error("project.remote-single-root-required");
      return { ...directories, workspaceIdentity: identity(directories.workspacePath) };
    },
    async resolveSessionDirectories(reference, requested) {
      if (reference.workspaceIdentity)
        verifyHost(remoteHostIdFromWorkspaceIdentity(reference.workspaceIdentity) ?? "invalid");
      const source = await port();
      const directories = await source.resolveSessionDirectories(
        reference,
        await localParams(requested),
      );
      if (directories.additionalDirectories.length)
        throw new Error("project.remote-single-root-required");
      return { ...directories, workspaceIdentity: identity(directories.workspacePath) };
    },
    measureProjectData: unavailable,
    deleteProjectData: unavailable,
  };
}
