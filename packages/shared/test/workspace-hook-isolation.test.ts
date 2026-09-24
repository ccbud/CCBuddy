import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  discoverWorkspaceHookConfigPaths,
  readWorkspaceHookProjectSources,
} from "../src/workspace-hook-config.ts";

test("workspace hooks ignore old project config unless its path is explicit", async () => {
  const workspacePath = await mkdtemp(join(tmpdir(), "ccbuddy-hook-project-"));
  const oldConfig = join(workspacePath, ".ccbuddy", "config.json");
  try {
    await mkdir(join(workspacePath, ".ccbuddy"));
    await writeFile(oldConfig, JSON.stringify({ hooks: { enabled: true } }));
    await writeFile(
      join(workspacePath, "ccbuddy.json"),
      JSON.stringify({ hooks: { enabled: true } }),
    );

    assert.deepEqual(discoverWorkspaceHookConfigPaths({ workingDirectory: workspacePath }), []);
    assert.deepEqual(await readWorkspaceHookProjectSources({ workingDirectory: workspacePath }), {
      sources: [],
      errors: [],
    });

    const explicit = await readWorkspaceHookProjectSources({
      workingDirectory: workspacePath,
      explicitProjectConfigPath: oldConfig,
    });
    assert.equal(explicit.sources.length, 1);
    assert.equal(explicit.sources[0]?.editable, false);
  } finally {
    await rm(workspacePath, { recursive: true, force: true });
  }
});
