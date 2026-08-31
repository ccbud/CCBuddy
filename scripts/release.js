#!/usr/bin/env node
'use strict';

/* Prepare one synchronized release commit and the tag that starts release.yml. */

const { spawnSync } = require('child_process');

const version = process.argv[2];
const noPush = process.argv.includes('--no-push');
const SEMVER_RE = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const XCODEGEN_VERSION = '2.46.0';

const requestedVersion = SEMVER_RE.exec(version || '');
if (!requestedVersion || BigInt(requestedVersion[1]) < 2n) {
  console.error('Usage: npm run release -- <x.y.z> [--no-push]   e.g. npm run release -- 2.0.1');
  process.exit(1);
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: process.cwd(),
    encoding: 'utf8',
    stdio: options.capture ? 'pipe' : 'inherit',
  });
  if (result.error) throw result.error;
  if (result.status !== 0 && !options.allowFailure) {
    throw new Error(`${command} ${args.join(' ')} failed with status ${result.status}`);
  }
  return options.capture ? (result.stdout || '').trim() : result.status;
}

const git = (args, options) => run('git', args, options);
const fail = (message) => { console.error(`✗ ${message}`); process.exit(1); };

function parseVersionTag(tag) {
  const match = /^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(tag);
  return match ? match.slice(1).map(BigInt) : null;
}

function compareVersionParts(left, right) {
  for (let index = 0; index < 3; index += 1) {
    if (left[index] < right[index]) return -1;
    if (left[index] > right[index]) return 1;
  }
  return 0;
}

// Guards: only release from a clean main, so stray edits never ride along into a release.
try {
  if (git(['branch', '--show-current'], { capture: true }) !== 'main') {
    fail('releases must run from the main branch');
  }
  if (git(['status', '--porcelain'], { capture: true })) {
    fail('working tree not clean — commit or stash first');
  }

  git(['fetch', '--prune', '--tags', 'origin']);
  const head = git(['rev-parse', 'HEAD'], { capture: true });
  const originMain = git(['rev-parse', '--verify', 'refs/remotes/origin/main'], { capture: true });
  if (head !== originMain) {
    fail('local main must exactly match origin/main before preparing a release');
  }

  const tag = `v${version}`;
  if (git(['show-ref', '--verify', '--quiet', `refs/tags/${tag}`], { allowFailure: true }) === 0) {
    fail(`${tag} already exists locally`);
  }
  const remoteTag = git(['ls-remote', '--tags', 'origin', `refs/tags/${tag}`], { capture: true });
  if (remoteTag) fail(`${tag} already exists on origin`);

  const exactTags = new Set(git(['tag', '--list'], { capture: true }).split(/\r?\n/));
  const remoteTags = git(['ls-remote', '--tags', '--refs', 'origin'], { capture: true });
  for (const line of remoteTags.split(/\r?\n/)) {
    const reference = line.split(/\s+/)[1] || '';
    if (reference.startsWith('refs/tags/')) exactTags.add(reference.slice('refs/tags/'.length));
  }
  exactTags.delete('');
  const targetParts = requestedVersion.slice(1).map(BigInt);
  const blockingTags = [...exactTags]
    .map((candidate) => ({ candidate, parts: parseVersionTag(candidate) }))
    .filter(({ parts }) => parts && compareVersionParts(targetParts, parts) <= 0)
    .sort((left, right) => compareVersionParts(left.parts, right.parts));
  if (blockingTags.length > 0) {
    fail(`${tag} must be greater than existing tag ${blockingTags[blockingTags.length - 1].candidate}`);
  }

  const xcodegenVersion = run('xcodegen', ['--version'], { capture: true });
  if (xcodegenVersion !== `Version: ${XCODEGEN_VERSION}`) {
    fail(`XcodeGen ${XCODEGEN_VERSION} is required (found ${xcodegenVersion || '<unknown>'})`);
  }

  run(process.execPath, ['scripts/release-version.js', 'set', version]);
  run('xcodegen', ['generate', '--spec', 'native/project.yml', '--project', 'native']);
  run(process.execPath, ['scripts/release-version.js', 'check', version]);

  git(['add',
    'package.json', 'package-lock.json',
    'src-tauri/tauri.conf.json', 'src-tauri/Cargo.toml', 'src-tauri/Cargo.lock',
    'native/project.yml', 'native/CCBuddy.xcodeproj',
  ]);
  if (git(['diff', '--cached', '--quiet'], { allowFailure: true }) !== 0) {
    git(['commit', '-m', `release: ${tag}`]);
  } else {
    console.log(`✓ all version sources already match ${version}; tagging the current commit`);
  }

  run('xcodegen', ['generate', '--spec', 'native/project.yml', '--project', 'native']);
  run(process.execPath, ['scripts/release-version.js', 'check', version]);
  if (git(['status', '--porcelain', '--', 'native/CCBuddy.xcodeproj'], { capture: true })) {
    fail('XcodeGen output changed after the release commit');
  }
  git(['tag', '-a', tag, '-m', `CC Buddy ${tag}`]);

  if (noPush) {
    console.log(`\n✓ prepared and tagged locally. Publish with: git push --atomic origin main ${tag}`);
  } else {
    git(['push', '--atomic', 'origin', 'main', tag]);
    console.log(`\n✓ pushed ${tag}; the tag-triggered release workflow is starting.`);
    console.log('  Watch: gh run list --workflow=release.yml --limit 1');
  }
} catch (error) {
  fail(error.message);
}
