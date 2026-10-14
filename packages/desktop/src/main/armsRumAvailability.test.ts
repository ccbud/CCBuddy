import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { runInNewContext } from "node:vm";
import ts from "typescript";
import { isArmsRumEnabled } from "./armsRumAvailability.js";

test("unconfigured ARMS keeps local crash capture available", () => {
  assert.equal(isArmsRumEnabled(""), false);
});

test("configured ARMS owns remote crash capture with the optional endpoint", () => {
  assert.equal(isArmsRumEnabled("https://example.invalid/rum"), true);
});

test("a blank optional endpoint keeps local crash capture available", () => {
  assert.equal(isArmsRumEnabled(" \t "), false);
});

test("crash bootstrap passes the selected ARMS mode to Electron crash capture", async () => {
  const source = await readFile(new URL("./appCrashCaptureBootstrap.ts", import.meta.url), "utf8");
  const script = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;

  for (const armsRumEnabled of [false, true]) {
    let observedMode: boolean | undefined;
    const dependencies: Record<string, unknown> = {
      "./logger.js": { logger: {} },
      "./desktopCrashCapture.js": {
        initializeCrashCapture: (_logger: unknown, enabled: boolean) => {
          observedMode = enabled;
          return {};
        },
      },
      "./armsRumAvailability.js": { armsRumEnabled },
    };
    runInNewContext(script, {
      exports: {},
      require: (specifier: string) => {
        if (!(specifier in dependencies)) throw new Error(`Unexpected import: ${specifier}`);
        return dependencies[specifier];
      },
    });
    assert.equal(observedMode, armsRumEnabled);
  }
});
