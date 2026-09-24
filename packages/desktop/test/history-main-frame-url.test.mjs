import assert from "node:assert/strict";
import { test } from "node:test";
import { isTrustedHistoryMainFrameUrl } from "../src/main/historyMainFrameUrl.ts";

test("history access follows only the exact application renderer entry", () => {
  assert.equal(
    isTrustedHistoryMainFrameUrl(
      "file:///Applications/CCbuddy.app/Contents/Resources/app.asar/out/renderer/index.html?locale=zh-CN",
      "file:///Applications/CCbuddy.app/Contents/Resources/app.asar/out/renderer/index.html",
    ),
    true,
  );
  assert.equal(
    isTrustedHistoryMainFrameUrl("https://example.com/", "file:///app/index.html"),
    false,
  );
  assert.equal(
    isTrustedHistoryMainFrameUrl("http://127.0.0.1:5173/evil", "http://127.0.0.1:5173/"),
    false,
  );
  assert.equal(
    isTrustedHistoryMainFrameUrl("http://evil.example/", "http://127.0.0.1:5173/"),
    false,
  );
  assert.equal(
    isTrustedHistoryMainFrameUrl(
      "file:///app/index.html?windowKind=history",
      "file:///app/index.html",
    ),
    false,
  );
  assert.equal(
    isTrustedHistoryMainFrameUrl(
      "file:///app/index.html?windowKind=main&windowKind=history",
      "file:///app/index.html",
    ),
    false,
  );
  assert.equal(
    isTrustedHistoryMainFrameUrl(
      "file:///app/index.html?windowKind=main",
      "file:///app/index.html",
    ),
    true,
  );
});
