import { Event as RpcEvent } from "@ccbuddy/rpc";
import type { IConversationShareService, ICCbuddyAgentService } from "@ccbuddy/services";
import { conversationShareConnectionScopeFactory } from "@ccbuddy/services/node";

type ConversationShareAgentService = Pick<
  ICCbuddyAgentService,
  | "conversationRowsRangeV4"
  | "conversationFileChangesV4"
  | "conversationAttachmentReadV4"
  | "conversationAttachmentStatV4"
>;

type ConnectionScopableConversationShareService = IConversationShareService & {
  [conversationShareConnectionScopeFactory](
    agentService: ConversationShareAgentService,
  ): IConversationShareService;
};

function isConnectionScopableConversationShareService(
  service: IConversationShareService,
): service is ConnectionScopableConversationShareService {
  return (
    conversationShareConnectionScopeFactory in service &&
    typeof service[conversationShareConnectionScopeFactory] === "function"
  );
}

export function scopeConversationShareServiceForAttachment(
  service: IConversationShareService,
  clientMode: "desktop-continuous" | "web-remote-replayable",
  agentService?: ConversationShareAgentService,
): IConversationShareService {
  if (clientMode === "desktop-continuous") {
    if (!isConnectionScopableConversationShareService(service)) return service;
    if (agentService) return service[conversationShareConnectionScopeFactory](agentService);
    const rejectUnavailable = async (): Promise<never> => {
      throw Object.assign(new Error("Conversation sharing connection is not ready"), {
        kind: "connection_unavailable" as const,
      });
    };
    return {
      getCapabilities: () => service.getCapabilities(),
      preflight: (input) => service.preflight(input),
      publish: rejectUnavailable,
      onDynamicPublishProgress: (operationId) => service.onDynamicPublishProgress(operationId),
      importShare: (input, operationId) => service.importShare(input, operationId),
      onDynamicImportProgress: (operationId) => service.onDynamicImportProgress(operationId),
      getImportedConversation: (input) => service.getImportedConversation(input),
      getPreview: (shareCode) => service.getPreview(shareCode),
      getContinuation: (input) => service.getContinuation(input),
    };
  }
  const rejectNonDesktopShare = async (): Promise<never> => {
    throw Object.assign(new Error("Conversation sharing is only available from Desktop"), {
      kind: "feature_disabled" as const,
    });
  };
  return {
    getCapabilities: () => service.getCapabilities(),
    preflight: rejectNonDesktopShare,
    publish: rejectNonDesktopShare,
    onDynamicPublishProgress: () => RpcEvent.None,
    importShare: rejectNonDesktopShare,
    onDynamicImportProgress: () => RpcEvent.None,
    // 非 Desktop attachment 没有本地 workspace 展示面，返回 null 避免暴露本地只读内容。
    getImportedConversation: async () => null,
    getPreview: (shareCode: string) => service.getPreview(shareCode),
    getContinuation: rejectNonDesktopShare,
  };
}
