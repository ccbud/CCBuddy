import { beforeEach, expect, it, vi } from "vitest";
import {
  CompactTrigger,
  SessionEventType,
  createRootTraceContext,
  createSessionId,
  type Model,
} from "@ccbuddy/contracts";
import { buildCompactPrompt } from "../src/compact/prompt.js";
import { MessageHistoryImpl, type RuntimeMessageEntry } from "../src/agent/message-history.js";
import { compactActiveConversation } from "../src/runtime/methods/compact-active.js";
import {
  startSpeculativeCompaction,
  takeSpeculativeCompaction,
} from "../src/runtime/methods/speculative-compaction.js";
import { selectCompactEntries } from "../src/runtime/helpers/compact-selection.js";
import { buildCompactTimelinePayload } from "../src/runtime/methods/compact-persistence.js";
import { createToolRegistry } from "../src/tool/registry.js";
import type { AgentRuntimeInternal } from "../src/runtime/internal.js";
import type { ReadFileStateMap } from "../src/tool/types.js";

const { request } = vi.hoisted(() => ({ request: vi.fn() }));
vi.mock("../src/runtime/methods/compact-summary-model-request.js", () => ({
  runCompactSummaryModelRequest: request,
}));
beforeEach(() => request.mockReset());

function fixture() {
  const model = {
    providerId: "fixture",
    modelId: "fixture",
    optionSpecs: { maxOutputTokens: { max: 10000 } },
    properties: {
      supportsMidConversationSystem: true,
      inputFormat: ["text"],
      outputFormat: ["text"],
      contextWindow: 100000,
      maxOutputTokens: 10000,
    },
  } as unknown as Model;
  const entries: RuntimeMessageEntry[] = [
    { message: { role: "system", content: "context prefix" } },
  ];
  for (let index = 0; index < 6; index++)
    entries.push(
      { message: { role: "user", content: `request ${index}` } },
      { message: { role: "assistant", content: `response ${index}` } },
    );
  const history = new MessageHistoryImpl();
  history.replaceMessages(entries);
  const readFileState: ReadFileStateMap = new Map([
    [
      "/workspace/old.txt",
      {
        path: "/workspace/old.txt",
        content: "old",
        readAt: new Date(),
        revisionId: "old",
        sourceTool: "Read",
        isPartialView: false,
      },
    ],
  ]);
  const persist = vi.fn(async () => {});
  const telemetry = {
    run: (work: () => Promise<unknown>) => work(),
    setInputTokens: vi.fn(),
    setOutputTokens: vi.fn(),
    finishCompleted: vi.fn(),
    finishCancelled: vi.fn(),
    finishFailed: vi.fn(),
  };
  const runtime = {
    config: { toolSearch: { mode: "off" } },
    sessionId: createSessionId("two-pass"),
    workspaceRoot: "/workspace",
    workingDirectory: "/workspace",
    messageHistory: history,
    readFileState,
    registry: createToolRegistry(),
    agentTelemetry: { compaction: () => telemetry },
    getTools: () => [],
    initializeMcp: async () => {},
    extractToolCallsFromResult: () => [],
    createModelStatusSink: () => undefined,
    buildCompactTimelinePayload,
    persistCompactSummary: persist,
    persistCompactTimeline: async () => {},
    createEvent: (type: string, payload: unknown) => ({ type, payload }),
    appendEvent: async () => {},
    finishCompactTimelineFailure: async () => {},
  } as unknown as AgentRuntimeInternal;
  const trace = createRootTraceContext({ sessionId: runtime.sessionId });
  return { runtime, model, entries, persist, trace };
}

async function prepare(
  input: ReturnType<typeof fixture>,
  run: () => Promise<string> = async () => "prepared first pass",
) {
  const entries = selectCompactEntries({
    entries: input.entries,
    trigger: CompactTrigger.Auto,
  }).entriesForSummary;
  startSpeculativeCompaction(input.runtime, {
    entries,
    instructions: buildCompactPrompt(undefined),
    model: input.model,
    run,
  });
  await new Promise<void>((resolve) => setImmediate(resolve));
}

it("commits only the final pass, preserving the recent tail and replacing shared Read state after persistence", async () => {
  const input = fixture();
  await prepare(input);
  expect(input.persist).not.toHaveBeenCalled();
  expect(input.runtime.readFileState.size).toBe(1);
  const sharedMap = input.runtime.readFileState;
  input.persist.mockImplementation(async () => {
    expect(sharedMap.size).toBe(1);
  });
  request.mockResolvedValueOnce({ text: "final summary", finishReason: "stop" });
  const events: any[] = [];
  const result = await compactActiveConversation.call(
    input.runtime,
    undefined,
    input.trace,
    events,
    { trigger: CompactTrigger.Auto, model: input.model },
  );
  expect(result.outcome).toBe("compacted");
  expect(JSON.stringify(request.mock.lastCall)).toContain("prepared first pass");
  expect(input.persist).toHaveBeenCalledOnce();
  expect(events.filter((event) => event.type === SessionEventType.CompactBoundary)).toHaveLength(1);
  expect(input.runtime.readFileState).toBe(sharedMap);
  expect(sharedMap.size).toBe(0);
  expect(JSON.stringify(input.runtime.messageHistory.borrowReadOnlyRuntimeEntries())).toContain(
    "response 5",
  );
});

it("does not replace history or Read state when final persistence fails", async () => {
  const input = fixture();
  await prepare(input);
  const before = structuredClone(input.runtime.messageHistory.borrowReadOnlyRuntimeEntries());
  input.persist.mockRejectedValue(new Error("durable write failed"));
  request.mockResolvedValue({ text: "final summary", finishReason: "stop" });
  await expect(
    compactActiveConversation.call(input.runtime, undefined, input.trace, [], {
      trigger: CompactTrigger.Auto,
      model: input.model,
    }),
  ).rejects.toThrow("durable write failed");
  expect(input.runtime.messageHistory.borrowReadOnlyRuntimeEntries()).toEqual(before);
  expect(input.runtime.readFileState.size).toBe(1);
});

it("falls back to full history after a failed first pass, and never resurrects a cancelled candidate", async () => {
  const input = fixture();
  await prepare(input, async () => {
    throw new Error("first pass failed");
  });
  request.mockResolvedValueOnce({ text: "single-pass summary", finishReason: "stop" });
  await compactActiveConversation.call(input.runtime, undefined, input.trace, [], {
    trigger: CompactTrigger.Auto,
    model: input.model,
  });
  expect(JSON.stringify(request.mock.lastCall)).toContain("request 0");
  const cancelled = fixture();
  const abort = new AbortController();
  const gate = Promise.withResolvers<string>();
  startSpeculativeCompaction(cancelled.runtime, {
    entries: cancelled.entries,
    instructions: "test",
    model: cancelled.model,
    signal: abort.signal,
    run: () => gate.promise,
  });
  await new Promise<void>((resolve) => setImmediate(resolve));
  abort.abort();
  gate.resolve("late summary");
  await new Promise<void>((resolve) => setImmediate(resolve));
  expect(
    takeSpeculativeCompaction(cancelled.runtime, {
      entries: cancelled.entries,
      instructions: "test",
      model: cancelled.model,
    }),
  ).toBeUndefined();
});
