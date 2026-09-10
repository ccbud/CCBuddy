'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { selectVersion, updateGeneratedProject, synchronizeVersion, resolveReleaseSource, prepare, VERSION_FILES } = require('../scripts/prepare-main-release');
const ROOT = path.resolve(__dirname, '..');
function git(cwd, ...args) {
  const result = spawnSync('git', args, { cwd, encoding: 'utf8', env: { ...process.env,
    GIT_AUTHOR_NAME: 'Fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid',
    GIT_COMMITTER_NAME: 'Fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid' } });
  assert.equal(result.status, 0, `git ${args[0]}: ${result.stderr}`);
  return result.stdout.trim();
}
function fixture(run) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ccbuddy-release-test-'));
  const cwd = path.join(temporary, 'checkout'), origin = path.join(temporary, 'origin.git');
  fs.mkdirSync(cwd); git(temporary, 'init', '--bare', origin); git(cwd, 'init', '-b', 'main');
  git(cwd, 'config', 'user.name', 'Fixture'); git(cwd, 'config', 'user.email', 'fixture@example.invalid');
  git(cwd, 'config', 'commit.gpgSign', 'false'); git(cwd, 'config', 'tag.gpgSign', 'false');
  for (const file of [...VERSION_FILES, 'scripts/release-version.js', 'scripts/prepare-main-release.js']) {
    fs.mkdirSync(path.dirname(path.join(cwd, file)), { recursive: true });
    fs.copyFileSync(path.join(ROOT, file), path.join(cwd, file));
  }
  synchronizeVersion(cwd, '2.0.5'); git(cwd, 'add', '.'); git(cwd, 'commit', '-m', 'Baseline');
  git(cwd, 'commit', '--allow-empty', '-m', 'Source change');
  git(cwd, 'remote', 'add', 'origin', origin); git(cwd, 'push', 'origin', 'main');
  const sourceSha = git(cwd, 'rev-parse', 'HEAD'), outputFile = path.join(temporary, 'output');
  const options = { cwd, ref: 'refs/heads/main', sourceSha, outputFile };
  const remote = (...args) => git(temporary, '--git-dir', origin, ...args);
  try { return run({ cwd, origin, temporary, sourceSha, outputFile, options, remote }); }
  finally { fs.rmSync(temporary, { recursive: true, force: true }); }
}
function priorTag(cwd) {
  git(cwd, 'tag', '-a', 'v2.0.5', 'HEAD^', '-m', 'Prior release'); git(cwd, 'push', 'origin', 'v2.0.5');
}
test('version selection is exact, numeric, arbitrary precision and never below package', () => {
  assert.equal(selectVersion('2.0.5', []), '2.0.5');
  assert.equal(selectVersion('2.0.6', ['v2.0.5', 'v2.0.6-beta.1', 'v02.0.9', 'other']), '2.0.6');
  assert.equal(selectVersion('2.1.0', ['v2.0.99', 'v1.99.99']), '2.1.0');
  assert.equal(selectVersion('2.0.5', ['v2.9.0', 'v2.10.8']), '2.10.9');
  assert.equal(selectVersion('2.0.5', ['v2.0.9007199254740999']), '2.0.9007199254741000');
  assert.throws(() => selectVersion('2.0.5-beta', []));
});
test('generated replacement requires exactly two identical original fields', () => {
  const text = 'MARKETING_VERSION = 2.0.5;\nMARKETING_VERSION = 2.0.5;\n';
  assert.equal(updateGeneratedProject(text, '2.0.5', '2.0.6'), text.replaceAll('2.0.5', '2.0.6'));
  assert.throws(() => updateGeneratedProject(text + text, '2.0.5', '2.0.6'));
  assert.throws(() => updateGeneratedProject(text.replace('2.0.5', '2.0.4'), '2.0.5', '2.0.6'));
});
test('snapshot synchronizes exactly seven files and pushes annotated tag without moving main', () => fixture(f => {
  priorTag(f.cwd); const result = prepare(f.options);
  assert.equal(result.version, '2.0.6'); assert.equal(result.should_release, 'true');
  assert.equal(result.source_sha, f.sourceSha); assert.notEqual(result.commit, f.sourceSha);
  assert.equal(f.remote('rev-parse', 'main'), f.sourceSha);
  assert.equal(f.remote('rev-parse', 'v2.0.6^{commit}'), result.commit);
  assert.equal(f.remote('cat-file', '-t', 'v2.0.6'), 'tag');
  assert.equal(f.remote('for-each-ref', '--format=%(taggername)', 'refs/tags/v2.0.6'), 'github-actions[bot]');
  assert.match(f.remote('for-each-ref', '--format=%(contents)', 'refs/tags/v2.0.6'), new RegExp(`Release-Source-SHA: ${f.sourceSha}$`));
  assert.equal(git(f.cwd, 'branch', '--show-current'), '');
  assert.deepEqual(f.remote('rev-list', '--parents', '-n', '1', result.commit).split(' '), [result.commit, f.sourceSha]);
  assert.equal(f.remote('log', '-1', '--format=%an', result.commit), 'github-actions[bot]');
  assert.deepEqual(f.remote('diff-tree', '--no-commit-id', '--name-only', '-r', result.commit).split('\n').sort(), [...VERSION_FILES].sort());
  assert.equal(require(path.join(f.cwd, 'scripts/release-version')).check('2.0.6'), '2.0.6');
  assert.equal(resolveReleaseSource(result.commit, { cwd: f.cwd, expectedSource: f.sourceSha }), f.sourceSha);
  assert.equal(git(f.cwd, 'status', '--porcelain'), '');
  assert.match(fs.readFileSync(f.outputFile, 'utf8'), new RegExp(`commit=${result.commit}\nsource_sha=${f.sourceSha}\n`));
}));
test('no-tag bootstrap retains package version and creates an auditable snapshot', () => fixture(f => {
  const result = prepare(f.options);
  assert.equal(result.version, '2.0.5'); assert.notEqual(result.commit, f.sourceSha);
  assert.equal(f.remote('rev-parse', 'main'), f.sourceSha);
  assert.equal(f.remote('rev-parse', 'v2.0.5^{}'), result.commit);
}));
test('old ancestor events release their own content without changing advanced main', () => fixture(f => {
  priorTag(f.cwd);
  git(f.cwd, 'commit', '--allow-empty', '-m', 'Newer source'); git(f.cwd, 'push', 'origin', 'main');
  const newer = git(f.cwd, 'rev-parse', 'HEAD'); git(f.cwd, 'checkout', '--detach', f.sourceSha);
  const result = prepare(f.options);
  assert.equal(result.should_release, 'true'); assert.equal(result.source_sha, f.sourceSha);
  assert.equal(f.remote('rev-parse', 'main'), newer);
  assert.equal(f.remote('rev-parse', `${result.tag}^`), f.sourceSha);
}));
test('tag rejection cannot move main or create a remote tag and emits no success', () => fixture(f => {
  priorTag(f.cwd); const hook = path.join(f.origin, 'hooks/pre-receive');
  fs.writeFileSync(hook, '#!/bin/sh\nexit 1\n'); fs.chmodSync(hook, 0o755);
  assert.throws(() => prepare(f.options), /Git push failed/);
  assert.equal(f.remote('rev-parse', 'main'), f.sourceSha); assert.equal(f.remote('tag', '--list'), 'v2.0.5');
  assert.equal(fs.existsSync(f.outputFile), false);
}));
test('rerunning original source reuses annotated snapshot even after main advances', () => fixture(f => {
  priorTag(f.cwd); const first = prepare(f.options);
  git(f.cwd, 'checkout', 'main'); git(f.cwd, 'commit', '--allow-empty', '-m', 'Later source');
  git(f.cwd, 'push', 'origin', 'main'); const newer = f.remote('rev-parse', 'main');
  git(f.cwd, 'checkout', '--detach', f.sourceSha);
  assert.deepEqual(prepare(f.options), first);
  assert.equal(f.remote('rev-parse', 'main'), newer);
  assert.equal(f.remote('tag', '--list'), 'v2.0.5\nv2.0.6');
}));
test('a manually tagged main source is reused, preventing dual-event version increments', () => fixture(f => {
  git(f.cwd, 'tag', '-a', 'v2.0.5', '-m', 'CC Buddy v2.0.5'); git(f.cwd, 'push', 'origin', 'v2.0.5');
  const result = prepare(f.options);
  assert.equal(result.commit, f.sourceSha); assert.equal(result.version, '2.0.5');
  assert.equal(f.remote('tag', '--list'), 'v2.0.5');
  assert.equal(resolveReleaseSource(f.sourceSha, { cwd: f.cwd }), f.sourceSha);
}));
test('tag path is read-only, resolves original source, and rejects invalid tags or source', () => fixture(f => {
  const first = prepare(f.options);
  const result = prepare({ ...f.options, sourceSha: first.commit, ref: 'refs/tags/v2.0.5' });
  assert.deepEqual(result, first); assert.equal(git(f.cwd, 'status', '--porcelain'), '');
  assert.throws(() => prepare({ ...f.options, sourceSha: first.commit, ref: 'refs/tags/v2.0.5-rc.1' }), /exact/);
  assert.throws(() => prepare({ ...f.options, sourceSha: '0'.repeat(40) }), /exactly equal HEAD/);
  assert.throws(() => prepare({ ...f.options, sourceSha: first.commit, ref: 'refs/heads/topic' }), /refs\/heads\/main/);
}));
test('dirty and pre-staged unrelated changes cannot enter a release', () => fixture(f => {
  fs.writeFileSync(path.join(f.cwd, 'unrelated.txt'), 'Do not publish');
  assert.throws(() => prepare(f.options), /clean/);
  git(f.cwd, 'add', 'unrelated.txt'); assert.throws(() => prepare(f.options), /clean/);
  assert.equal(f.remote('rev-parse', 'main'), f.sourceSha); assert.equal(f.remote('tag', '--list'), '');
}));
test('non-main-ancestor source is rejected without publishing', () => fixture(f => {
  git(f.cwd, 'checkout', '--detach'); git(f.cwd, 'commit', '--allow-empty', '-m', 'Unpublished branch');
  const branch = git(f.cwd, 'rev-parse', 'HEAD');
  assert.throws(() => prepare({ ...f.options, sourceSha: branch }), /not on origin\/main/);
  assert.equal(f.remote('tag', '--list'), '');
}));
test('verification rejects changed payload, modes, unrelated paths, trailers and expected source', () => fixture(f => {
  priorTag(f.cwd); const result = prepare(f.options);
  assert.throws(() => resolveReleaseSource(result.commit, { cwd: f.cwd, expectedSource: '0'.repeat(40) }), /RELEASE_SOURCE_SHA/);
  for (const mutate of [
    () => fs.appendFileSync(path.join(f.cwd, 'package.json'), '\n'),
    () => fs.chmodSync(path.join(f.cwd, 'package.json'), 0o755),
    () => fs.writeFileSync(path.join(f.cwd, 'other.txt'), 'unexpected'),
  ]) {
    git(f.cwd, 'checkout', '--detach', result.commit); mutate(); git(f.cwd, 'add', '.');
    git(f.cwd, 'commit', '--amend', '--no-edit');
    assert.throws(() => resolveReleaseSource(git(f.cwd, 'rev-parse', 'HEAD'), { cwd: f.cwd }), /unexpected|Noncanonical/);
  }
  git(f.cwd, 'checkout', '--detach', result.commit); git(f.cwd, 'commit', '--amend', '-m', 'Wrong trailer');
  assert.throws(() => resolveReleaseSource(git(f.cwd, 'rev-parse', 'HEAD'), { cwd: f.cwd }), /trailer/);
}));
test('verify CLI prints only the source SHA and binds RELEASE_SOURCE_SHA', () => fixture(f => {
  const result = prepare(f.options);
  const invoke = expected => spawnSync(process.execPath, ['scripts/prepare-main-release.js', '--verify', result.commit], {
    cwd: f.cwd, encoding: 'utf8', env: { ...process.env, RELEASE_SOURCE_SHA: expected },
  });
  const ok = invoke(f.sourceSha); assert.equal(ok.status, 0, ok.stderr); assert.equal(ok.stdout, f.sourceSha + '\n');
  const wrong = invoke('0'.repeat(40)); assert.notEqual(wrong.status, 0); assert.equal(wrong.stdout, '');
  const previous = process.env.RELEASE_SOURCE_SHA;
  try {
    process.env.RELEASE_SOURCE_SHA = '0'.repeat(40);
    assert.equal(resolveReleaseSource(result.commit, { cwd: f.cwd, expectedSource: null }), f.sourceSha);
  } finally { if (previous === undefined) delete process.env.RELEASE_SOURCE_SHA; else process.env.RELEASE_SOURCE_SHA = previous; }
}));
test('bot identity does not depend on a configured checkout identity', () => fixture(f => {
  git(f.cwd, 'config', 'user.name', ''); git(f.cwd, 'config', 'user.email', '');
  const result = prepare(f.options);
  assert.equal(f.remote('log', '-1', '--format=%an', result.commit), 'github-actions[bot]');
  assert.equal(f.remote('for-each-ref', '--format=%(taggername)', `refs/tags/${result.tag}`), 'github-actions[bot]');
}));
