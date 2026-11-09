import { describe, expect, it, vi } from "vitest";
import {
  closeSessionRuntime,
  getSessionLifecycle,
} from "../src/ccbuddy-protocol/session-runtime-lifecycle.js";
import { acquireSessionResidencyFinalization } from "../src/ccbuddy-protocol/session-finalization.js";
import { requireSession } from "../src/ccbuddy-protocol/server-types.js";
import type {
  CCbuddyProtocolAgentServerContext,
  CCbuddyProtocolSessionRecord,
} from "../src/ccbuddy-protocol/server-types.js";

function fixture() {
  const close = vi.fn(async () => {});
  const record = {
    unsubscribe: vi.fn(),
    app: { close, runtime: { beginShutdown: vi.fn(), stopActiveForegroundExecution: vi.fn() } },
    eventStore: { deleteSession: vi.fn(async () => {}) },
  } as unknown as CCbuddyProtocolSessionRecord;
  const context = {
    deps: { sessionStore: { getSession: async () => ({ time: {} }) } },
    sessions: new Map([["session", record]]),
    notify: vi.fn(),
    v4Gateway: {
      releaseSessionProjection: vi.fn(async () => {}),
      finishSessionRelease: vi.fn(async () => {}),
      disposeSession: vi.fn(),
    },
  } as unknown as CCbuddyProtocolAgentServerContext;
  return { context, record, close };
}

describe("runtime resource release boundary", () => {
  it("detaches the registry before waiting for app.close and gates a new instance", async () => {
    const { context, close } = fixture();
    const gate = Promise.withResolvers<void>();
    close.mockImplementation(() => gate.promise);
    const closing = closeSessionRuntime(context, "session");
    await vi.waitFor(() => expect(close).toHaveBeenCalledOnce());
    expect(context.sessions.has("session")).toBe(false);
    expect((await getSessionLifecycle(context).getState("session")).state).toBe("stopping");
    expect(getSessionLifecycle(context).isReady("session")).toBe(false);
    expect(() => requireSession(context, "session")).toThrow("Session is not active");
    gate.resolve();
    await closing;
    expect((await getSessionLifecycle(context).getState("session")).state).toBe("unloaded");
  });

  it("waits for original detached finalization and does not reset the inbox early", async () => {
    const { context, record, close } = fixture();
    const release = acquireSessionResidencyFinalization(record);
    const closing = closeSessionRuntime(context, "session");
    await vi.waitFor(() => expect(close).toHaveBeenCalledOnce());
    expect(context.v4Gateway!.finishSessionRelease).not.toHaveBeenCalled();
    release();
    release();
    await closing;
    expect(record.residencyFinalizationCount).toBe(0);
    expect(context.v4Gateway!.finishSessionRelease).toHaveBeenCalledOnce();
  });

  it("isolates failed cleanup while still attempting remaining resource stages", async () => {
    const { context, record, close } = fixture();
    vi.mocked(record.unsubscribe!).mockImplementation(() => {
      throw new Error("unsubscribe failed");
    });
    await expect(closeSessionRuntime(context, "session")).rejects.toThrow("resources");
    expect(close).toHaveBeenCalledOnce();
    expect(record.eventStore.deleteSession).toHaveBeenCalledOnce();
    expect((await getSessionLifecycle(context).getState("session")).state).toBe("faulted");
    await expect(getSessionLifecycle(context).ensureReady("session")).rejects.toThrow("recovery");
  });

  it("marks only actual deletion as an index-removal fact", async () => {
    const { context } = fixture();
    await closeSessionRuntime(context, "session", true);
    expect(context.v4Gateway!.disposeSession).toHaveBeenCalledWith("session", { deleted: true });
    expect(context.v4Gateway!.releaseSessionProjection).not.toHaveBeenCalled();
  });
});
