import { describe, expect, it } from "vitest";
import { genUiModelContextSchema, selectGenUiModelContext } from "@ccbuddy/shared/gen-ui";
import { attachGenUiContext, normalizeGenUiInput } from "../src/agent/gen-ui-context.js";
import {
  createRuntimeUserEntry,
  systemReminderAttachmentEntry,
  type RuntimeMessageEntry,
} from "../src/agent/message-history.js";
import { runtimeInputMetadata } from "../src/agent/runtime-input-presentation.js";
import { buildProviderRequestMessages } from "../src/runtime/helpers/provider-request-messages.js";
import { buildRuntimeUserEntriesFromTurn } from "../src/runtime/helpers/conversation.js";

const context = [{ path: "/project/example.html", state: { stage: "entry" } }];
const legacy = `Question\n\n<untrusted_gen_ui_state>\n${JSON.stringify(context)}\n</untrusted_gen_ui_state>`;

function markers(messages: readonly unknown[]): string[] {
  return [...JSON.stringify(messages).matchAll(/mk:([a-z0-9-]+)/g)].map((match) => match[1]!);
}

function guide(name: string): RuntimeMessageEntry {
  return attachGenUiContext(
    createRuntimeUserEntry(`mk:${name}`, runtimeInputMetadata("user_steer")),
    [{ ...context[0]!, state: `mk:${name}-state` }],
  );
}

describe("Gen UI input snapshots", () => {
  it("selects JSON-only bounded model state without private data", () => {
    expect(
      selectGenUiModelContext([
        {
          path: context[0]!.path,
          state: { modelContent: context[0]!.state, privateContent: "SECRET" },
        },
        { path: "/project/empty.html", state: { modelContent: null, privateContent: "SECRET" } },
      ]),
    ).toEqual(context);
    for (const input of [
      [{ ...context[0], state: Infinity }],
      [{ ...context[0], state: undefined }],
      [{ ...context[0], state: "x".repeat(16385) }],
      Array(101).fill(context[0]),
      Array(5).fill({ ...context[0], state: "x".repeat(15000) }),
    ])
      expect(genUiModelContextSchema.safeParse(input).success).toBe(false);
  });

  it("decodes only a valid legacy tail, preserving explicit new-protocol text", () => {
    expect(normalizeGenUiInput(legacy)).toEqual({ text: "Question", genUiContext: context });
    expect(normalizeGenUiInput(legacy, [])).toEqual({ text: legacy, genUiContext: [] });
    for (const text of [
      `${legacy}\nreal text`,
      "Question\n\n<untrusted_gen_ui_state>\nbad\n</untrusted_gen_ui_state>",
      `\`\`\`text\n${legacy}\n\`\`\``,
      "ordinary text",
    ])
      expect(normalizeGenUiInput(text).text).toBe(text);
  });

  it("keeps state off visible text and derives one user-side reminder", () => {
    const entries = buildRuntimeUserEntriesFromTurn("Question", [], { genUiContext: context });
    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatchObject({
      message: { role: "user", content: "Question" },
      metadata: { source: "real_user", genUiState: expect.stringContaining('"stage":"entry"') },
    });
    const { messages } = buildProviderRequestMessages({ entries });
    expect(JSON.stringify(messages).split("untrusted page state")).toHaveLength(2);
    expect(messages[1]).toMatchObject({
      role: "user",
      content: expect.stringContaining("<system-reminder>"),
    });
    const plain = createRuntimeUserEntry("Question");
    expect(attachGenUiContext(plain, [])).toBe(plain);
    expect(
      attachGenUiContext(plain, [{ ...context[0]!, state: "</system-reminder>" }]).metadata
        ?.genUiState,
    ).not.toContain("</system-reminder>");
  });

  it.each([true, false])("keeps consecutive inputs paired (MCS=%s)", (useMidConversationSystem) => {
    const entries = ["first", "second"].flatMap((name) =>
      buildRuntimeUserEntriesFromTurn(`mk:${name}`, [], {
        genUiContext: [{ ...context[0]!, state: `mk:${name}-state` }],
      }),
    );
    expect(
      markers(buildProviderRequestMessages({ entries, useMidConversationSystem }).messages),
    ).toEqual(["first", "first-state", "second", "second-state"]);
  });

  it.each([true, false])(
    "keeps guide states outside system after projection (MCS=%s)",
    (useMidConversationSystem) => {
      const entries: RuntimeMessageEntry[] = [
        createRuntimeUserEntry("mk:task"),
        {
          message: {
            role: "assistant",
            content: "",
            toolCalls: [{ id: "call-1", name: "Read", input: {} }],
          },
        },
        { message: { role: "tool", content: "mk:tool", toolCallId: "call-1", toolName: "Read" } },
        systemReminderAttachmentEntry("runtime_mode", "mk:mode"),
        guide("first"),
        guide("second"),
      ];
      const { messages } = buildProviderRequestMessages({ entries, useMidConversationSystem });
      expect(markers(messages)).toEqual(
        useMidConversationSystem
          ? ["task", "tool", "first-state", "second-state", "mode", "first", "second"]
          : ["task", "tool", "mode", "first", "first-state", "second", "second-state"],
      );
      expect(
        messages
          .filter((message) => message.role === "system")
          .some((message) => JSON.stringify(message).includes("-state")),
      ).toBe(false);
    },
  );
});
