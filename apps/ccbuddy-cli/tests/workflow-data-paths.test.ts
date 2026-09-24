import assert from "node:assert/strict";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { resolveWorkspaceStateRoot } from "../packages/contracts/src/workspace-state.js";
import { isPreapprovedWorkflowDraftWrite } from "../packages/core/src/permission/workflow-draft-path.js";
import { writeWorkflowDraft } from "../packages/core/src/tool/handlers/workflow-drafts.js";
import {
  savedWorkflowRoot,
  saveSavedWorkflow,
} from "../packages/core/src/tool/handlers/saved-workflows/store.js";
import {
  workflowRunsDir,
  writeChildEntryFile,
} from "../packages/dynamic-workflow-runtime/src/child-entry-file.js";

test("workflow application files stay inside the CCbuddy data root", async () => {
  const baseDir = mkdtempSync(join(tmpdir(), "ccbuddy-workflow-test-"));
  const previousBase = process.env.CCBUDDY_DATA_BASE_DIR;
  process.env.CCBUDDY_DATA_BASE_DIR = baseDir;
  try {
    const workspace = join(baseDir, "checkout");
    mkdirSync(workspace);
    const projectRoot = resolveWorkspaceStateRoot(workspace);
    const draft = await writeWorkflowDraft({ cwd: workspace, name: "example", source: "script" });
    assert.ok(draft);
    assert.ok(draft.path.startsWith(`${projectRoot}/`));
    assert.equal(readFileSync(draft.path, "utf8"), "script");

    const saved = saveSavedWorkflow({
      cwd: workspace,
      name: "example",
      meta: { description: "example" },
      script: "export default 1;",
      scope: "project",
    });
    assert.ok(saved.path.startsWith(`${projectRoot}/`));
    assert.equal(savedWorkflowRoot(workspace, "project").dir, join(projectRoot, "workflows"));

    const global = saveSavedWorkflow({
      cwd: workspace,
      name: "example",
      meta: { description: "global" },
      script: "export default 2;",
      scope: "global",
    });
    assert.equal(global.path, join(baseDir, ".ccbuddy", "workflows", "example.dwf.ts"));

    const entry = writeChildEntryFile({ cwd: workspace, runId: "run_1", source: "export {};" });
    assert.equal(entry.path, join(workflowRunsDir(workspace), "run_1.mjs"));
    assert.equal(existsSync(join(workspace, ".ccbuddy")), false);
  } finally {
    if (previousBase === undefined) delete process.env.CCBUDDY_DATA_BASE_DIR;
    else process.env.CCBUDDY_DATA_BASE_DIR = previousBase;
    rmSync(baseDir, { recursive: true, force: true });
  }
});

test("run entry fails closed when the CCbuddy data root cannot be written", () => {
  const baseDir = mkdtempSync(join(tmpdir(), "ccbuddy-workflow-test-"));
  const previousBase = process.env.CCBUDDY_DATA_BASE_DIR;
  process.env.CCBUDDY_DATA_BASE_DIR = join(baseDir, "blocking-file");
  try {
    writeFileSync(process.env.CCBUDDY_DATA_BASE_DIR, "blocked");
    assert.throws(() =>
      writeChildEntryFile({ cwd: join(baseDir, "checkout"), runId: "run_2", source: "export {};" }),
    );
  } finally {
    if (previousBase === undefined) delete process.env.CCBUDDY_DATA_BASE_DIR;
    else process.env.CCBUDDY_DATA_BASE_DIR = previousBase;
    rmSync(baseDir, { recursive: true, force: true });
  }
});

test("logical workspace identity separates project workflow state at a shared path", async () => {
  const baseDir = mkdtempSync(join(tmpdir(), "ccbuddy-workflow-test-"));
  const previousBase = process.env.CCBUDDY_DATA_BASE_DIR;
  process.env.CCBUDDY_DATA_BASE_DIR = baseDir;
  try {
    const workspace = join(baseDir, "shared-checkout");
    const first = resolveWorkspaceStateRoot(workspace, { workspaceIdentity: "remote:alpha" });
    const second = resolveWorkspaceStateRoot(workspace, { workspaceIdentity: "remote:beta" });
    assert.notEqual(first, second);
    const firstSaved = savedWorkflowRoot(workspace, "project", {
      workspaceIdentity: "remote:alpha",
    });
    const secondSaved = savedWorkflowRoot(workspace, "project", {
      workspaceIdentity: "remote:beta",
    });
    assert.equal(firstSaved.dir, join(first, "workflows"));
    assert.equal(secondSaved.dir, join(second, "workflows"));
    const firstDraft = await writeWorkflowDraft({
      cwd: workspace,
      workspaceIdentity: "remote:alpha",
      name: "shared",
      source: "first",
    });
    const secondDraft = await writeWorkflowDraft({
      cwd: workspace,
      workspaceIdentity: "remote:beta",
      name: "shared",
      source: "second",
    });
    assert.ok(firstDraft?.path.startsWith(`${first}/`));
    assert.ok(secondDraft?.path.startsWith(`${second}/`));
    assert.equal(workflowRunsDir(workspace, "remote:alpha"), join(first, "workflow-runs"));
    assert.equal(workflowRunsDir(workspace, "remote:beta"), join(second, "workflow-runs"));
  } finally {
    if (previousBase === undefined) delete process.env.CCBUDDY_DATA_BASE_DIR;
    else process.env.CCBUDDY_DATA_BASE_DIR = previousBase;
    rmSync(baseDir, { recursive: true, force: true });
  }
});

test("draft edit approval follows the current logical workspace identity", () => {
  const workspace = join(tmpdir(), "shared-checkout");
  const alphaDraft = join(
    resolveWorkspaceStateRoot(workspace, { workspaceIdentity: "remote:alpha" }),
    "workflow-drafts",
    "review.dwf.ts",
  );
  const betaDraft = join(
    resolveWorkspaceStateRoot(workspace, { workspaceIdentity: "remote:beta" }),
    "workflow-drafts",
    "review.dwf.ts",
  );
  const check = (filePath: string) =>
    isPreapprovedWorkflowDraftWrite({
      toolName: "Edit",
      input: { file_path: filePath },
      workingDirectory: workspace,
      workspaceIdentity: "remote:alpha",
    });
  assert.equal(check(alphaDraft), true);
  assert.equal(check(betaDraft), false);
  assert.equal(check(join(workspace, ".ccbuddy", "workflow-drafts", "review.dwf.ts")), false);
});
