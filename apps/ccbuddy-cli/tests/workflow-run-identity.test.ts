import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  findSavedWorkflowForRunOp,
  saveSavedWorkflowFromRunOp,
} from "../packages/bootstrap/src/ccbuddy-protocol/saved-workflows-run.js";
import { listSavedWorkflowsOp } from "../packages/bootstrap/src/ccbuddy-protocol/saved-workflows.js";
import type { CCbuddyProtocolAgentServerContext } from "../packages/bootstrap/src/ccbuddy-protocol/server-types.js";
import {
  resolveSavedWorkflow,
  saveSavedWorkflow,
  savedWorkflowRoot,
} from "../packages/core/src/tool/handlers/saved-workflows/store.js";

const FIRST_SCRIPT =
  'const reviewer = agent("Reviewer");\nreturn await reviewer.ask<string>("Review");\n';
const SECOND_SCRIPT =
  'const reviewer = agent("Other reviewer");\nreturn await reviewer.ask<string>("Other review");\n';

function contextWithRun(scriptText: string, name = "review"): CCbuddyProtocolAgentServerContext {
  return {
    deps: {
      sessionStore: {
        workflowJournalStore: () => ({
          getRun: (runId: string) => ({ runId, scriptText, name, args: { target: "source" } }),
        }),
      },
    },
  } as unknown as CCbuddyProtocolAgentServerContext;
}

test("save-from-run and ordinary listing isolate identities at the same physical path", async () => {
  const baseDir = await mkdtemp(join(tmpdir(), "ccbuddy-workflow-run-identity-"));
  const previousBase = process.env.CCBUDDY_DATA_BASE_DIR;
  process.env.CCBUDDY_DATA_BASE_DIR = baseDir;
  try {
    const cwd = join(baseDir, "checkout");
    const workspaceA = {
      workspacePath: cwd,
      workspaceIdentity: "remote:alpha",
      workspaceKey: "remote:alpha",
    };
    const workspaceB = {
      workspacePath: cwd,
      workspaceIdentity: "remote:beta",
      workspaceKey: "remote:beta",
    };
    const first = await saveSavedWorkflowFromRunOp(contextWithRun(FIRST_SCRIPT), {
      workspace: workspaceA,
      runId: "first",
      name: "review",
      scope: "project",
      meta: { description: "First" },
    });
    assert.ok(first.ok);
    assert.equal(
      first.path,
      join(savedWorkflowRoot(cwd, "project", workspaceA).dir, "review.dwf.ts"),
    );
    assert.equal(
      (await listSavedWorkflowsOp(contextWithRun(FIRST_SCRIPT), { workspace: workspaceA }))
        .workflows.length,
      1,
    );
    assert.equal(
      (await listSavedWorkflowsOp(contextWithRun(FIRST_SCRIPT), { workspace: workspaceB }))
        .workflows.length,
      0,
    );

    const second = await saveSavedWorkflowFromRunOp(contextWithRun(SECOND_SCRIPT), {
      workspace: workspaceB,
      runId: "second",
      name: "review",
      scope: "project",
      meta: { description: "Second" },
    });
    assert.ok(second.ok);
    assert.notEqual(first.path, second.path);
    const blocked = await saveSavedWorkflowFromRunOp(contextWithRun(SECOND_SCRIPT), {
      workspace: workspaceA,
      runId: "replacement",
      name: "review",
      scope: "project",
      meta: { description: "Replacement" },
    });
    assert.equal(blocked.ok, false);
    if (!blocked.ok) assert.equal(blocked.reason, "target_exists");
    const replaced = await saveSavedWorkflowFromRunOp(contextWithRun(SECOND_SCRIPT), {
      workspace: workspaceA,
      runId: "replacement",
      name: "review",
      scope: "project",
      meta: { description: "Replacement" },
      overwrite: true,
    });
    assert.ok(replaced.ok && replaced.overwritten);
    const untouched = resolveSavedWorkflow({
      cwd,
      name: "review",
      scope: "project",
      workspaceIdentity: workspaceB.workspaceIdentity,
    });
    assert.ok(untouched.ok);
    if (untouched.ok) {
      assert.equal(untouched.meta.description, "Second");
      assert.equal(untouched.script, SECOND_SCRIPT);
    }

    const global = saveSavedWorkflow({
      cwd,
      name: "global",
      script: FIRST_SCRIPT,
      meta: { description: "Global" },
      scope: "global",
    });
    assert.equal(global.path, join(baseDir, ".ccbuddy", "workflows", "global.dwf.ts"));
  } finally {
    if (previousBase === undefined) delete process.env.CCBUDDY_DATA_BASE_DIR;
    else process.env.CCBUDDY_DATA_BASE_DIR = previousBase;
    await rm(baseDir, { recursive: true, force: true });
  }
});

test("find-for-run applies identity to candidate, script, and name matches", async () => {
  const baseDir = await mkdtemp(join(tmpdir(), "ccbuddy-workflow-run-identity-"));
  const previousBase = process.env.CCBUDDY_DATA_BASE_DIR;
  process.env.CCBUDDY_DATA_BASE_DIR = baseDir;
  try {
    const cwd = join(baseDir, "checkout");
    const workspaceA = {
      workspacePath: cwd,
      workspaceIdentity: "remote:alpha",
      workspaceKey: "remote:alpha",
    };
    const workspaceB = {
      workspacePath: cwd,
      workspaceIdentity: "remote:beta",
      workspaceKey: "remote:beta",
    };
    const own = saveSavedWorkflow({
      cwd,
      workspaceIdentity: workspaceA.workspaceIdentity,
      name: "own",
      script: FIRST_SCRIPT,
      meta: { description: "Own" },
      scope: "project",
    });
    saveSavedWorkflow({
      cwd,
      workspaceIdentity: workspaceB.workspaceIdentity,
      name: "foreign",
      script: SECOND_SCRIPT,
      meta: { description: "Foreign" },
      scope: "project",
    });
    for (const match of ["candidate", "script", "name"] as const) {
      const result = await findSavedWorkflowForRunOp(
        contextWithRun(match === "name" ? SECOND_SCRIPT : FIRST_SCRIPT, "own"),
        {
          workspace: workspaceA,
          runId: match,
          ...(match === "candidate" ? { candidates: [{ name: "own", scope: "project" }] } : {}),
        },
      );
      assert.equal(result.match, match);
      assert.equal(result.entry?.path, own.path);
      assert.deepEqual(result.runArgs, { target: "source" });
    }
    const foreign = await findSavedWorkflowForRunOp(contextWithRun(SECOND_SCRIPT, "foreign"), {
      workspace: workspaceA,
      runId: "foreign",
      candidates: [{ name: "foreign", scope: "project" }],
    });
    assert.equal(foreign.entry, undefined);
  } finally {
    if (previousBase === undefined) delete process.env.CCBUDDY_DATA_BASE_DIR;
    else process.env.CCBUDDY_DATA_BASE_DIR = previousBase;
    await rm(baseDir, { recursive: true, force: true });
  }
});
