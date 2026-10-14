import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { PluginMetadata } from "../packages/contracts/src/index.js";
import { createPluginAgentStateId } from "../../../packages/shared/src/index.js";
import * as subagents from "../packages/bootstrap/src/subagents.js";

test("plugin templates resolve multiple Host snapshots without rereading files or retaining model overrides", async () => {
  assert.equal(typeof subagents.loadPluginAgentTemplates, "function");
  assert.equal(typeof subagents.resolvePluginAgentProfiles, "function");
  const root = await mkdtemp(join(tmpdir(), "ccbuddy-plugin-agent-templates-"));
  try {
    await mkdir(join(root, "agents"));
    await writeFile(
      join(root, "agents", "reviewer.md"),
      "---\nname: reviewer\ndescription: Review source\n---\nReview the changes.\n",
    );
    const plugin = {
      id: "test/plugin",
      name: "test-plugin",
      enabled: true,
      rootPath: root,
      components: [{ kind: "agent", items: [{ name: "reviewer" }] }],
    } as PluginMetadata;
    const templates = await subagents.loadPluginAgentTemplates({ plugins: [plugin] });
    assert.equal(templates.profiles.length, 1);
    await rm(root, { recursive: true, force: true });
    const modelSelection = { providerId: "byok", modelId: "review-model" };
    const first = subagents.resolvePluginAgentProfiles(
      {
        plugins: [plugin],
        reservedProfileNames: ["reviewer"],
        modelSelectionOverrides: {
          [createPluginAgentStateId(plugin.id, "reviewer")]: modelSelection,
        },
      },
      templates,
    );
    assert.deepEqual(
      first.profiles.map(({ name }) => name),
      ["test-plugin:reviewer"],
    );
    assert.deepEqual(first.profiles[0]?.modelSelection, modelSelection);
    const second = subagents.resolvePluginAgentProfiles({ plugins: [plugin] }, templates);
    assert.deepEqual(
      second.profiles.map(({ name }) => name),
      ["test-plugin:reviewer", "reviewer"],
    );
    assert.equal(second.profiles[0]?.modelSelection, undefined);
    assert.equal(templates.profiles[0]?.profile.modelSelection, undefined);
    assert.deepEqual(templates.diagnostics, []);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
