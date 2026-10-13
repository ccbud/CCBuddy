import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { buildToolInputResolutionContext } from "../packages/core/src/tool/executor/permission-input-adjustments.js";
import type { ToolExecutorDeps } from "../packages/core/src/tool/executor/types.js";
import { createWorkflowToolEntry } from "../packages/core/src/tool/handlers/create-workflow.js";
import { saveSavedWorkflow } from "../packages/core/src/tool/handlers/saved-workflows/store.js";
import { resolveWorkspaceStateRoot } from "../packages/contracts/src/workspace-state.js";

test("executor input resolution reads the saved workflow from the current logical identity", async () => {
  const baseDir = await mkdtemp(join(tmpdir(), "ccbuddy-workflow-resolution-"));
  const previousBase = process.env.CCBUDDY_DATA_BASE_DIR;
  process.env.CCBUDDY_DATA_BASE_DIR = baseDir;
  try {
    const cwd = join(baseDir, "shared-checkout");
    await mkdir(cwd);
    const scripts = ["return 'alpha';", "return 'beta';"];
    const identities = ["fixture-remote-alpha", "fixture-remote-beta"];
    for (const [index, workspaceIdentity] of identities.entries()) {
      saveSavedWorkflow({
        cwd,
        workspaceIdentity,
        name: "review",
        scope: "project",
        meta: { description: `Saved for ${workspaceIdentity}` },
        script: scripts[index]!,
      });
    }
    for (const [index, workspaceIdentity] of identities.entries()) {
      const context = buildToolInputResolutionContext({
        getWorkingDirectory: () => cwd,
        workspaceIdentity,
        sessionId: "fixture-session",
      } as unknown as ToolExecutorDeps);
      const resolution = await createWorkflowToolEntry.resolveInput!(
        { saved: { name: "review", scope: "project" } },
        context,
      );
      assert.equal(resolution.result, true);
      if (!resolution.result) throw new Error("Workflow resolution unexpectedly failed");
      const input = resolution.input as { script: string; saved: { path: string; draft: string } };
      assert.equal(input.script, scripts[index]);
      const stateRoot = resolveWorkspaceStateRoot(cwd, { workspaceIdentity });
      assert.ok(input.saved.path.startsWith(join(stateRoot, "workflows")));
      assert.ok(input.saved.draft.startsWith(join(stateRoot, "workflow-drafts")));
    }
  } finally {
    if (previousBase === undefined) delete process.env.CCBUDDY_DATA_BASE_DIR;
    else process.env.CCBUDDY_DATA_BASE_DIR = previousBase;
    await rm(baseDir, { recursive: true, force: true });
  }
});
