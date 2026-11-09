import { describe, expect, it, vi } from "vitest";
import type { SessionLifecycleSnapshot } from "@ccbuddy/shared";
import type { ConversationTransport } from "./transport.js";
import { ConversationProjectionStore } from "./conversationProjectionStore.js";
import { ReplaceableConversationTransport } from "./replaceableConversationTransport.js";

function fixture() {
  const listeners = new Set<(snapshot: SessionLifecycleSnapshot) => void>();
  const subscribe = vi.fn(async () => ({
    ack: { subscriptionId: "subscription", mode: "snapshot", logEpoch: "epoch" },
  }));
  const transport = {
    subscribe,
    activate: vi.fn(),
    unsubscribe: vi.fn(async () => {}),
    onAssemblyFault: () => () => {},
    onRuntimeRestart: () => () => {},
    onFrame: () => () => {},
    onSessionLifecycle: (listener: (snapshot: SessionLifecycleSnapshot) => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  } as unknown as ConversationTransport;
  const emit = (
    state: SessionLifecycleSnapshot["state"],
    revision: number,
    sessionId = "session",
  ) => {
    const snapshot: SessionLifecycleSnapshot = {
      sessionId,
      state,
      revision,
      generation: 1,
      lastError: null,
    };
    listeners.forEach((listener) => listener(snapshot));
  };
  return { transport, subscribe, emit, listeners };
}

describe("session lifecycle projection recovery", () => {
  it("does not reactivate a stopped session and reconnects exactly when ready", async () => {
    const { transport, subscribe, emit } = fixture();
    const store = new ConversationProjectionStore("conversation/session", transport);
    emit("stopping", 1);
    emit("unloaded", 2);
    emit("starting", 3);
    expect(subscribe).not.toHaveBeenCalled();
    emit("ready", 4);
    await vi.waitFor(() => expect(store.getState().status).toBe("live"));
    expect(subscribe).toHaveBeenCalledOnce();
    emit("ready", 4);
    emit("stopping", 2);
    expect(store.getState().lifecycle?.state).toBe("ready");
    expect(subscribe).toHaveBeenCalledOnce();
    await store.close();
  });

  it("ignores another session and does not reconnect a faulted runtime", async () => {
    const { transport, subscribe, emit } = fixture();
    const store = new ConversationProjectionStore("conversation/session", transport);
    emit("stopping", 1, "other");
    expect(store.getState().lifecycle).toBeUndefined();
    emit("faulted", 2);
    expect(store.getState().status).toBe("error");
    expect(subscribe).not.toHaveBeenCalled();
    await store.close();
  });

  it("discards an old ACK and completes a deferred reconnect after a release race", async () => {
    const { transport, subscribe, emit } = fixture();
    const old = Promise.withResolvers<Awaited<ReturnType<ConversationTransport["subscribe"]>>>();
    subscribe.mockImplementationOnce(() => old.promise as never);
    const store = new ConversationProjectionStore("conversation/session", transport);
    const initial = store.connect();
    emit("stopping", 1);
    emit("ready", 2);
    expect(subscribe).toHaveBeenCalledOnce();
    old.resolve({ ack: { subscriptionId: "old", mode: "snapshot", logEpoch: "epoch" } } as never);
    await initial;
    await vi.waitFor(() => expect(store.getState().subscriptionId).toBe("subscription"));
    expect(subscribe).toHaveBeenCalledTimes(2);
    expect(transport.unsubscribe).toHaveBeenCalledWith("old");
    await store.close();
  });

  it("moves the lifecycle listener to the replacement remote proxy", () => {
    const first = fixture();
    const second = fixture();
    const stable = new ReplaceableConversationTransport(first.transport);
    const listener = vi.fn();
    const off = stable.onSessionLifecycle(listener);
    first.emit("ready", 1);
    stable.replace(second.transport);
    first.emit("stopping", 2);
    second.emit("ready", 3);
    expect(listener).toHaveBeenCalledTimes(2);
    expect(first.listeners.size).toBe(0);
    off();
    expect(second.listeners.size).toBe(0);
  });
});
