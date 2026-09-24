#!/usr/bin/env node

// 修复原因：#53 重建 release.yml 时只保留了 tag 触发，main 推送不再自动打包发布，
// 旧版用户因此收不到新版本。这里恢复“每次 main 推送都分配一个版本并打 tag”的流程：
// - 根 package.json 版本高于已有最高 tag 时，直接给 main 提交打该版本 tag；
// - 否则在 main 提交之上生成只改版本字段的快照提交（不推送 main），版本为最高 tag 的 patch + 1；
// - 同一 main 提交重跑时复用已分配的 tag，保证幂等。
import { execFile } from "node:child_process";
import { appendFile, readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const workspaceDir = resolve(import.meta.dirname, "../../..");

export const VERSION_FILES = Object.freeze([
  "package.json",
  "apps/ccbuddy-cli/package.json",
  "apps/ccbuddy-cli/packages/cli/package.json",
]);
const MAIN_REF = "refs/remotes/origin/main";
const SOURCE_TRAILER = "Release-Source-SHA";
const VERSION_RE = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const SHA_RE = /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/;
const VERSION_FIELD_RE = /^(  "version": ")([^"]+)(",)$/gm;
const BOT_CONFIG = [
  "-c",
  "user.name=github-actions[bot]",
  "-c",
  "user.email=41898282+github-actions[bot]@users.noreply.github.com",
];

function parts(version) {
  const match = VERSION_RE.exec(version ?? "");
  if (!match) throw new Error(`Expected an exact x.y.z version, found ${version}`);
  return match.slice(1).map(BigInt);
}

function compareVersions(left, right) {
  const a = parts(left);
  const b = parts(right);
  for (let i = 0; i < 3; i += 1) if (a[i] !== b[i]) return a[i] > b[i] ? 1 : -1;
  return 0;
}

const isReleaseTag = (tag) =>
  typeof tag === "string" && tag.startsWith("v") && VERSION_RE.test(tag.slice(1));

export function selectVersion(packageVersion, tags) {
  const released = tags.filter(isReleaseTag).map((tag) => tag.slice(1));
  if (released.length === 0) return packageVersion;
  const highest = released.reduce((max, v) => (compareVersions(v, max) > 0 ? v : max));
  if (compareVersions(packageVersion, highest) > 0) return packageVersion;
  const [major, minor, patch] = parts(highest);
  return `${major}.${minor}.${patch + 1n}`;
}

export function bumpVersionText(text, previous, next) {
  parts(previous);
  parts(next);
  const matches = [...text.matchAll(VERSION_FIELD_RE)];
  if (matches.length !== 1 || matches[0][2] !== previous) {
    throw new Error(`Expected exactly one top-level "version": "${previous}" field`);
  }
  return text.replace(VERSION_FIELD_RE, (_, prefix, _value, suffix) => `${prefix}${next}${suffix}`);
}

const snapshotMessage = (version, source) =>
  `release: v${version}\n\n${SOURCE_TRAILER}: ${source}`;

function gitClient(cwd) {
  return async (args, { allowFailure = false } = {}) => {
    try {
      const { stdout } = await execFileAsync("git", args, {
        cwd,
        encoding: "utf8",
        maxBuffer: 64 * 1024 * 1024,
      });
      return allowFailure ? 0 : stdout.replace(/\n$/, "");
    } catch (error) {
      // 不回显 git stderr，避免把带凭据的远端地址写进日志。
      if (allowFailure && typeof error.code === "number") return error.code;
      throw new Error(`git ${args[0]} failed (status ${error.code ?? "unavailable"})`);
    }
  };
}

async function readVersionAt(git, commit, file) {
  return JSON.parse(await git(["show", `${commit}:${file}`])).version;
}

/**
 * Accepts a release commit that is on origin/main, or a snapshot whose single parent is on
 * origin/main and whose only change is the version field of VERSION_FILES. Returns the main source.
 */
export async function resolveReleaseSource(commit, version, { cwd = workspaceDir } = {}) {
  if (!SHA_RE.test(commit ?? "")) throw new Error("Expected a complete release commit SHA");
  parts(version);
  const git = gitClient(cwd);
  for (const file of VERSION_FILES) {
    const actual = await readVersionAt(git, commit, file);
    if (actual !== version) throw new Error(`${file}: expected ${version}, found ${actual}`);
  }
  if (
    (await git(["merge-base", "--is-ancestor", commit, MAIN_REF], { allowFailure: true })) === 0
  ) {
    return commit;
  }
  const parents = (await git(["rev-list", "--parents", "-n", "1", commit])).split(" ");
  if (parents.length !== 2) throw new Error("Release snapshot must have exactly one parent");
  const source = parents[1];
  if (
    (await git(["merge-base", "--is-ancestor", source, MAIN_REF], { allowFailure: true })) !== 0
  ) {
    throw new Error("Release source is not on origin/main");
  }
  if (
    (await git(["log", "-1", "--format=%B", commit])).trim() !== snapshotMessage(version, source)
  ) {
    throw new Error("Release snapshot has an invalid source trailer");
  }
  const previous = await readVersionAt(git, source, "package.json");
  if (compareVersions(version, previous) <= 0)
    throw new Error("Release snapshot must increase the version");
  const raw = await git(["diff", "--raw", "--no-abbrev", "--no-renames", source, commit]);
  for (const line of raw.split("\n").filter(Boolean)) {
    const match = /^:(\d+) (\d+) [a-f0-9]+ [a-f0-9]+ M\t(.+)$/.exec(line);
    if (!match || match[1] !== match[2] || !VERSION_FILES.includes(match[3])) {
      throw new Error("Release snapshot contains an unexpected change");
    }
  }
  for (const file of VERSION_FILES) {
    const expected = bumpVersionText(await git(["show", `${source}:${file}`]), previous, version);
    if ((await git(["show", `${commit}:${file}`])) !== expected.replace(/\n$/, "")) {
      throw new Error(`Noncanonical release snapshot change: ${file}`);
    }
  }
  return source;
}

async function writeOutputs(outputFile, result) {
  if (!outputFile) return;
  await appendFile(
    outputFile,
    Object.entries(result)
      .map(([key, value]) => `${key}=${value}\n`)
      .join(""),
  );
}

export async function prepare({
  cwd = workspaceDir,
  ref = process.env.GITHUB_REF,
  sha = process.env.GITHUB_SHA,
  outputFile = process.env.GITHUB_OUTPUT,
} = {}) {
  const git = gitClient(cwd);
  if (!SHA_RE.test(sha ?? "") || (await git(["rev-parse", "--verify", "HEAD"])) !== sha) {
    throw new Error("Event SHA must equal the checked-out HEAD");
  }
  if (await git(["status", "--porcelain=v1", "--untracked-files=all"]))
    throw new Error("Working tree must be clean");
  await git([
    "fetch",
    "--force",
    "--no-recurse-submodules",
    "--tags",
    "origin",
    `+refs/heads/main:${MAIN_REF}`,
  ]);

  const emit = async (tag, commit, source) => {
    const result = { version: tag.slice(1), tag, commit, source_sha: source };
    await writeOutputs(outputFile, result);
    return result;
  };

  if (ref?.startsWith("refs/tags/")) {
    const tag = ref.slice("refs/tags/".length);
    if (!isReleaseTag(tag)) throw new Error("Expected an exact vX.Y.Z tag");
    if ((await git(["cat-file", "-t", `refs/tags/${tag}`])) !== "tag")
      throw new Error("Release tags must be annotated");
    const commit = await git(["rev-parse", `refs/tags/${tag}^{commit}`]);
    return emit(tag, commit, await resolveReleaseSource(commit, tag.slice(1), { cwd }));
  }
  if (ref !== "refs/heads/main") throw new Error("Automatic releases require refs/heads/main");
  if ((await git(["merge-base", "--is-ancestor", sha, MAIN_REF], { allowFailure: true })) !== 0) {
    throw new Error("Event SHA is not on origin/main");
  }

  const tags = (await git(["tag", "--list", "v*"])).split("\n").filter(isReleaseTag);
  // 重跑同一 main 提交时复用已分配的版本，不重复占号。
  for (const tag of tags) {
    if ((await git(["cat-file", "-t", `refs/tags/${tag}`])) !== "tag") continue;
    const commit = await git(["rev-parse", `refs/tags/${tag}^{commit}`]);
    const isSnapshotOfSha =
      commit !== sha &&
      (await git(["log", "-1", "--format=%B", commit])).trim() ===
        snapshotMessage(tag.slice(1), sha);
    if (commit === sha || isSnapshotOfSha) {
      const source = await resolveReleaseSource(commit, tag.slice(1), { cwd });
      if (source !== sha) throw new Error(`${tag} does not belong to ${sha}`);
      return emit(tag, commit, sha);
    }
  }

  const packageVersion = JSON.parse(await readFile(join(cwd, "package.json"), "utf8")).version;
  const version = selectVersion(packageVersion, tags);
  const tag = `v${version}`;
  let commit = sha;
  if (version !== packageVersion) {
    await git(["checkout", "--detach", sha]);
    for (const file of VERSION_FILES) {
      const path = join(cwd, file);
      await writeFile(path, bumpVersionText(await readFile(path, "utf8"), packageVersion, version));
    }
    await git(["add", "--", ...VERSION_FILES]);
    await git([
      ...BOT_CONFIG,
      "-c",
      "commit.gpgSign=false",
      "commit",
      "-m",
      `release: ${tag}`,
      "-m",
      `${SOURCE_TRAILER}: ${sha}`,
    ]);
    commit = await git(["rev-parse", "HEAD"]);
  }
  if ((await resolveReleaseSource(commit, version, { cwd })) !== sha)
    throw new Error("Release source mismatch");
  await git([
    ...BOT_CONFIG,
    "-c",
    "tag.gpgSign=false",
    "tag",
    "-a",
    tag,
    commit,
    "-m",
    `CCbuddy ${tag}`,
    "-m",
    `${SOURCE_TRAILER}: ${sha}`,
  ]);
  // GITHUB_TOKEN 推送的 tag 不会再次触发工作流，发布在本次运行内完成。
  await git(["push", "origin", `refs/tags/${tag}:refs/tags/${tag}`]);
  return emit(tag, commit, sha);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [mode, commit, version] = process.argv.slice(2);
  const run =
    mode === "--verify" && commit && version
      ? resolveReleaseSource(commit, version).then((source) => console.log(source))
      : mode === undefined
        ? prepare()
        : Promise.reject(
            new Error("Usage: prepare-main-release.mjs [--verify <commit> <version>]"),
          );
  run.catch((error) => {
    console.error(`Release preparation failed: ${error.message}`);
    process.exitCode = 1;
  });
}
