import type { IProjectService } from "./contract.js";
/** 对外树使用 attachment 已登记的稳定身份；实际 cwd 与远端 canonical key 不改写。 */
export function bindRemoteProjectIdentities(
  service: IProjectService,
  resolveIdentity: (workspacePath: string) => Promise<string>,
): IProjectService {
  return {
    readProjects: (params) => service.readProjects(params),
    async readTree(params) {
      const tree = await service.readTree(params);
      // 空项目也会立即订阅侧栏状态。若只准备 task cwd，首次订阅会固定到未映射的
      // emitter，稍后打开目录才建立映射也无法重绑；必须先准备所有订阅目录再发布树。
      const paths = [
        ...new Set([
          ...tree.projects.flatMap((project) => project.roots.map((root) => root.rootPath)),
          ...tree.tasks.map((task) => task.workspacePath),
        ]),
      ];
      const identities = new Map(
        await Promise.all(paths.map(async (path) => [path, await resolveIdentity(path)] as const)),
      );
      return {
        ...tree,
        tasks: tree.tasks.map((task) => ({
          ...task,
          workspaceIdentity: identities.get(task.workspacePath)!,
        })),
      };
    },
    readDirectory: (params) => service.readDirectory(params),
    saveProject: (input) => service.saveProject(input),
    deleteProject: (id, hostId) => service.deleteProject(id, hostId),
    restoreProject: (id, hostId) => service.restoreProject(id, hostId),
    moveTask: (input) => service.moveTask(input),
    reorderProjects: (ids, hostId) => service.reorderProjects(ids, hostId),
    measureProjectData: (ids, hostId) => service.measureProjectData(ids, hostId),
    deleteProjectData: (id, hostId) => service.deleteProjectData(id, hostId),
    async prepareSession(params) {
      const directories = await service.prepareSession(params);
      return {
        ...directories,
        workspaceIdentity: await resolveIdentity(directories.workspacePath),
      };
    },
    async resolveSessionDirectories(task, hostId) {
      const directories = await service.resolveSessionDirectories(task, hostId);
      // 已有任务恢复曾漏补远程身份，导致同一 cwd 被导航隔离校验拒绝。
      // 以所属 Host 返回的真实目录解析身份，不复制请求身份或放宽导航校验。
      return {
        ...directories,
        workspaceIdentity: await resolveIdentity(directories.workspacePath),
      };
    },
  };
}

/**
 * 远端身份登记按物理连接代际去重，供装配器包住传给 `bindRemoteProjectIdentities` 的 resolver。
 *
 * Bug 原因：3.16 起，每次远端 readTree、resolveSessionDirectories、prepareSession 都对每个路径
 * 重新调用一次远端 resolveWorkspace。登记只写入 Server Core 进程内的 stable → canonical
 * 映射表，同一连接内重复登记不改变任何状态，却给发送前的目录解析多加一次串行 SSH 往返，
 * 并让远端每次同步打开两个 SQLite 库。
 *
 * 修复：映射表随 Core 进程存活且只增不删；Core 重启一定会断开连接，Host 会拿到新的物理连接
 * 对象。所以按物理连接对象缓存登记结果即可，不需要超时。登记失败不缓存，下次重新登记。
 */
export function createRemoteIdentityRegistrationCache(): (
  physicalConnection: object,
  workspacePath: string,
  register: () => Promise<string>,
) => Promise<string> {
  const byConnection = new WeakMap<object, Map<string, Promise<string>>>();
  return (physicalConnection, workspacePath, register) => {
    const byPath = byConnection.get(physicalConnection) ?? new Map<string, Promise<string>>();
    byConnection.set(physicalConnection, byPath);
    const registered = byPath.get(workspacePath);
    if (registered) return registered;
    const flight = register();
    byPath.set(workspacePath, flight);
    // 调用方照常收到失败；这里只删除缓存，让下一次读取重新登记。
    flight.catch(() => {
      if (byPath.get(workspacePath) === flight) byPath.delete(workspacePath);
    });
    return flight;
  };
}
