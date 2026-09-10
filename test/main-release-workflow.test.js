'use strict';
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');
const workflow = fs.readFileSync(path.join(__dirname, '../.github/workflows/release.yml'), 'utf8');

test('every main push triggers release without a path filter', () => {
  assert.match(workflow, /on:\n  push:\n    branches:\n      - main\n    tags:/);
  assert.ok(!workflow.includes('paths-ignore:'));
});
test('release queue keeps pending pushes and the active release', () => {
  assert.match(workflow, /concurrency:[\s\S]*?group: native-release\n  cancel-in-progress: false\n  queue: max/);
});
test('main release continues in the same workflow without waiting for a token-pushed tag event', () => {
  assert.ok(workflow.includes('run: node scripts/prepare-main-release.js'));
  assert.ok(workflow.includes("if: needs.prepare.outputs.should_release == 'true'"));
  assert.ok(workflow.includes('needs: prepare'));
});
test('all consumers use immutable prepared commit and tag', () => {
  assert.equal((workflow.match(/ref: \$\{\{ needs\.verify\.outputs\.commit \}\}/g) || []).length, 4);
  assert.ok(workflow.includes('ref: ${{ needs.prepare.outputs.commit }}'));
  assert.equal((workflow.match(/TAG: \$\{\{ needs\.verify\.outputs\.tag \}\}/g) || []).length, 2);
  assert.ok(!workflow.includes('TAG: ${{ github.ref_name }}'));
});
test('version-only snapshots have an independent provenance gate', () => {
  assert.ok(workflow.includes('run: node scripts/prepare-main-release.js --verify "$RELEASE_COMMIT"'));
  assert.ok(workflow.includes('RELEASE_SOURCE_SHA: ${{ needs.prepare.outputs.source_sha }}'));
});
test('late old sources cannot regress the updater or Homebrew', () => {
  assert.ok(workflow.includes('run: node scripts/release-publish-policy.js'));
  assert.ok(workflow.includes('--draft=false --latest="$IS_LATEST"'));
  assert.ok(workflow.includes("if: needs.publish.outputs.is_latest == 'true'"));
});
