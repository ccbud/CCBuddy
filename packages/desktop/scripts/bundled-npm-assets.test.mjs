import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync, existsSync } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  stageBundledNpm,
  bundledNpmTarballUrl,
  BUNDLED_NPM_VERSION,
} from "./bundled-npm-assets.mjs";

test("stages verified npm without docs and reuses the integrity-checked cache", async () => {
  const root = await mkdtemp(join(tmpdir(), "ccbuddy-npm-staging-"));
  const bytes = Buffer.from("fixture tarball");
  const integrity = `sha512-${createHash("sha512").update(bytes).digest("base64")}`;
  let downloads = 0;
  const download = async (url, target) => {
    assert.equal(url, bundledNpmTarballUrl(BUNDLED_NPM_VERSION));
    downloads++;
    await writeFile(target, bytes);
  };
  const extract = ({ extractDir }) => {
    const packageRoot = join(extractDir, "package");
    mkdirSync(join(packageRoot, "bin"), { recursive: true });
    mkdirSync(join(packageRoot, "docs"), { recursive: true });
    writeFileSync(join(packageRoot, "bin", "npm-cli.js"), "npm");
    writeFileSync(join(packageRoot, "bin", "npx-cli.js"), "npx");
    writeFileSync(join(packageRoot, "docs", "help.txt"), "help");
  };
  try {
    const options = {
      cacheDir: join(root, "cache"),
      glmDir: join(root, "glm"),
      integrity,
      download,
      extract,
    };
    const staged = await stageBundledNpm(options);
    assert.equal(await readFile(join(staged, "bin", "npm-cli.js"), "utf8"), "npm");
    assert.equal(existsSync(join(staged, "docs")), false);
    await stageBundledNpm(options);
    assert.equal(downloads, 1);
    await assert.rejects(
      stageBundledNpm({
        cacheDir: join(root, "cache"),
        glmDir: join(root, "glm"),
        integrity,
        download,
        extract: () => {},
      }),
      /missing npm entry/,
    );
    assert.equal(downloads, 1);
    await writeFile(join(root, "cache", `npm-${BUNDLED_NPM_VERSION}.tgz`), "corrupt");
    await assert.rejects(
      stageBundledNpm({
        cacheDir: join(root, "cache"),
        glmDir: join(root, "glm"),
        integrity,
        download: async (_url, path) => writeFile(path, "bad"),
        extract,
      }),
      /sha512 mismatch/,
    );
    assert.equal(
      await readFile(join(root, "cache", `npm-${BUNDLED_NPM_VERSION}.tgz`), "utf8"),
      "corrupt",
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
