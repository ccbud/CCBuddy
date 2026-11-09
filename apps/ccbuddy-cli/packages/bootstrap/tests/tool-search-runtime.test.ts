import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, vi } from "vitest";
import {
  createSessionId,
  InMemorySessionEventStore,
  type Model,
  type ModelRequest,
  type ModelResult,
} from "@ccbuddy/contracts";
import { createSqliteSessionStore } from "../../adapters/src/storage/session-store/sqlite-session-store.js";
import { AgentRuntime } from "../../core/src/runtime.js";
import { createToolRegistry } from "../../core/src/tool/registry.js";
import { toolSearchToolEntry } from "../../core/src/tool/handlers/tool-search.js";
import { createTestRuntimeModel } from "../../core/tests/test-runtime-model.js";
import type { AgentRuntimeInternal } from "../../core/src/runtime/internal.js";
import { collectDiscoveredTools } from "../../core/src/tool/search/history.js";

it.each(["off", "on"] as const)(
  "executes deferred tools with canonical identity and cold recovery (streaming=%s)",
  async (streaming) => {
    const root = await mkdtemp(join(tmpdir(), "ccbuddy-tool-search-"));
    const dbPath = join(root, "session.sqlite");
    const sessionId = createSessionId("tool-search-runtime");
    const requests: ModelRequest[] = [];
    const registry = createToolRegistry();
    const handler = vi.fn(async (input: unknown) => input);
    registry.register({
      ...toolSearchToolEntry,
      aliases: undefined,
      metadata: { ...toolSearchToolEntry.metadata, name: "DeferredExample", shouldDefer: true },
      inputSchema: {
        type: "object",
        properties: { value: { type: "string" } },
        required: ["value"],
      },
      runtimeInputSchema: undefined,
      outputSchema: {},
      runtimeOutputSchema: undefined,
      formatModelContent: undefined,
      handler,
    });
    const response = async (request: ModelRequest): Promise<ModelResult> => {
      requests.push(request);
      const toolCalls =
        requests.length === 1
          ? [
              {
                id: "discover",
                name: "LocalToolSearch",
                input: { query: "select:DeferredExample" },
              },
            ]
          : requests.length === 2
            ? [
                {
                  id: "execute",
                  name: "DeferredToolCall",
                  input: { name: "DeferredExample", input: { value: "checked" } },
                },
              ]
            : undefined;
      return {
        text: toolCalls ? "" : "done",
        toolCalls,
        finishReason: toolCalls ? "tool-calls" : "stop",
        usage: {},
      };
    };
    const model: Model = {
      ...createTestRuntimeModel({ generateText: response }),
      async *streamText(request) {
        const result = await response(request);
        for (const toolCall of result.toolCalls ?? [])
          yield { type: "tool_call" as const, toolCall };
        if (result.text) {
          yield { type: "text_start" as const, id: "text" };
          yield { type: "text_delta" as const, id: "text", text: result.text };
          yield { type: "text_end" as const, id: "text" };
        }
        yield { type: "finish" as const, finishReason: result.finishReason, usage: result.usage };
      },
    };
    let store = await createSqliteSessionStore({ dbPath });
    const makeRuntime = () =>
      new AgentRuntime(
        sessionId,
        {
          mode: "yolo",
          toolSearch: { mode: "local" },
          compact: { enabled: false },
          modelSelection: { providerId: "test", modelId: "model" },
          modelStreaming: streaming,
          titleGeneration: { enabled: false },
          workspacePath: root,
        },
        {
          sessionStore: store,
          eventStore: new InMemorySessionEventStore({ retention: "unbounded" }),
          toolRegistry: registry,
          modelFactory: () => model,
        },
      );
    let runtime = makeRuntime();
    try {
      await runtime.executeTurn("Discover and execute the example");
      expect(handler).toHaveBeenCalledOnce();
      expect(requests).toHaveLength(3);
      const initialTools = requests[0]?.tools?.map((tool) => tool.name);
      expect(initialTools).toEqual(expect.arrayContaining(["LocalToolSearch", "DeferredToolCall"]));
      expect(initialTools).not.toContain("DeferredExample");
      expect(JSON.stringify(requests[1]?.messages)).toContain("DeferredExample");
      const stored = await store.messages({ sessionID: sessionId });
      const toolPart = stored
        .flatMap((message) => message.parts)
        .find((part) => part.type === "tool" && part.callID === "execute");
      expect(toolPart).toMatchObject({
        tool: "DeferredExample",
        metadata: { modelCallWrapper: "DeferredToolCall" },
        state: { status: "completed" },
      });
      const snapshot = () =>
        (runtime as unknown as AgentRuntimeInternal).messageHistory.toRuntimeEntries();
      const hot = snapshot();
      expect(hot.filter((entry) => entry.metadata?.toolSearchAnnouncement)).toHaveLength(1);
      await runtime.closeBrowserSession();
      store.close();
      store = await createSqliteSessionStore({ dbPath });
      runtime = makeRuntime();
      await runtime.resumeFromStore();
      const cold = snapshot();
      expect(cold.filter((entry) => entry.metadata?.toolSearchAnnouncement)).toHaveLength(1);
      expect(
        cold.some(
          (entry) =>
            entry.kind !== "attachment" &&
            entry.message.toolCalls?.some(
              (call) =>
                call.name === "DeferredExample" && call.modelCallWrapper === "DeferredToolCall",
            ),
        ),
      ).toBe(true);
      await runtime.executeTurn("Continue");
      expect(snapshot().filter((entry) => entry.metadata?.toolSearchAnnouncement)).toHaveLength(1);
      expect(handler).toHaveBeenCalledOnce();
      await runtime.executeTurn("/compact");
      const compacted = snapshot();
      expect([...collectDiscoveredTools(compacted)]).toContain("DeferredExample");
      expect(
        compacted.some((entry) =>
          entry.metadata?.compactBoundary?.preCompactDiscoveredTools?.includes("DeferredExample"),
        ),
      ).toBe(true);
      expect(requests.at(-1)?.tools?.map((tool) => tool.name)).toContain("DeferredToolCall");
      const compactRecords = await store.messages({ sessionID: sessionId });
      expect(
        compactRecords
          .flatMap((message) => message.parts)
          .some(
            (part) =>
              part.type === "compaction" &&
              part.compactBoundary?.preCompactDiscoveredTools?.includes("DeferredExample"),
          ),
      ).toBe(true);
      await runtime.closeBrowserSession();
      store.close();
      store = await createSqliteSessionStore({ dbPath });
      runtime = makeRuntime();
      await runtime.resumeFromStore();
      expect([...collectDiscoveredTools(snapshot())]).toContain("DeferredExample");
    } finally {
      await runtime.closeBrowserSession();
      store.close();
      await rm(root, { recursive: true, force: true });
    }
  },
);
