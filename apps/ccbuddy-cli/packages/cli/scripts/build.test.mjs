import assert from "node:assert/strict";
import { resolve } from "node:path";
import test from "node:test";
import { build } from "esbuild";
import { resolveBuildAliases } from "./build.mjs";

test("CLI bundling resolves the GenUI model context through the shared subpath", async () => {
  const result = await build({
    stdin: {
      contents: 'export { genUiModelContextSchema } from "@ccbuddy/shared/gen-ui";',
      resolveDir: resolve(import.meta.dirname, "../src"),
      sourcefile: "gen-ui-build-regression.ts",
    },
    alias: resolveBuildAliases(),
    bundle: true,
    format: "esm",
    platform: "node",
    target: "node22",
    write: false,
    metafile: true,
    logLevel: "silent",
  });
  const inputs = Object.keys(result.metafile.inputs);
  assert.ok(inputs.some((input) => input.endsWith("packages/shared/src/gen-ui/contract.ts")));
  assert.match(result.outputFiles[0].text, /genUiModelContextSchema/);
});
