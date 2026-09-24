import assert from "node:assert/strict";
import test from "node:test";
import { resolveRemoteCdnBaseUrls } from "./remoteCdn.js";

test("CCbuddy remote assets have no inherited CDN fallback", (t) => {
  const previous = process.env.CCBUDDY_CDN_BASE_URL;
  delete process.env.CCBUDDY_CDN_BASE_URL;
  t.after(() => {
    if (previous === undefined) delete process.env.CCBUDDY_CDN_BASE_URL;
    else process.env.CCBUDDY_CDN_BASE_URL = previous;
  });

  assert.deepEqual(resolveRemoteCdnBaseUrls(), []);
  assert.deepEqual(
    resolveRemoteCdnBaseUrls({ overrideBaseUrl: "https://assets.example.com/ccbuddy/releases" }),
    ["https://assets.example.com/ccbuddy/releases"],
  );
});
