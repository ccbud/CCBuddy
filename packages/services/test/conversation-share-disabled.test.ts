import assert from "node:assert/strict";
import { test } from "node:test";
import { Event } from "@ccbuddy/rpc";
import {
  ConversationShareServiceError,
  createUnsupportedConversationShareService,
} from "../src/conversation-share/conversationShare.ts";

test("disabled conversation sharing rejects every publishing and import route", async () => {
  const rejected: string[] = [];
  const service = createUnsupportedConversationShareService({
    message: "Conversation sharing is unavailable in CCbuddy",
    onRejected: (action) => rejected.push(action),
  });
  const operations = [
    service.getCapabilities(),
    service.preflight({} as Parameters<typeof service.preflight>[0]),
    service.publish({} as Parameters<typeof service.publish>[0], "publish"),
    service.importShare({} as Parameters<typeof service.importShare>[0], "import"),
    service.getPreview("share-code"),
    service.getContinuation({ shareCode: "share-code", clientRequestId: "request" }),
  ];

  for (const operation of operations) {
    await assert.rejects(operation, (error: unknown) => {
      assert.ok(error instanceof ConversationShareServiceError);
      assert.equal(error.kind, "feature_disabled");
      assert.equal(error.message, "Conversation sharing is unavailable in CCbuddy");
      return true;
    });
  }
  assert.deepEqual(rejected, [
    "getCapabilities",
    "preflight",
    "publish",
    "importShare",
    "getPreview",
    "getContinuation",
  ]);
  assert.equal(service.onDynamicPublishProgress("publish"), Event.None);
  assert.equal(service.onDynamicImportProgress("import"), Event.None);
  assert.equal(
    await service.getImportedConversation({ workspacePath: "/project", contextId: "context" }),
    null,
  );
});
