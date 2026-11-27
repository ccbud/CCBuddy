import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { resolve } from "node:path";
import test from "node:test";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const cli = resolve(import.meta.dirname, "../dist/ccbuddy.cjs");

test("sets the visible process name before running commands", async () => {
  const { stdout } = await execFileAsync(process.execPath, [cli, "doctor", "--json"], {
    env: { ...process.env, CCBUDDY_PLUGIN_ID: "documents@ccbuddy-plugins-official" },
  });
  const payload = JSON.parse(stdout);

  assert.equal(payload.cli.name, "ccbuddy");
  assert.equal(payload.cli.processName, "ccbuddy-cli");
  assert.equal(payload.runtime.processTitle, "ccbuddy-cli");
});
