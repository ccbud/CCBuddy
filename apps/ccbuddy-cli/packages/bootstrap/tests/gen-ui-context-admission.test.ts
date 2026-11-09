import { describe, expect, it, vi } from "vitest";
import {
  SessionEventType,
  type SessionEvent,
  type TurnInputIntentMetadata,
  type MessageWithParts,
} from "@ccbuddy/contracts";
import { queueItemSchema, type CommandEnvelope } from "@ccbuddy/shared/ccbuddy-protocol-v4";
import { ProductProjection } from "../src/ccbuddy-protocol-v4/product-projection.js";
import {
  inputIntentMetadata,
  inputIntentMetadataFromCanonical,
  inputIntentMetadataFromQueueItem,
} from "../src/ccbuddy-protocol-v4/commands/input-intent.js";
import { resolveInputCommandForAdmission } from "../src/ccbuddy-protocol/v4-bridge.js";
import { mapMessageWithParts } from "../src/ccbuddy-protocol/message-mapper.js";

const genUiContext = [{ path: "/project/example.html", state: "FROZEN" }];
const legacy = `Question\n\n<untrusted_gen_ui_state>\n${JSON.stringify(genUiContext)}\n</untrusted_gen_ui_state>`;
const intent: TurnInputIntentMetadata = {
  sourceCommandId: "source",
  queueItemId: "input",
  clientId: "desktop",
  kind: "sendText",
  text: "Question",
  admissionSeq: 1,
  admittedAt: 100,
  requestedDelivery: "queue",
  admittedDelivery: "queue",
  queuePosition: 0,
  genUiContext,
};
function envelope(payload: unknown): CommandEnvelope {
  return {
    commandId: "new",
    clientId: "desktop",
    sessionId: "session",
    type: "sendText",
    payload,
    issuedAt: 1,
  };
}
function event(sequence: number, text: string, metadata?: TurnInputIntentMetadata): SessionEvent {
  return {
    id: `event-${sequence}`,
    sessionId: "session",
    turnId: "turn",
    type: SessionEventType.TurnSteerQueued,
    timestamp: new Date(100 + sequence),
    traceId: "trace",
    sequenceNumber: sequence,
    payload: {
      pendingInputId: "input",
      input: text,
      queueLength: 1,
      delivery: "queue",
      ...(metadata ? { intent: metadata } : {}),
    },
  } as SessionEvent;
}

describe("Gen UI admission, projection and replay", () => {
  it.each([{ text: "Question", genUiContext }, { text: legacy }])(
    "normalizes before admission (%j)",
    (payload) => {
      expect(resolveInputCommandForAdmission(envelope(payload), "session", vi.fn())).toMatchObject({
        text: "Question",
        genUiContext,
      });
    },
  );

  it.each([{ context: genUiContext }, { context: [] }])(
    "retains even an empty explicit snapshot (%j)",
    ({ context }) => {
      expect(
        inputIntentMetadata(envelope({ text: "Question" }), {
          text: "Question",
          requestedDelivery: "queue",
          genUiContext: context,
        }).genUiContext,
      ).toEqual(context);
      expect(
        inputIntentMetadataFromCanonical(
          envelope({}),
          { kind: "sendText", text: "Question", genUiContext: context },
          "Edited",
        ),
      ).toMatchObject({ text: "Edited", genUiContext: context });
    },
  );

  it("carries the frozen snapshot through queue edits and promotion", () => {
    const projection = new ProductProjection("session", "epoch");
    projection.applyEvent(event(1, "Question", intent));
    projection.applyEvent(event(2, "Edited"));
    const item = queueItemSchema.parse(projection.getSnapshot().queue.items[0]);
    expect(inputIntentMetadataFromQueueItem(item, item.text)).toEqual({
      ...intent,
      text: "Edited",
      attachmentRefs: [],
    });
  });

  it("normalizes old queue tails before promotion", () => {
    const projection = new ProductProjection("session", "epoch");
    projection.applyEvent(event(1, legacy));
    const item = queueItemSchema.parse(projection.getSnapshot().queue.items[0]);
    expect(item).toMatchObject({ text: "Question", genUiContext });
    expect(inputIntentMetadataFromQueueItem(item, item.text).genUiContext).toEqual(genUiContext);
  });

  it.each([{ context: undefined }, { context: [] }])(
    "history and search normalize only old-format tails (%j)",
    ({ context }) => {
      const message = {
        info: {
          id: "message",
          sessionID: "session",
          role: "user",
          time: { created: 1 },
          metadata: { conversationInputIntent: { genUiContext: context } },
        },
        parts: [
          { id: "part", messageID: "message", sessionID: "session", type: "text", text: legacy },
        ],
      } as unknown as MessageWithParts;
      expect(mapMessageWithParts(message).parts[0]).toMatchObject({
        text: context ? legacy : "Question",
      });
      expect(message.parts[0]).toMatchObject({ text: legacy });
    },
  );
});
