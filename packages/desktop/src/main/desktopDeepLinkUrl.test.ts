import assert from "node:assert/strict";
import test from "node:test";
import { extractDeepLinkUrlFromArgs, isWorkspaceOpenUrl } from "./desktopDeepLinkUrl.js";

test("CCbuddy accepts its own workspace links without claiming CCbuddy links", () => {
  const ownLink = "ccbuddy://workspace/open?path=%2Ftmp%2Fproject";
  const upstreamLink = "ccbuddy://workspace/open?path=%2Ftmp%2Fproject";

  assert.equal(extractDeepLinkUrlFromArgs([ownLink]), ownLink);
  assert.equal(extractDeepLinkUrlFromArgs([upstreamLink]), null);
  assert.equal(isWorkspaceOpenUrl(new URL(ownLink)), true);
  assert.equal(isWorkspaceOpenUrl(new URL(upstreamLink)), false);
});
