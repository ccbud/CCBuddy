import {
  buildRemoteHostWorkspaceIdentity,
  type IRemoteProjectService,
  type ProjectSidebarProps,
  type SidebarFileTreeTarget,
  type VirtualProject,
} from "@/project-sidebar/contract.js";
import { attachRemoteProjectWorkspace } from "@/project-sidebar/remote-navigation.js";

/** 文件读取目标只取用户选中的 root；不能用同路径的当前 tab 猜远端身份。 */
export async function resolveProjectFileTarget(input: {
  project: VirtualProject;
  rootPath: string;
  isRemote: boolean;
  props: Pick<
    ProjectSidebarProps,
    | "workspacePath"
    | "workspaceIdentity"
    | "onConnectRemote"
    | "onSelectRemoteProject"
    | "onCancelRemoteProject"
  >;
  remoteService?: IRemoteProjectService;
  findSession(identity: string): { sessionId: string } | undefined;
  waitForPendingConnection?(workspaceKey: string): Promise<void>;
  /** 本次查看仍是最新意图；被取代后不再连接设备、绑定目录或改写 tab。 */
  isCurrent(): boolean;
}): Promise<SidebarFileTreeTarget | null> {
  const { project, rootPath, props } = input;
  if (!project.roots.some((root) => root.rootPath === rootPath))
    throw new Error("project.root-not-found");
  const identity = input.isRemote
    ? buildRemoteHostWorkspaceIdentity(project.hostId, rootPath)
    : undefined;
  let sessionId = identity ? input.findSession(identity)?.sessionId : undefined;
  if (identity && !sessionId) {
    if (!input.remoteService) throw new Error("project.connection-unavailable");
    sessionId = await attachRemoteProjectWorkspace({
      hostId: project.hostId,
      workspacePath: rootPath,
      workspaceIdentity: identity,
      remoteService: input.remoteService,
      isCurrent: input.isCurrent,
      findSession: input.findSession,
      waitForPendingConnection: input.waitForPendingConnection,
      connect: props.onConnectRemote,
      bind: (id, path, guard) => props.onSelectRemoteProject(id, path, undefined, identity, guard),
      cancel: props.onCancelRemoteProject,
    });
  }
  return {
    workspacePath: rootPath,
    workspaceName: project.name,
    ...(identity ? { workspaceIdentity: identity } : {}),
    ...(sessionId ? { workspaceRemoteSessionId: sessionId } : {}),
  };
}
