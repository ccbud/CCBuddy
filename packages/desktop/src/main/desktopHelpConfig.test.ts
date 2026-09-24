import assert from "node:assert/strict";
import test from "node:test";
import { createDesktopHelpConfigReader } from "./desktopHelpConfig.js";

test("CCbuddy help links resolve locally to CCbuddy resources", async () => {
  const config = await createDesktopHelpConfigReader()();
  assert.equal(config.feedback_use_external_form, true);
  assert.match(config.feedback_url ?? "", /^https:\/\/github\.com\/ccbud\/CCBuddy\/issues\//);
  assert.equal(config.community_urls?.["en-US"], "https://github.com/ccbud/CCBuddy");
});
