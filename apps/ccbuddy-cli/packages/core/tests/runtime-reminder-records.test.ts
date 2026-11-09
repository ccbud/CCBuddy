import { describe, expect, it, vi } from "vitest";
import { createRootTraceContext, createSessionId } from "@ccbuddy/contracts";
import { systemReminderAttachmentEntry } from "../src/agent/message-history.js";
import type { AgentRuntimeInternal } from "../src/runtime/internal.js";
import { persistAnnouncements } from "../src/runtime/methods/context-refresh.js";
import { buildRuntimeReminderMessage } from "../src/runtime/methods/runtime-reminder-persistence.js";
import type { TurnRequestState } from "../src/runtime/methods/turn-loop-state.js";

function fixture() {
  const runtime = {
    sessionId: createSessionId("reminder-records"),
    config: {},
    latestConversationMessageId: "real-input",
    sessionStore: { removeMessage: vi.fn() },
    getSessionModelSelection: () => ({ providerId: "test", modelId: "model" }),
    persistMessage: vi.fn(),
    persistPart: vi.fn(),
    messageHistory: { appendRuntimeEntries: vi.fn() },
  };
  return { runtime, internal: runtime as unknown as AgentRuntimeInternal };
}

describe("hidden runtime reminder persistence", () => {
  it("keeps the conversation pointer and omits closed top-level source values", () => {
    const { internal, runtime } = fixture();
    const entry = systemReminderAttachmentEntry("tool_search_announcement", "available tools");
    const record = buildRuntimeReminderMessage(internal, entry);
    expect(record?.info).toMatchObject({ synthetic: true, visibility: "model-only" });
    expect(record?.info.source).toBeUndefined();
    expect(record?.info.semantics).toMatchObject({
      kind: "system_reminder",
      uiVisibility: "hidden",
    });
    expect(record?.parts[0]).toMatchObject({
      text: "available tools",
      metadata: { runtimeMessage: entry.metadata },
    });
    expect(runtime.latestConversationMessageId).toBe("real-input");
  });

  it("does not admit an announcement when persistence fails", async () => {
    const { runtime, internal } = fixture();
    const failure = new Error("storage unavailable");
    runtime.persistPart.mockRejectedValueOnce(failure);
    const state = { entries: [] } as unknown as TurnRequestState;
    await expect(
      persistAnnouncements(
        internal,
        state,
        [systemReminderAttachmentEntry("tool_search_announcement", "available tools")],
        createRootTraceContext(),
      ),
    ).rejects.toBe(failure);
    expect(state.entries).toEqual([]);
    expect(runtime.messageHistory.appendRuntimeEntries).not.toHaveBeenCalled();
    expect(runtime.sessionStore.removeMessage).toHaveBeenCalledOnce();
    expect(runtime.latestConversationMessageId).toBe("real-input");
  });
});
