#!/usr/bin/env node
'use strict';

// Publish an event-pinned version snapshot: never move main or rely on recursive token pushes.
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const ROOT = path.resolve(__dirname, '..');
const VERSION_RE = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const SHA_RE = /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/;
const VERSION_FILES = Object.freeze([
  'package.json', 'package-lock.json', 'src-tauri/tauri.conf.json',
  'src-tauri/Cargo.toml', 'src-tauri/Cargo.lock', 'native/project.yml',
  'native/CCBuddy.xcodeproj/project.pbxproj',
]);
const SOURCE_TRAILER = 'Release-Source-SHA';
const BOT_CONFIG = ['-c', 'user.name=github-actions[bot]', '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com'];
const packageField = /^(  "version": ")([^"]+)(",)$/gm;
const EDITORS = [
  [packageField], [packageField, /^(  "packages": \{\n    "": \{\n      "name": "[^"]+",\n      "version": ")([^"]+)(",)$/gm],
  [packageField], [/^(name = "app"\nversion = ")([^"]+)(")$/gm],
  [/^(\[\[package\]\]\nname = "app"\nversion = ")([^"]+)(")$/gm],
  [/^(    MARKETING_VERSION: ")([^"]+)(")$/gm],
];
function parts(version) {
  const match = VERSION_RE.exec(version || '');
  if (!match) throw new Error('Expected an exact x.y.z version');
  return match.slice(1).map(BigInt);
}
function compare(left, right) {
  for (let i = 0; i < 3; i += 1) if (left[i] !== right[i]) return left[i] > right[i] ? 1 : -1;
  return 0;
}
const exactTag = tag => typeof tag === 'string' && tag.startsWith('v') && VERSION_RE.test(tag.slice(1));
function selectVersion(packageVersion, tags) {
  const current = parts(packageVersion);
  let highest;
  for (const tag of tags.filter(exactTag)) {
    const value = parts(tag.slice(1));
    if (!highest || compare(value, highest) > 0) highest = value;
  }
  if (!highest) return packageVersion;
  const next = [highest[0], highest[1], highest[2] + 1n];
  return compare(current, next) >= 0 ? packageVersion : next.join('.');
}
function updateGeneratedProject(text, previous, next, expectedCount = 2) {
  parts(previous); parts(next);
  const matches = [...text.matchAll(/MARKETING_VERSION = ([^;]+);/g)];
  if (matches.length !== expectedCount || matches.some(match => match[1] !== previous)) {
    throw new Error(`Generated project must contain exactly ${expectedCount} matching MARKETING_VERSION fields`);
  }
  return text.replace(/MARKETING_VERSION = ([^;]+);/g, `MARKETING_VERSION = ${next};`);
}
function canonicalVersions(read, next) {
  const previous = JSON.parse(read('package.json')).version;
  if (parts(previous)[0] < 2n || parts(next)[0] < 2n) throw new Error('Native release major must be at least 2');
  return VERSION_FILES.map((file, index) => {
    let text = read(file);
    if (index === 6) return updateGeneratedProject(text, previous, next);
    for (const pattern of EDITORS[index]) {
      const matches = [...text.matchAll(pattern)];
      if (matches.length !== 1 || matches[0][2] !== previous) throw new Error(`Inconsistent version field: ${file}`);
      text = text.replace(pattern, (_, prefix, value, suffix) => `${prefix}${next}${suffix}`);
    }
    return text;
  });
}
function synchronizeVersion(cwd, version) {
  const updated = canonicalVersions(file => fs.readFileSync(path.join(cwd, file), 'utf8'), version);
  const releaseVersion = require(path.join(cwd, 'scripts/release-version.js'));
  releaseVersion.set(version);
  fs.writeFileSync(path.join(cwd, VERSION_FILES[6]), updated[6]);
  releaseVersion.check(version);
  VERSION_FILES.forEach((file, index) => {
    if (fs.readFileSync(path.join(cwd, file), 'utf8') !== updated[index]) throw new Error(`Noncanonical version update: ${file}`);
  });
}
function gitClient(cwd) {
  return (args, allowFailure = false, raw = false) => {
    const result = spawnSync('git', args, { cwd, encoding: 'utf8', stdio: 'pipe' });
    // Do not echo potentially credential-bearing git stderr, URLs, or environment values.
    if (result.error || (result.status !== 0 && !allowFailure)) throw new Error(`Git ${args[0]} failed (status ${result.status ?? 'unavailable'})`);
    return allowFailure ? result.status : raw ? result.stdout : result.stdout.trimEnd();
  };
}
function resolveReleaseSource(commit, { cwd = ROOT, expectedSource = process.env.RELEASE_SOURCE_SHA } = {}) {
  if (!SHA_RE.test(commit || '')) throw new Error('Expected a complete release commit SHA');
  const git = gitClient(cwd), read = (sha, file) => git(['show', `${sha}:${file}`], false, true);
  const version = JSON.parse(read(commit, 'package.json')).version;
  const unchanged = canonicalVersions(file => read(commit, file), version);
  VERSION_FILES.forEach((file, index) => {
    if (read(commit, file) !== unchanged[index]) throw new Error(`Inconsistent release version: ${file}`);
  });
  let source = commit;
  if (git(['merge-base', '--is-ancestor', commit, 'refs/remotes/origin/main'], true) !== 0) {
    const parents = git(['rev-list', '--parents', '-n', '1', commit]).split(' ');
    if (parents.length !== 2) throw new Error('Automatic snapshot must have exactly one source parent');
    source = parents[1];
    const expectedMessage = `release: v${version}\n\n${SOURCE_TRAILER}: ${source}`;
    if (git(['log', '-1', '--format=%B', commit]) !== expectedMessage) throw new Error('Invalid release source trailer');
    if (git(['merge-base', '--is-ancestor', source, 'refs/remotes/origin/main'], true) !== 0) throw new Error('Release source is not on origin/main');
    if (compare(parts(version), parts(JSON.parse(read(source, 'package.json')).version)) < 0) throw new Error('Snapshot version cannot decrease');
    const raw = git(['diff', '--raw', '--no-abbrev', '--no-renames', source, commit]);
    for (const line of raw.split('\n').filter(Boolean)) {
      const match = /^:(\d+) (\d+) [a-f0-9]+ [a-f0-9]+ M\t(.+)$/.exec(line);
      if (!match || match[1] !== match[2] || !VERSION_FILES.includes(match[3])) throw new Error('Snapshot contains an unexpected change');
    }
    const expected = canonicalVersions(file => read(source, file), version);
    VERSION_FILES.forEach((file, index) => {
      if (read(commit, file) !== expected[index]) throw new Error(`Noncanonical snapshot change: ${file}`);
    });
  }
  if (expectedSource != null && source !== expectedSource) throw new Error('Release source does not match RELEASE_SOURCE_SHA');
  return source;
}
function prepare({ cwd = ROOT, ref = process.env.GITHUB_REF, sourceSha = process.env.GITHUB_SHA,
  outputFile = process.env.GITHUB_OUTPUT } = {}) {
  const git = gitClient(cwd);
  const emit = (version, tag, commit, source = sourceSha) => {
    const result = { should_release: 'true', version, tag, commit, source_sha: source };
    if (outputFile) fs.appendFileSync(outputFile, Object.entries(result).map(([k, v]) => `${k}=${v}\n`).join(''));
    return result;
  };
  const clean = () => {
    if (git(['status', '--porcelain=v1', '--untracked-files=all'])) throw new Error('Working tree must be clean');
  };
  if (!SHA_RE.test(sourceSha || '') || git(['rev-parse', '--verify', 'HEAD']) !== sourceSha) throw new Error('Source SHA must exactly equal HEAD');
  clean();
  if (ref?.startsWith('refs/tags/')) {
    const tag = ref.slice('refs/tags/'.length);
    if (!exactTag(tag)) throw new Error('Expected an exact vX.Y.Z tag');
    if (git(['rev-parse', '--verify', `${ref}^{commit}`]) !== sourceSha) throw new Error('Tag must resolve to source SHA');
    return emit(tag.slice(1), tag, sourceSha, resolveReleaseSource(sourceSha, { cwd }));
  }
  if (ref !== 'refs/heads/main') throw new Error('Automatic releases require refs/heads/main');
  git(['fetch', '--no-recurse-submodules', '--prune', '--tags', 'origin', '+refs/heads/main:refs/remotes/origin/main']);
  if (git(['merge-base', '--is-ancestor', sourceSha, 'refs/remotes/origin/main'], true) !== 0) throw new Error('Event source is not on origin/main');
  const tags = git(['ls-remote', '--tags', '--refs', 'origin']).split('\n')
    .map(line => line.split(/\s+/)[1]?.replace(/^refs\/tags\//, '')).filter(exactTag);
  const sourceVersion = JSON.parse(fs.readFileSync(path.join(cwd, 'package.json'), 'utf8')).version;
  for (const tag of tags) {
    if (git(['cat-file', '-t', `refs/tags/${tag}`]) !== 'tag') continue;
    const commit = git(['rev-parse', `${tag}^{commit}`]);
    const message = git(['log', '-1', '--format=%B', commit]);
    if (commit === sourceSha && tag.slice(1) === sourceVersion) {
      resolveReleaseSource(commit, { cwd, expectedSource: sourceSha });
      return emit(tag.slice(1), tag, commit);
    }
    if (message !== `release: ${tag}\n\n${SOURCE_TRAILER}: ${sourceSha}`) continue;
    if (git(['for-each-ref', '--format=%(contents)', `refs/tags/${tag}`]) !== `CC Buddy ${tag}\n\n${SOURCE_TRAILER}: ${sourceSha}`) {
      throw new Error('Automatic tag is missing its source annotation');
    }
    resolveReleaseSource(commit, { cwd, expectedSource: sourceSha });
    return emit(tag.slice(1), tag, commit);
  }
  clean();
  const version = selectVersion(sourceVersion, tags), tag = `v${version}`;
  git(['checkout', '--detach', sourceSha]);
  synchronizeVersion(cwd, version);
  git(['add', '--', ...VERSION_FILES]);
  const staged = git(['diff', '--cached', '--name-only']).split('\n').filter(Boolean);
  if (staged.some(file => !VERSION_FILES.includes(file))) throw new Error('Unexpected staged release file');
  git([...BOT_CONFIG, '-c', 'commit.gpgSign=false', 'commit', '--allow-empty', '-m', `release: ${tag}`, '-m', `${SOURCE_TRAILER}: ${sourceSha}`]);
  clean();
  const commit = git(['rev-parse', 'HEAD']);
  resolveReleaseSource(commit, { cwd, expectedSource: sourceSha });
  git([...BOT_CONFIG, '-c', 'tag.gpgSign=false', 'tag', '-a', tag, '-m', `CC Buddy ${tag}`, '-m', `${SOURCE_TRAILER}: ${sourceSha}`]);
  git(['push', 'origin', `refs/tags/${tag}:refs/tags/${tag}`]);
  return emit(version, tag, commit);
}
if (require.main === module) {
  try {
    if (process.argv[2] === '--verify' && process.argv.length === 4) console.log(resolveReleaseSource(process.argv[3]));
    else if (process.argv.length === 2) prepare();
    else throw new Error('Usage: prepare-main-release.js [--verify <release-commit-sha>]');
  } catch (error) { console.error(`Release preparation failed: ${error.message}`); process.exitCode = 1; }
}
module.exports = { selectVersion, updateGeneratedProject, synchronizeVersion, resolveReleaseSource, prepare, VERSION_FILES };
