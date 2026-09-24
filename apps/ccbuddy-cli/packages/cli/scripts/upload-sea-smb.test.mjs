import assert from "node:assert/strict";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import test from "node:test";
import {
  parseUploadSeaSmbArgs,
  releaseDirectoryName,
  ensureDestinationRoot,
  uploadSeaBinaries,
} from "./upload-sea-smb.mjs";

test("SEA upload requires an explicit destination before any file access", async () => {
  assert.throws(() => parseUploadSeaSmbArgs([]), /--dest-root is required/);
  await assert.rejects(uploadSeaBinaries({}), /--dest-root is required/);
});

test("SEA upload resolves an explicit destination and uses CCbuddy release names", () => {
  const cwd = resolve(tmpdir(), "ccbuddy-release-test");
  const options = parseUploadSeaSmbArgs(["--dest-root", "releases"], { cwd });
  assert.equal(options.destinationRoot, resolve(cwd, "releases"));
  assert.equal(releaseDirectoryName("0.1.0"), "ccbuddy-cli-0.1.0");
});

test("SEA upload refuses an unmounted or missing destination root", async () => {
  const missingRoot = resolve(tmpdir(), `ccbuddy-release-missing-${process.pid}`, "releases");
  await assert.rejects(ensureDestinationRoot({ destinationRoot: missingRoot }), /does not exist/);
});
