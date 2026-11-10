import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";
import { build } from "tsup";
import configs from "../tsup.config.ts";
import {
  findInvalidNodeBuiltinImports,
  verifyNodeBuiltinImports,
} from "../scripts/verify-node-builtin-imports.mjs";

const root = resolve(import.meta.dirname, "../../..");

test("builtin protocol checks reject static, dynamic and CommonJS bare sqlite imports", () => {
  for (const source of [
    'import { DatabaseSync } from "sqlite";',
    'export { DatabaseSync } from "sqlite";',
    'const sqlite = import("sqlite");',
    'const sqlite = require("sqlite");',
  ]) {
    assert.deepEqual(findInvalidNodeBuiltinImports(source), ["sqlite"]);
  }
  assert.deepEqual(
    findInvalidNodeBuiltinImports(`
    import { DatabaseSync } from "node:sqlite";
    import { readFile } from "fs/promises";
    const message = 'from "sqlite"';
  `),
    [],
  );
});

test("bundle checks reject missing, empty and invalid output instead of silently passing", async (context) => {
  const directory = await mkdtemp(resolve(tmpdir(), "ccbuddy-builtin-check-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  await assert.rejects(verifyNodeBuiltinImports(resolve(directory, "missing")), { code: "ENOENT" });
  await assert.rejects(verifyNodeBuiltinImports(directory), /No JavaScript bundles found/);
  await mkdir(resolve(directory, "assets"));
  const bundle = resolve(directory, "main.mjs");
  await writeFile(bundle, 'import { DatabaseSync } from "sqlite";');
  await assert.rejects(
    verifyNodeBuiltinImports(directory),
    /Node builtin protocol missing.*sqlite/,
  );
  await writeFile(bundle, 'import { DatabaseSync } from "node:sqlite";');
  assert.equal(await verifyNodeBuiltinImports(directory), 1);
});

for (const target of ["main", "host", "scheduler"]) {
  test(`${target} tsup bundle loads the real SQLite migration entry`, async (context) => {
    const config = configs.find((candidate) => candidate.name === target);
    assert.ok(config, `missing ${target} production build configuration`);
    const directory = await mkdtemp(resolve(tmpdir(), `ccbuddy-${target}-sqlite-`));
    context.after(() => rm(directory, { recursive: true, force: true }));
    await build({
      config: false,
      entry: { migration: resolve(root, "packages/shared/src/sqlite-migrations/index.ts") },
      outDir: directory,
      format: config.format,
      platform: config.platform,
      target: config.target,
      ...(config.removeNodeProtocol === undefined
        ? {}
        : { removeNodeProtocol: config.removeNodeProtocol }),
      minify: config.minify,
      noExternal: [/.*/],
      splitting: false,
      silent: true,
      outExtension: () => ({ js: ".mjs" }),
    });
    const filename = resolve(directory, "migration.mjs");
    const source = await readFile(filename, "utf8");
    assert.match(source, /from\s*["']node:sqlite["']/);
    assert.equal(await verifyNodeBuiltinImports(directory), 1);
    const module = await import(pathToFileURL(filename).href);
    assert.equal(typeof module.sqliteMigrations.migrate, "function");
    assert.equal(typeof module.sqliteMigrations.restore, "function");
  });
}
