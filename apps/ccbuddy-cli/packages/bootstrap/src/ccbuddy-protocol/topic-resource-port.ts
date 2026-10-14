import { channelReplyResultSchema } from "@ccbuddy/shared";
import { randomUUID } from "node:crypto";
import type { TopicResourcePort } from "@ccbuddy/contracts";
import {
  ccbuddyProtocolMethods,
  ccbuddyTopicResourceReadResultSchema,
  ccbuddyTopicResourceCancelResultSchema,
} from "@ccbuddy/shared";
import {
  protocolTraceFromTraceContext,
  type CCbuddyProtocolAgentServerContext,
} from "./server-types.js";

const RESOURCE_TIMEOUT_MS = 120_000;

export function createProtocolTopicResourcePort(
  context: CCbuddyProtocolAgentServerContext,
): TopicResourcePort {
  return {
    async reply(request, options) {
      options.signal.throwIfAborted();
      return context.requestClient(
        ccbuddyProtocolMethods.channelReply,
        request,
        channelReplyResultSchema,
        {
          signal: options.signal,
          trace: options.trace ? protocolTraceFromTraceContext(options.trace) : undefined,
          timeoutMs: 60_000,
        },
      );
    },
    async read(request, options) {
      options.signal.throwIfAborted();
      const requestId = randomUUID();
      // 原因：Core trace 含 sessionId 等额外字段，原样发送会让 Host 严格校验失败并断开整个 CLI。
      const trace = options.trace ? protocolTraceFromTraceContext(options.trace) : undefined;
      const cancel = async () => {
        try {
          await context.requestClient(
            ccbuddyProtocolMethods.topicResourceCancel,
            { requestId, taskId: request.taskId },
            ccbuddyTopicResourceCancelResultSchema,
            { timeoutMs: RESOURCE_TIMEOUT_MS, trace },
          );
        } catch {
          // 原因：断连时 requestClient 会同步抛错，不能从 abort listener 冒泡并终止 CLI。
          // 取消是尽力通知；原读取请求仍保留取消／断连错误，不重连或重新执行。
        }
      };
      options.signal.addEventListener("abort", cancel, { once: true });
      try {
        const result = await context.requestClient(
          ccbuddyProtocolMethods.topicResourceRead,
          { ...request, requestId },
          ccbuddyTopicResourceReadResultSchema,
          { signal: options.signal, trace, timeoutMs: RESOURCE_TIMEOUT_MS },
        );
        options.signal.throwIfAborted();
        return result;
      } finally {
        options.signal.removeEventListener("abort", cancel);
      }
    },
  };
}
