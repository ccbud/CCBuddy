'use strict';
const assert = require('node:assert/strict');
const test = require('node:test');
const { compareVersions, channelPolicy } = require('../scripts/release-publish-policy');

test('first release owns the channel', () => {
  assert.equal(channelPolicy('v2.0.6', null, true).latest, true);
});
test('new version from newer source advances the channel', () => {
  assert.equal(channelPolicy('v2.0.6', 'v2.0.5', true).latest, true);
});
test('late older source still publishes without reverting the update channel', () => {
  assert.equal(channelPolicy('v2.0.7', 'v2.0.6', false).latest, false);
});
test('manual old or same version cannot take over latest even on newer source', () => {
  assert.equal(channelPolicy('v2.0.5', 'v2.0.6', true).latest, false);
  assert.equal(channelPolicy('v2.0.6', 'v2.0.6', true).latest, false);
});
test('version ordering is numeric and does not overflow', () => {
  assert.equal(compareVersions('v2.0.10', 'v2.0.9'), 1);
  assert.equal(compareVersions('v2.1.0', 'v2.0.999'), 1);
  assert.equal(compareVersions('v2.0.9007199254740993', 'v2.0.9007199254740992'), 1);
});
test('invalid release versions fail closed', () => {
  for (const tag of ['main', 'v2.0.01', 'v2.0.6-beta', 'v2.0.6\nother', 'v2.0']) {
    assert.throws(() => channelPolicy(tag, null, true));
    assert.throws(() => compareVersions('v2.0.6', tag));
  }
});
