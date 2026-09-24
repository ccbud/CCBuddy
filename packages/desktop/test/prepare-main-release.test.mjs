import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { promisify } from "node:util";
import {
  VERSION_FILES,
  bumpVersionText,
  prepare,
  resolveReleaseSource,
  selectVersion,
} from "../scripts/prepare-main-release.mjs";

const execFileAsync = promisify(execFile);
// 隔离开发者的全局 git 配置（签名、钩子等），脚本内的 git 调用继承该环境。
process.env.GIT_CONFIG_GLOBAL = "/dev/null";
const GIT_ENV = {
  ...process.env,
  GIT_AUTHOR_NAME: "test",
  GIT_AUTHOR_EMAIL: "test@example.invalid",
  GIT_COMMITTER_NAME: "test",
  GIT_COMMITTER_EMAIL: "test@example.invalid",
  GIT_CONFIG_NOSYSTEM: "1",
  GIT_CONFIG_GLOBAL: "/dev/null",
};

async function git(cwd, ...args) {
  const { stdout } = await execFileAsync("git", args, { cwd, env: GIT_ENV });
  return stdout.trim();
}

const packageText = (version) =>
  `{\n  "name": "fixture",\n  "version": "${version}",\n  "private": true\n}\n`;

async function withRepo(packageVersion, tags, run) {
  const root = await mkdtemp(join(tmpdir(), "ccbuddy-main-release-"));
  const origin = join(root, "origin.git");
  const work = join(root, "work");
  try {
    await git(root, "init", "--bare", "--initial-branch=main", origin);
    await git(root, "clone", origin, work);
    await writeFile(join(work, "README.md"), "fixture\n");
    await git(work, "add", ".");
    await git(work, "commit", "-m", "base");
    for (const tag of tags) await git(work, "tag", "-a", tag, "-m", tag);
    for (const file of VERSION_FILES) {
      await mkdir(dirname(join(work, file)), { recursive: true });
      await writeFile(join(work, file), packageText(packageVersion));
    }
    await git(work, "add", ".");
    await git(work, "commit", "-m", "feature");
    await git(work, "push", "--follow-tags", "origin", "main");
    const sha = await git(work, "rev-parse", "HEAD");
    await run({ work, origin, sha, outputFile: join(root, "output") });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test("selectVersion keeps a newer package version and otherwise bumps the highest tag patch", () => {
  assert.equal(selectVersion("2.0.12", ["v2.0.9", "v2.0.10", "latest"]), "2.0.12");
  assert.equal(selectVersion("2.0.9", ["v2.0.9", "v2.0.10"]), "2.0.11");
  assert.equal(selectVersion("1.0.0", []), "1.0.0");
});

test("bumpVersionText changes only the single top-level version field", () => {
  assert.equal(bumpVersionText(packageText("2.0.9"), "2.0.9", "2.0.10"), packageText("2.0.10"));
  assert.throws(() => bumpVersionText(packageText("2.0.8"), "2.0.9", "2.0.10"));
});

test("a main push with an unreleased package version tags the main commit itself", async () => {
  await withRepo("2.0.12", ["v2.0.9"], async ({ work, origin, sha, outputFile }) => {
    const result = await prepare({ cwd: work, ref: "refs/heads/main", sha, outputFile });
    assert.deepEqual(result, { version: "2.0.12", tag: "v2.0.12", commit: sha, source_sha: sha });
    assert.equal(await git(origin, "rev-parse", "v2.0.12^{commit}"), sha);
    assert.equal(await git(origin, "cat-file", "-t", "v2.0.12"), "tag");
    assert.match(await readFile(outputFile, "utf8"), /^version=2\.0\.12$/m);

    // 重跑同一提交复用已有 tag，不再分配新版本。
    const rerun = await prepare({ cwd: work, ref: "refs/heads/main", sha });
    assert.equal(rerun.tag, "v2.0.12");
  });
});

test("a main push with an already released version publishes a bumped snapshot", async () => {
  await withRepo("2.0.9", ["v2.0.9"], async ({ work, origin, sha }) => {
    const result = await prepare({ cwd: work, ref: "refs/heads/main", sha });
    assert.equal(result.tag, "v2.0.10");
    assert.equal(result.source_sha, sha);
    assert.notEqual(result.commit, sha);
    assert.equal(await git(origin, "rev-parse", "v2.0.10^{commit}"), result.commit);
    assert.equal(await git(origin, "rev-parse", "main"), sha, "main must not move");
    for (const file of VERSION_FILES) {
      assert.equal(
        await git(work, "show", `${result.commit}:${file}`),
        packageText("2.0.10").trim(),
      );
    }
    assert.equal(await resolveReleaseSource(result.commit, "2.0.10", { cwd: work }), sha);

    await git(work, "checkout", "--detach", sha);
    const rerun = await prepare({ cwd: work, ref: "refs/heads/main", sha });
    assert.deepEqual(rerun, result);
  });
});

test("a snapshot with changes beyond the version fields is rejected", async () => {
  await withRepo("2.0.9", ["v2.0.9"], async ({ work, sha }) => {
    await git(work, "checkout", "--detach", sha);
    for (const file of VERSION_FILES) await writeFile(join(work, file), packageText("2.0.10"));
    await writeFile(join(work, "README.md"), "tampered\n");
    await git(work, "add", ".");
    await git(work, "commit", "-m", "release: v2.0.10", "-m", `Release-Source-SHA: ${sha}`);
    const commit = await git(work, "rev-parse", "HEAD");
    await git(work, "fetch", "origin", "+refs/heads/main:refs/remotes/origin/main");
    await assert.rejects(
      resolveReleaseSource(commit, "2.0.10", { cwd: work }),
      /unexpected change/,
    );
  });
});

test("a tag push must be annotated and match the package versions", async () => {
  await withRepo("2.0.12", ["v2.0.9"], async ({ work, sha }) => {
    await git(work, "tag", "-a", "v2.0.13", "-m", "wrong version");
    await assert.rejects(
      prepare({ cwd: work, ref: "refs/tags/v2.0.13", sha }),
      /expected 2\.0\.13, found 2\.0\.12/,
    );
    await git(work, "tag", "v2.0.12");
    await assert.rejects(prepare({ cwd: work, ref: "refs/tags/v2.0.12", sha }), /annotated/);
  });
});
