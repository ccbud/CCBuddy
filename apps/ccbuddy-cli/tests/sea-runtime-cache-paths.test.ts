import assert from "node:assert/strict";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { resolveSeaRuntimeCacheBaseDirectory } from "../packages/cli/src/sea-runtime-cache-path.js";

test("SEA runtime assets use the CCbuddy application data root", () => {
  const previousBase = process.env.CCBUDDY_DATA_BASE_DIR;
  try {
    delete process.env.CCBUDDY_DATA_BASE_DIR;
    assert.equal(
      resolveSeaRuntimeCacheBaseDirectory(),
      join(homedir(), ".ccbuddy", "cli", "cache", "sea-assets"),
    );

    const testBase = join(tmpdir(), "ccbuddy-sea-cache-test");
    assert.equal(
      resolveSeaRuntimeCacheBaseDirectory(testBase),
      join(testBase, ".ccbuddy", "cli", "cache", "sea-assets"),
    );
  } finally {
    if (previousBase === undefined) delete process.env.CCBUDDY_DATA_BASE_DIR;
    else process.env.CCBUDDY_DATA_BASE_DIR = previousBase;
  }
});
