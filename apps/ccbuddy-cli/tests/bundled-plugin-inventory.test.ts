import assert from "node:assert/strict";
import { access, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  DEFAULT_ENABLED_OFFICIAL_PLUGIN_IDS,
  OFFICIAL_PLUGIN_DEFINITIONS,
} from "../packages/bootstrap/src/app/official-plugin-definitions.js";
import {
  collectSeaOfficialPluginAssets,
  officialSeaPlugins,
} from "../packages/cli/scripts/sea-official-plugin-assets.mjs";
import { DEFAULT_ENABLED_OFFICIAL_PLUGIN_IDS as settingsDefaultPlugins } from "../../../packages/shared/src/plugin-marketplaces.js";

const EXPECTED_PLUGINS = ["browser-use", "node-repl-host", "visualize"];
const cliRoot = fileURLToPath(new URL("..", import.meta.url));

test("official runtime, SEA, and Settings inventories describe the shipped plugin packages", async () => {
  assert.deepEqual(OFFICIAL_PLUGIN_DEFINITIONS.map(({ name }) => name).sort(), EXPECTED_PLUGINS);
  assert.deepEqual(officialSeaPlugins.map(({ name }) => name).sort(), EXPECTED_PLUGINS);
  assert.deepEqual(
    [...DEFAULT_ENABLED_OFFICIAL_PLUGIN_IDS].sort(),
    [...settingsDefaultPlugins].sort(),
  );
  for (const plugin of officialSeaPlugins) {
    const root = resolve(cliRoot, plugin.rootPath);
    const packageJson = JSON.parse(await readFile(join(root, "package.json"), "utf8"));
    const manifest = JSON.parse(
      await readFile(join(root, ".ccbuddy-plugin", "plugin.json"), "utf8"),
    );
    assert.equal(packageJson.name, plugin.packageName);
    assert.equal(packageJson.version, plugin.version);
    assert.equal(manifest.name, plugin.name);
    assert.equal(manifest.version, plugin.version);
    const definition = OFFICIAL_PLUGIN_DEFINITIONS.find(({ name }) => name === plugin.name)!;
    assert.equal(definition.version, plugin.version);
    for (const seedPath of definition.requiredSeedPaths ?? []) await access(join(root, seedPath));
  }
});

test("SEA asset collection includes every shipped plugin without omitted upstream packages", async () => {
  const stagingDirectory = await mkdtemp(join(tmpdir(), "ccbuddy-sea-plugins-"));
  try {
    const { manifest } = await collectSeaOfficialPluginAssets({ root: cliRoot, stagingDirectory });
    assert.deepEqual(manifest.plugins.map(({ name }) => name).sort(), EXPECTED_PLUGINS);
  } finally {
    await rm(stagingDirectory, { recursive: true, force: true });
  }
});
