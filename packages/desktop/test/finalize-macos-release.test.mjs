import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import YAML from "yaml";
import { finalizeMacosRelease } from "../scripts/finalize-macos-release.mjs";

const version = "2.0.12";
const zipName = `CCbuddy-${version}-mac-arm64.zip`;
const dmgName = `CCbuddy-${version}-mac-arm64.dmg`;
const zipBytes = Buffer.from("signed, notarized ZIP");
const dmgBytes = Buffer.from("stapled DMG");
const hash = (bytes) => createHash("sha512").update(bytes).digest("base64");

async function withDist(run) {
  const distDir = await mkdtemp(join(tmpdir(), "ccbuddy-release-test-"));
  try {
    await Promise.all([
      writeFile(join(distDir, zipName), zipBytes),
      writeFile(join(distDir, dmgName), dmgBytes),
      writeFile(join(distDir, `${zipName}.blockmap`), "blockmap"),
      writeFile(
        join(distDir, "latest-mac.yml"),
        YAML.stringify({
          version,
          files: [
            { url: zipName, sha512: hash(zipBytes), size: zipBytes.length },
            { url: dmgName, sha512: "stale-after-staple", size: 1 },
          ],
          path: zipName,
          sha512: hash(zipBytes),
        }),
      ),
    ]);
    await run(distDir);
  } finally {
    await rm(distDir, { recursive: true, force: true });
  }
}

test("publishes only the unchanged, verified ZIP after DMG stapling", async () => {
  await withDist(async (distDir) => {
    await finalizeMacosRelease(distDir, version);
    const manifest = YAML.parse(await readFile(join(distDir, "latest-mac.yml"), "utf8"));
    assert.deepEqual(manifest.files, [
      { url: zipName, sha512: hash(zipBytes), size: zipBytes.length },
    ]);
    assert.equal(manifest.path, zipName);
  });
});

test("rejects a ZIP changed after electron-builder wrote the manifest", async () => {
  await withDist(async (distDir) => {
    await writeFile(join(distDir, zipName), "modified ZIP");
    await assert.rejects(finalizeMacosRelease(distDir, version), /does not match the signed ZIP/);
  });
});
