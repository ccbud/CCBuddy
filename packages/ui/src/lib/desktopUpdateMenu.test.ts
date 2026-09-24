import assert from "node:assert/strict";
import test from "node:test";
import { shouldDisplayDesktopUpdateEntry } from "./desktopUpdateMenu.js";

test("CCbuddy hides an unconfigured updater but keeps active update progress visible", () => {
  assert.equal(shouldDisplayDesktopUpdateEntry(null, "production"), false);
  assert.equal(
    shouldDisplayDesktopUpdateEntry({ kind: "idle", enabled: false }, "production"),
    false,
  );
  assert.equal(
    shouldDisplayDesktopUpdateEntry({ kind: "checking", enabled: false }, "production"),
    true,
  );
  assert.equal(
    shouldDisplayDesktopUpdateEntry(
      { kind: "download-progress", enabled: false, progress: "42%" },
      "production",
    ),
    true,
  );
  assert.equal(shouldDisplayDesktopUpdateEntry({ kind: "idle", enabled: true }, "preview"), false);
});
