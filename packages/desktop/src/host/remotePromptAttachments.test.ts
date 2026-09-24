import assert from "node:assert/strict";
import test from "node:test";
import { resolveRemotePromptAttachmentRootFromHome } from "./remotePromptAttachments.js";

test("remote prompt attachments use a CCbuddy-owned private root", () => {
  assert.equal(
    resolveRemotePromptAttachmentRootFromHome("/home/alice\n"),
    "/home/alice/.ccbuddy/tmp/prompt-attachments",
  );
  assert.throws(() => resolveRemotePromptAttachmentRootFromHome("relative/home"));
});
