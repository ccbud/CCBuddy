import { ServiceChannels } from "@ccbuddy/shared";
import type {
  TraceId,
  CCbuddyAgentMcpServer,
  CCbuddyDeliveryKind,
  CCbuddyMessageWithParts,
  ModelSelection,
  CCbuddyPermissionRequestParams,
  CCbuddyUserInputRequestParams,
  CCbuddyUserInputResponse,
  CCbuddySessionInfo,
  CCbuddySessionImportHistory,
  CCbuddySessionEvent,
  CCbuddySessionMode,
  CCbuddySessionPersistence,
  CCbuddySessionStateSnapshot,
  CCbuddyStateUpdatedNotification,
  CCbuddyWorkspacePresentation,
} from "@ccbuddy/shared";
import { createServiceDescriptor } from "#src/descriptors.js";

export interface CCbuddySessionWorkspaceTarget {
  workspacePath: string;
  workspaceIdentity?: string;
  remoteSessionId?: string;
}

export type CCbuddySessionReadWorkspacePresentationParams = CCbuddySessionWorkspaceTarget;

export interface CCbuddyTaskTarget extends CCbuddySessionWorkspaceTarget {
  sessionId: string;
}

export interface CCbuddySessionCreateParams extends CCbuddySessionWorkspaceTarget {
  /** 仅导入事务使用的预分配 ID；普通新会话继续由 Agent 分配。 */
  sessionId?: string;
  sessionTraceId?: TraceId;
  parentSessionId?: string;
  mode?: CCbuddySessionMode;
  model?: ModelSelection;
  persistence?: CCbuddySessionPersistence;
  thoughtLevel?: string;
  mcpServers?: CCbuddyAgentMcpServer[];
  importedHistory?: CCbuddySessionImportHistory;
}

export interface CCbuddySessionResumeParams extends CCbuddyTaskTarget {
  model?: ModelSelection;
  thoughtLevel?: string;
  mcpServers?: CCbuddyAgentMcpServer[];
  /**
   * 默认广播 resume 得到的历史快照，并让 shadow 订阅请求初始 snapshot。
   * 续聊发送前的 runtime 预恢复会关闭它，避免旧终态快照覆盖本地已开始的新输入运行态。
   */
  broadcastSnapshot?: boolean;
}

export interface CCbuddySessionListParams extends CCbuddySessionWorkspaceTarget {
  includeArchived?: boolean;
  limit?: number;
}

export interface CCbuddySessionReadParams extends CCbuddyTaskTarget {
  deliveryKind?: CCbuddyDeliveryKind;
  messageLimit?: number;
  afterSeq?: number;
}

export interface CCbuddySessionMessagesParams extends CCbuddyTaskTarget {
  afterMessageId?: string;
  limit?: number;
}

export interface CCbuddySessionEventsParams extends CCbuddyTaskTarget {
  afterSeq?: number;
  limit?: number;
}

export interface CCbuddySessionSetModelParams extends CCbuddyTaskTarget {
  model: ModelSelection;
  expectedRevision?: number;
  persistAsWorkspaceLastUsed?: boolean;
}

export interface CCbuddySessionSetThoughtLevelParams extends CCbuddyTaskTarget {
  thoughtLevel?: string;
  expectedRevision?: number;
  persistAsWorkspaceLastUsed?: boolean;
}

export interface CCbuddySessionSetModeParams extends CCbuddyTaskTarget {
  mode: CCbuddySessionMode;
  expectedRevision?: number;
}

export interface CCbuddySessionSubscribeParams extends CCbuddyTaskTarget {
  deliveryKind: CCbuddyDeliveryKind;
  afterSeq?: number;
  includeSnapshot?: boolean;
  eventCoalescing?: {
    mode: "background-summary";
    intervalMs?: number;
  };
}

export type CCbuddySessionServiceEvent =
  | { type: "session.event"; event: CCbuddySessionEvent }
  | { type: "state.updated"; notification: CCbuddyStateUpdatedNotification }
  | { type: "permission.request"; request: CCbuddyPermissionRequestParams }
  | { type: "userInput.request"; request: CCbuddyUserInputRequestParams }
  | {
      type: "userInput.response";
      requestId: string;
      response: CCbuddyUserInputResponse;
    }
  | { type: "snapshot"; snapshot: CCbuddySessionStateSnapshot };

export interface CCbuddySessionInitializeResult {
  available: boolean;
  workspaceKey: string;
  protocolName?: string;
  protocolVersion?: number;
  transportKind?: "stdio" | "websocket";
  reason?: string;
  reasonCode?: "provider_not_ready";
}

export interface CCbuddySessionWorkspaceRuntimeIdentity {
  generation: number;
  identity: string;
  processId?: number;
  workspaceKey: string;
}

export interface ICCbuddySessionService {
  initializeWorkspace(
    params: CCbuddySessionWorkspaceTarget,
  ): Promise<CCbuddySessionInitializeResult>;
  getWorkspaceRuntimeIdentity(
    params: CCbuddySessionWorkspaceTarget,
  ): Promise<CCbuddySessionWorkspaceRuntimeIdentity>;
  readWorkspacePresentation(
    params: CCbuddySessionReadWorkspacePresentationParams,
  ): Promise<CCbuddyWorkspacePresentation>;
  createSession(params: CCbuddySessionCreateParams): Promise<CCbuddySessionStateSnapshot>;
  resumeSession(params: CCbuddySessionResumeParams): Promise<CCbuddySessionStateSnapshot>;
  listSessions(params: CCbuddySessionListParams): Promise<CCbuddySessionInfo[]>;
  readSession(params: CCbuddySessionReadParams): Promise<CCbuddySessionStateSnapshot>;
  readSessionMessages(params: CCbuddySessionMessagesParams): Promise<CCbuddyMessageWithParts[]>;
  readSessionEvents(params: CCbuddySessionEventsParams): Promise<CCbuddySessionEvent[]>;
  promoteDeferredDraftSession(params: CCbuddyTaskTarget): Promise<void>;
  closeSession(params: CCbuddyTaskTarget): Promise<void>;
  closeDeferredDraftSession(params: CCbuddyTaskTarget): Promise<boolean>;
  setModel(params: CCbuddySessionSetModelParams): Promise<CCbuddySessionStateSnapshot>;
  setThoughtLevel(
    params: CCbuddySessionSetThoughtLevelParams,
  ): Promise<CCbuddySessionStateSnapshot>;
  setMode(params: CCbuddySessionSetModeParams): Promise<CCbuddySessionStateSnapshot>;
  // renderer 订阅面走 agentService 的 conversation/sessions-index 帧通道。
}

export const ICCbuddySessionService = createServiceDescriptor<ICCbuddySessionService>(
  ServiceChannels.CCbuddySession,
);
