import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { afterEach, test } from "node:test";
import { runInNewContext } from "node:vm";
import ts from "typescript";
import { isRealComputerUseProducerInstalled } from "../scripts/computer-use-producer.mjs";
import { verifyStagedKoffi } from "../scripts/koffi-package-assets.mjs";

const source = await readFile(new URL("../electron-builder.config.js", import.meta.url), "utf8");
const tree = ts.createSourceFile(
  "electron-builder.config.js",
  source,
  ts.ScriptTarget.Latest,
  true,
);
const assertion = tree.statements.find(
  (node) => ts.isFunctionDeclaration(node) && node.name?.text === "assertPackagedCuaKoffi",
);
assert.ok(assertion, "the packaged Computer Use Koffi check must exist");
const directories = [];

afterEach(async () => {
  await Promise.all(
    directories.splice(0).map((path) => rm(path, { recursive: true, force: true })),
  );
});

async function fixture(manifest) {
  const root = await mkdtemp(resolve(tmpdir(), "ccbuddy-cua-koffi-test-"));
  directories.push(root);
  const desktopPackageRoot = resolve(root, "packages", "desktop");
  const resourcesDir = resolve(root, "Resources");
  await mkdir(desktopPackageRoot, { recursive: true });
  if (manifest) {
    const producerRoot = resolve(desktopPackageRoot, "node_modules", "@ccbuddy", "ccbuddy-cua");
    await mkdir(producerRoot, { recursive: true });
    await writeFile(resolve(producerRoot, "package.json"), JSON.stringify(manifest));
  }
  // Evaluate the real afterPack assertion with its ordinary producer detector
  // and resource verifier, without launching Electron or repacking an ASAR.
  const check = runInNewContext(`(${assertion.getText(tree)})`, {
    shouldPackageComputerUseHelper: isRealComputerUseProducerInstalled({ desktopPackageRoot }),
    verifyStagedKoffi,
    resolvePackagedResourcesDir: () => resourcesDir,
    targetPlatform: { os: "darwin", arch: "arm64" },
  });
  return { check: () => check({}), resourcesDir };
}

test("the open source Computer Use placeholder packages without a private Koffi runtime", async () => {
  const { check } = await fixture({ name: "@ccbuddy/ccbuddy-cua", ccbuddyCuaPlaceholder: true });
  assert.doesNotThrow(check);
});

test("an uninstalled Computer Use producer does not require a Koffi runtime", async () => {
  const { check } = await fixture();
  assert.doesNotThrow(check);
});

test("a real Computer Use producer still rejects a missing target Koffi binary", async () => {
  const { check } = await fixture({ name: "@ccbuddy/ccbuddy-cua" });
  assert.throws(check, /CUA plugin koffi runtime is incomplete.*\n- missing staged koffi runtime/s);
});

test("a real Computer Use producer requires both the target binary and JavaScript entry", async () => {
  const { check, resourcesDir } = await fixture({ name: "@ccbuddy/ccbuddy-cua" });
  const koffiRoot = resolve(
    resourcesDir,
    "glm",
    "packages",
    "ccbuddy-cua-plugin",
    "node_modules",
    "koffi",
  );
  const nativeDir = resolve(koffiRoot, "build", "koffi", "darwin_arm64");
  await mkdir(nativeDir, { recursive: true });
  await writeFile(resolve(nativeDir, "koffi.node"), "fixture native binary");
  assert.throws(check, /missing staged koffi runtime/);
  await writeFile(resolve(koffiRoot, "index.js"), "module.exports = {};");
  assert.doesNotThrow(check);
});
