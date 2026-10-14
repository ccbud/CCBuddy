import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { mock, test } from "node:test";
import { loadBuiltinProviderConfig } from "../builtin-provider-config.mjs";

const root = resolve(import.meta.dirname, "../..");

test("development and production stage the same local BYOK template", async () => {
  const testConfig = await loadBuiltinProviderConfig({ env: { CCBUDDY_ENV: "test" } });
  const productionConfig = await loadBuiltinProviderConfig({
    env: { CCBUDDY_ENV: "production" },
  });
  assert.equal(testConfig.environment, "test");
  assert.equal(productionConfig.environment, "production");
  assert.equal(testConfig.content, productionConfig.content);
});

test("optional desktop capabilities default to closed ports", async () => {
  const { resolveBuildTimeConfig, createBuildTimeConfigDefines } =
    await import("../build-time-config.mjs");
  const config = await resolveBuildTimeConfig({});
  assert.equal(config.armsRumEndpoint, "");
  assert.equal(config.telemetryReportEndpoint, "");
  assert.equal(config.autoUpdateEnabled, false);
  assert.equal(createBuildTimeConfigDefines(config).__CCBUDDY_UPDATE_MANIFEST_URL__, '""');
  const flagOnly = await resolveBuildTimeConfig({ CCBUDDY_AUTO_UPDATE: "1" });
  assert.equal(flagOnly.autoUpdateEnabled, false);
});

test("a CCbuddy release embeds its explicit update source", async () => {
  const { resolveBuildTimeConfig, createBuildTimeConfigDefines } =
    await import("../build-time-config.mjs");
  const manifest = "https://updates.ccbuddy.example/releases/latest.yml";
  const config = await resolveBuildTimeConfig({ CCBUDDY_UPDATE_MANIFEST_URL: manifest });
  assert.equal(config.autoUpdateEnabled, true);
  assert.equal(
    createBuildTimeConfigDefines(config).__CCBUDDY_UPDATE_MANIFEST_URL__,
    JSON.stringify(manifest),
  );
  await assert.rejects(
    resolveBuildTimeConfig({ CCBUDDY_UPDATE_MANIFEST_URL: "http://updates.example/latest.yml" }),
  );
});

test("every staged official plugin has its source manifest and required seed", async () => {
  const { officialPluginPackages } =
    await import("../../packages/desktop/scripts/agent-official-plugin-packages.mjs");
  assert.ok(officialPluginPackages.length > 0);
  for (const plugin of officialPluginPackages) {
    const directory = resolve(root, plugin.relativePath);
    const manifest = JSON.parse(
      await readFile(resolve(directory, ".ccbuddy-plugin/plugin.json"), "utf8"),
    );
    assert.ok(manifest.name);
    for (const asset of plugin.requiredSeedPaths ?? []) {
      assert.ok(existsSync(resolve(directory, asset)), `${plugin.packageName}: ${asset}`);
    }
  }
});

test("desktop build entries only reference shipped source files", async () => {
  const directory = resolve(root, "packages/desktop");
  const config = await readFile(resolve(directory, "tsup.config.ts"), "utf8");
  const entries = [...config.matchAll(/"[^"]+":\s*"(src\/[^"]+)"/g)];
  assert.ok(entries.length > 0);
  for (const [, entry] of entries) {
    assert.ok(existsSync(resolve(directory, entry)), `missing Desktop build entry: ${entry}`);
  }
});

test("desktop TypeScript project references all resolve", async () => {
  const directory = resolve(root, "packages/desktop");
  const project = JSON.parse(await readFile(resolve(directory, "tsconfig.json"), "utf8"));
  for (const reference of project.references) {
    assert.ok(
      existsSync(resolve(directory, reference.path)),
      `missing Desktop project: ${reference.path}`,
    );
  }
});

test("bootstrap with remote assets dispatches only existing package directories", async (t) => {
  const calls = [];
  t.after(() => mock.reset());
  mock.module(new URL("../spawn-command.mjs", import.meta.url).href, {
    namedExports: {
      runCommand: (command, args, options) => {
        assert.ok(existsSync(options.cwd), `missing bootstrap cwd: ${options.cwd}`);
        calls.push({ command, args, options });
        return { status: 0 };
      },
    },
  });
  mock.property(process, "argv", [...process.argv, "--with-remote"]);
  await import("../bootstrap.mjs");
  assert.ok(calls.some(({ options }) => options.cwd === resolve(root, "packages/server")));
  assert.ok(calls.some(({ options }) => options.cwd === resolve(root, "packages/desktop")));
});
