import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import {
  createSessionId,
  createModelProviderId,
  createModelId,
  InMemorySessionEventStore,
  type Model,
  type ModelRequest,
  type TurnInputIntentMetadata,
} from "@ccbuddy/contracts";
import { createSqliteSessionStore } from "../../adapters/src/storage/session-store/sqlite-session-store.js";
import { AgentRuntime } from "../../core/src/runtime.js";
import type { AgentRuntimeInternal } from "../../core/src/runtime/internal.js";

it("retains one frozen Gen UI snapshot across SQLite cold recovery", async () => {
  const root = await mkdtemp(join(tmpdir(), "ccbuddy-gen-ui-context-"));
  const dbPath = join(root, "session.sqlite");
  const sessionId = createSessionId("gen-ui-context");
  const requests: ModelRequest[] = [];
  const genUiContext = [{ path: "/project/example.html", state: "FROZEN_GEN_UI_STATE" }];
  const intent: TurnInputIntentMetadata = {
    sourceCommandId: "input",
    queueItemId: "input",
    clientId: "desktop",
    kind: "sendText",
    text: "Question",
    admissionSeq: 1,
    admittedAt: 100,
    requestedDelivery: "startNow",
    admittedDelivery: "startNow",
    genUiContext,
  };
  let store = await createSqliteSessionStore({ dbPath });
  const model: Model = {
    providerId: createModelProviderId("test"),
    modelId: createModelId("model"),
    properties: {
      contextWindow: 200000,
      inputFormat: {
        supportsText: true,
        supportsImage: false,
        supportsVideo: false,
        supportsAudio: false,
        supportsPdf: false,
      },
      outputFormat: { supportsText: true },
      supportsToolCall: true,
      supportsJsonSchemaOutput: true,
      supportsNativeWebSearch: false,
      supportsMidConversationSystem: true,
    },
    optionSpecs: { maxOutputTokens: { max: 32000 }, reasoningLevel: { values: ["disabled"] } },
    options: { maxOutputTokens: 32000, reasoningLevel: "disabled" },
    bind(options) {
      return { ...model, options: { ...model.options, ...options } };
    },
    async generateText(request) {
      requests.push(request);
      return { text: "done", finishReason: "stop", usage: {} };
    },
    async *streamText() {
      throw new Error("Streaming must remain disabled in this fixture");
    },
  };
  const makeRuntime = () =>
    new AgentRuntime(
      sessionId,
      {
        modelSelection: { providerId: "test", modelId: "model" },
        modelStreaming: "off",
        titleGeneration: { enabled: false },
        workspacePath: root,
      },
      {
        sessionStore: store,
        eventStore: new InMemorySessionEventStore({ retention: "unbounded" }),
        modelFactory: () => model,
      },
    );
  let runtime = makeRuntime();
  try {
    await runtime.executeTurn("Question", undefined, { inputId: "input", intent });
    expect(JSON.stringify(requests.at(-1)?.messages).split("FROZEN_GEN_UI_STATE")).toHaveLength(2);
    const stored = await store.messages({ sessionID: sessionId });
    expect(
      stored.find((message) =>
        message.parts.some((part) => part.type === "text" && part.text === "Question"),
      )?.info.metadata?.conversationInputIntent,
    ).toMatchObject({ text: "Question", genUiContext });
    const snapshot = () =>
      (runtime as unknown as AgentRuntimeInternal).messageHistory.toRuntimeEntries();
    const hot = snapshot();
    await runtime.closeBrowserSession();
    store.close();
    store = await createSqliteSessionStore({ dbPath });
    runtime = makeRuntime();
    await runtime.resumeFromStore();
    const cold = snapshot();
    const states = (entries: typeof hot) =>
      entries.flatMap((entry) => (entry.metadata?.genUiState ? [entry.metadata.genUiState] : []));
    expect(states(hot)).toEqual([expect.stringContaining("FROZEN_GEN_UI_STATE")]);
    expect(states(cold)).toEqual(states(hot));
    expect(
      [...hot, ...cold].filter(
        (entry) => entry.kind === "attachment" && entry.metadata?.source === "gen_ui_state",
      ),
    ).toEqual([]);
    await runtime.executeTurn("Continue");
    expect(JSON.stringify(requests.at(-1)?.messages).split("FROZEN_GEN_UI_STATE")).toHaveLength(2);
  } finally {
    await runtime.closeBrowserSession();
    store.close();
    await rm(root, { recursive: true, force: true });
  }
});
