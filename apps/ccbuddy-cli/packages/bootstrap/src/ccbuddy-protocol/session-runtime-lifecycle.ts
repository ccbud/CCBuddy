import type { SessionId } from "@ccbuddy/contracts";
import { ccbuddyProtocolMethods } from "@ccbuddy/shared";
import { SessionLifecycleController } from "../session-lifecycle/index.js";
import type { CCbuddyProtocolAgentServerContext } from "./server-types.js";
import { activateSessionRuntime, validateSessionActivationWorkspace } from "./server-operations.js";
import { waitForSessionResidencyFinalization } from "./session-finalization.js";
import { abortMcpUiToolCallsForSession, clearMcpUiAppToolsForSession } from "./mcp-ui/index.js";

export function getSessionLifecycle(
  context: CCbuddyProtocolAgentServerContext,
): SessionLifecycleController {
  return (context.sessionLifecycle ??= new SessionLifecycleController({
    exists: async (sessionId) => {
      const stored = await context.deps.sessionStore?.getSession(sessionId as SessionId);
      return (
        stored?.time.deleted === undefined && Boolean(stored || context.sessions.has(sessionId))
      );
    },
    hasRuntime: (sessionId) => context.sessions.has(sessionId),
    validateActivation: (sessionId, workspace) =>
      validateSessionActivationWorkspace(context, sessionId, workspace),
    activate: async (sessionId, workspace) => {
      await activateSessionRuntime(context, { sessionId, workspace });
    },
    assertCanStop: () => {},
    release: (sessionId, initializationFailed) =>
      releaseSessionRuntime(context, sessionId, initializationFailed ? "discard" : "close"),
    onChange: (snapshot) => {
      try {
        context.notify({
          method: ccbuddyProtocolMethods.sessionLifecycleChanged,
          params: snapshot,
        });
      } catch (error) {
        context.logger?.warn("Session lifecycle notification failed", {
          sessionId: snapshot.sessionId,
          error,
        });
      }
    },
  }));
}

export function closeSessionRuntime(
  context: CCbuddyProtocolAgentServerContext,
  sessionId: string,
  deleted = false,
): Promise<void> {
  return getSessionLifecycle(context).dispose(sessionId, () =>
    releaseSessionRuntime(context, sessionId, deleted ? "delete" : "close"),
  );
}

export async function releaseSessionRuntime(
  context: CCbuddyProtocolAgentServerContext,
  sessionId: string,
  mode: "close" | "delete" | "deactivate" | "discard",
): Promise<void> {
  const record = context.sessions.get(sessionId);
  if (!record) {
    if (mode === "close") {
      await context.v4Gateway?.releaseSessionProjection(sessionId);
      await context.v4Gateway?.finishSessionRelease(sessionId);
    }
    return;
  }
  const errors: unknown[] = [];
  const stage = async (work: () => unknown) => {
    try {
      await work();
    } catch (error) {
      errors.push(error);
    }
  };
  if (mode === "close" || mode === "delete") {
    await stage(() => record.app.runtime.beginShutdown());
    await stage(async () => {
      const target = await record.app.readTarget?.();
      if (target?.status === "active") await record.app.updateTargetStatus?.("paused");
    });
    await stage(() => {
      record.app.runtime.stopActiveForegroundExecution?.({ reason: "Session runtime closing" });
      record.activeAbortController?.abort(new Error("Session runtime closing"));
    });
  }
  await stage(() => record.unsubscribe?.());
  let projection: Promise<void> | undefined;
  await stage(() => {
    if (mode === "close")
      projection = context.v4Gateway?.releaseSessionProjection(sessionId).catch((error) => {
        errors.push(error);
      });
    else if (mode === "deactivate") context.v4Gateway?.deactivateSession(sessionId);
    else context.v4Gateway?.disposeSession(sessionId, { deleted: mode === "delete" });
  });
  // registry 缺席不表示释放完成；lifecycle 的 stopping/faulted 屏障阻止半关闭实例被复用。
  context.sessions.delete(sessionId);
  await stage(async () => {
    abortMcpUiToolCallsForSession(sessionId);
    clearMcpUiAppToolsForSession(context, sessionId);
    await record.app.unsubscribeMcpResourcesForUi?.(`${sessionId}|`);
  });
  let closed = false;
  await stage(async () => {
    await record.app.close?.();
    closed = true;
  });
  await projection;
  if (closed) {
    await stage(() => waitForSessionResidencyFinalization(record));
    if (mode === "close") await stage(() => context.v4Gateway?.finishSessionRelease(sessionId));
  }
  await stage(() => record.eventStore.deleteSession(sessionId as SessionId));
  if (errors.length)
    throw new AggregateError(errors, "Session runtime resources were not fully released");
}
