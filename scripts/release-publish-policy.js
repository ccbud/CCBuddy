#!/usr/bin/env node
'use strict';

// Queued main pushes may start out of order. All produce a Release, but an old
// source snapshot must never take over the updater or Homebrew channel.
const fs = require('fs');
const { execFileSync, spawnSync } = require('child_process');
const { resolveReleaseSource } = require('./prepare-main-release');

function versionParts(tag) {
  const match = /^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(tag || '');
  if (!match) throw new Error(`not an exact release tag: ${tag}`);
  return match.slice(1).map(BigInt);
}

function compareVersions(left, right) {
  const a = versionParts(left), b = versionParts(right);
  for (let i = 0; i < 3; i++) {
    if (a[i] !== b[i]) return a[i] > b[i] ? 1 : -1;
  }
  return 0;
}

function channelPolicy(tag, previousTag, previousSourceIsAncestor) {
  versionParts(tag);
  if (!previousTag) return { latest: true, reason: 'first public release' };
  if (compareVersions(tag, previousTag) <= 0) {
    return { latest: false, reason: 'never lower or reuse the updater version' };
  }
  if (!previousSourceIsAncestor) {
    return { latest: false, reason: 'older or diverged source must not roll back the update channel' };
  }
  return { latest: true, reason: 'newer version includes the current public source history' };
}

function main() {
  const { TAG: tag, GITHUB_REPOSITORY: repository, GITHUB_OUTPUT: output } = process.env;
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository || '') || !output) throw new Error('missing release context');
  versionParts(tag);
  const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();
  git('fetch', '--no-tags', 'origin', '+refs/heads/main:refs/remotes/origin/main');
  const currentSource = resolveReleaseSource(git('rev-parse', `refs/tags/${tag}^{commit}`));
  const response = spawnSync('gh', ['api', `repos/${repository}/releases/latest`], { encoding: 'utf8' });
  let previousTag = null, ancestor = true;
  if (response.status === 0) {
    previousTag = JSON.parse(response.stdout).tag_name;
    versionParts(previousTag);
    git('fetch', '--no-tags', 'origin', `refs/tags/${previousTag}:refs/tags/${previousTag}`);
    const previousSource = resolveReleaseSource(
      git('rev-parse', `refs/tags/${previousTag}^{commit}`), { expectedSource: null }
    );
    const relation = spawnSync('git', ['merge-base', '--is-ancestor', previousSource, currentSource]);
    if (![0, 1].includes(relation.status)) throw new Error('could not compare release source histories');
    ancestor = relation.status === 0;
  } else if (!/HTTP 404/.test(response.stderr || '')) {
    throw new Error('could not read the current public release; refusing to change the update channel');
  }
  const decision = channelPolicy(tag, previousTag, ancestor);
  fs.appendFileSync(output, `is_latest=${decision.latest}\n`);
  console.log(`${tag}: latest=${decision.latest}; ${decision.reason}`);
}

if (require.main === module) {
  try { main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
module.exports = { compareVersions, channelPolicy };
