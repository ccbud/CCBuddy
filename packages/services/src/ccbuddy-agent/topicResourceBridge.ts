import {
  ccbuddyTopicResourceReadParamsSchema,
  ccbuddyTopicResourceReadResultSchema,
  type CCbuddyTopicResourceReadParams,
  type CCbuddyTopicResourceReadResult,
  type CCbuddyPromptAttachment,
  type CCbuddyProtocolTrace,
} from "@ccbuddy/shared";

const RESOURCE_TIMEOUT_MS = 120_000;
export interface TopicResourceBridgeDependencies {
  validate(
    request: CCbuddyTopicResourceReadParams,
    signal: AbortSignal,
    trace?: CCbuddyProtocolTrace,
  ): Promise<void>;
  read(
    request: CCbuddyTopicResourceReadParams,
    signal: AbortSignal,
    trace?: CCbuddyProtocolTrace,
  ): Promise<CCbuddyPromptAttachment>;
  upload(
    request: CCbuddyTopicResourceReadParams,
    attachment: CCbuddyPromptAttachment,
    signal: AbortSignal,
    trace?: CCbuddyProtocolTrace,
  ): Promise<CCbuddyTopicResourceReadResult>;
}

/** 每个实际 CLI 连接拥有独立取消域，不能取消另一工作区或另一任务的读取。 */
export function createTopicResourceBridge(
  dependencies: TopicResourceBridgeDependencies | (() => TopicResourceBridgeDependencies),
) {
  const pending = new Map<string, { taskId: string; controller: AbortController }>();
  let disposed = false;
  return {
    async read(value: unknown, trace?: CCbuddyProtocolTrace): Promise<CCbuddyTopicResourceReadResult> {
      const request = ccbuddyTopicResourceReadParamsSchema.parse(value);
      if (disposed) throw new Error("Topic resource connection is closed");
      if (pending.has(request.requestId))
        throw new Error("Topic resource request is already active");
      const controller = new AbortController();
      pending.set(request.requestId, { taskId: request.taskId, controller });
      const timer = setTimeout(
        () => controller.abort(new Error("Topic resource request timed out")),
        RESOURCE_TIMEOUT_MS,
      );
      try {
        // 固定本次请求的路由，异步下载期间不能被后续 workspace 访问改投其他 logical session。
        const deps = typeof dependencies === "function" ? dependencies() : dependencies;
        const attachment = await deps.read(request, controller.signal, trace);
        controller.signal.throwIfAborted();
        const result = await deps.upload(request, attachment, controller.signal, trace);
        controller.signal.throwIfAborted();
        // 群可能在分块传输期间停用；返回引用前再核对授权，不暴露已失效请求的文件路径。
        await deps.validate(request, controller.signal, trace);
        // 授权检查也包含异步 IO，检查期间取消的请求不能再返回附件引用。
        controller.signal.throwIfAborted();
        return ccbuddyTopicResourceReadResultSchema.parse(result);
      } finally {
        clearTimeout(timer);
        pending.delete(request.requestId);
      }
    },
    cancel(request: { requestId: string; taskId: string }): boolean {
      const operation = pending.get(request.requestId);
      if (!operation || operation.taskId !== request.taskId) return false;
      operation.controller.abort(new Error("Topic resource request cancelled"));
      return true;
    },
    dispose() {
      disposed = true;
      for (const operation of pending.values())
        operation.controller.abort(new Error("Topic resource connection closed"));
      pending.clear();
    },
  };
}
