#!/usr/bin/env node
'use strict';

/*
 * The manifest's platform keys decide who can install the next release.
 *
 * A Tauri updater asks for its own platform by name and treats a missing key as a failed check —
 * not as "no update available". Publishing only the Apple-silicon keys therefore does not leave
 * Intel Macs on the previous version quietly; it leaves them erroring on every check with no way
 * forward. That is easy to do by accident and invisible on the machine doing the release, so it is
 * asserted here.
 */

const assert = require('node:assert/strict');
const test = require('node:test');

const { buildManifest, MACOS_TARGETS } = require('../generate-latest-json.js');

const INPUT = Object.freeze({
  version: '2.0.0',
  pubDate: '2026-08-29T12:34:56.000Z',
  url: 'https://github.com/ccbud/ccbud/releases/download/v2.0.0/CC.Buddy_universal.app.tar.gz',
  signature: 'dGhlLXNpZ25hdHVyZQ',
  sha256: 'a'.repeat(64),
});

test('every macOS target a 1.3.9 updater may ask for is published', () => {
  const manifest = buildManifest(INPUT);

  assert.deepEqual(Object.keys(manifest.platforms).sort(), [...MACOS_TARGETS].sort());
  for (const target of ['darwin-aarch64', 'darwin-aarch64-app', 'darwin-x86_64', 'darwin-x86_64-app']) {
    assert.ok(manifest.platforms[target], `missing target: ${target}`);
  }
});

test('one universal archive serves both kinds of Mac', () => {
  const manifest = buildManifest(INPUT);
  const entries = MACOS_TARGETS.map((target) => manifest.platforms[target]);

  for (const entry of entries) {
    assert.deepEqual(entry, { url: INPUT.url, signature: INPUT.signature, sha256: INPUT.sha256 });
  }
  // Distinct objects, so that a later edit to one key cannot silently rewrite the others.
  assert.equal(new Set(entries).size, entries.length);
});

test('the manifest carries the version and date the updater compares against', () => {
  const manifest = buildManifest(INPUT);

  assert.equal(manifest.version, INPUT.version);
  assert.equal(manifest.pub_date, INPUT.pubDate);
});

test('the published targets stay a frozen set', () => {
  assert.ok(Object.isFrozen(MACOS_TARGETS));
  assert.equal(MACOS_TARGETS.length, 4);
});
