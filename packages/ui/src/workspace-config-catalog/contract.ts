import type { WorkspaceTabState } from "@/store/tabStore.js";
import type { VirtualProject, RemoteProjectDirectory } from "@ccbuddy/services";
export {
  buildRemoteHostWorkspaceIdentity,
  buildRemoteWorkspaceIdentity,
  remoteTargetSchema,
  parseRemoteWorkspaceIdentity,
} from "@ccbuddy/shared";
export type { IServiceAccessor } from "@ccbuddy/services";
export type { VirtualProject, RemoteProjectDirectory };
/** 配置目录地址不是 tab/session；连接信息只能复用已存在的 attachment。 */
export type ConfigWorkspaceTarget = Pick<
  WorkspaceTabState,
  | "workspacePath"
  | "workspaceIdentity"
  | "label"
  | "remoteSessionId"
  | "remoteTarget"
  | "localWorkspacePath"
  | "availability"
> & { hostId?: string; configOnline?: boolean };
export type {
  ProjectCatalogPort as ConfigCatalogPort,
  ProjectCatalogSnapshot as ConfigCatalogSnapshot,
} from "@ccbuddy/services";
