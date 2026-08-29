#!/usr/bin/env node
'use strict';

const assert = require('assert/strict');
const crypto = require('crypto');
const {
  LEGACY_CONTRACT,
  decodeCanonicalBase64,
  isStrictRfc3339,
  validateLegacyConfig,
  verifyLegacyManifestContract,
} = require('../verify-legacy-tauri-manifest.js');

const ARTIFACT = Buffer.from('test');
const VERSION = '2.0.0';
const REPOSITORY = 'ccbud/ccbud';
const ARTIFACT_NAME = 'CC.Buddy_universal.app.tar.gz';
const PUBLIC_KEY_PAYLOAD = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3';
const PUBLIC_KEY = Buffer.from([
  'untrusted comment: minisign public key: E7620F1842B4E81F',
  PUBLIC_KEY_PAYLOAD,
  '',
].join('\n')).toString('base64');
const SIGNATURE_TEXT = [
  'untrusted comment: signature from minisign secret key',
  'RUQf6LRCGA9i559r3g7V1qNyJDApGip8MfqcadIgT9CuhV3EMhHoN1mGTkUidF/z7SrlQgXdy8ofjb7bNJJylDOocrCo8KLzZwo=',
  'trusted comment: timestamp:1556193335\tfile:test',
  'y/rUw2y8/hOUYjZU71eHp/Wo1KZ40fGy2VJEDl34XMJM+TX48Ss/17u3IvIfbVR1FkZZSNCisQbuQY+bHwhEBg==',
  '',
].join('\n');
const SIGNATURE = Buffer.from(SIGNATURE_TEXT).toString('base64');
const TEST_CONTRACT = Object.freeze({ ...LEGACY_CONTRACT, publicKey: PUBLIC_KEY });

function configWith(endpoints = [TEST_CONTRACT.endpoint]) {
  return {
    identifier: TEST_CONTRACT.bundleIdentifier,
    plugins: { updater: { pubkey: TEST_CONTRACT.publicKey, endpoints } },
  };
}

function manifestFor(artifact = ARTIFACT) {
  const url = `https://github.com/${REPOSITORY}/releases/download/v${VERSION}/${ARTIFACT_NAME}`;
  const sha256 = crypto.createHash('sha256').update(artifact).digest('hex');
  const platform = { url, signature: SIGNATURE, sha256 };
  return {
    version: VERSION,
    pub_date: '2026-08-22T12:34:56.123456789+08:00',
    platforms: {
      'darwin-aarch64-app': platform,
      'darwin-aarch64': { ...platform },
      'darwin-x86_64-app': { ...platform },
      'darwin-x86_64': { ...platform },
    },
  };
}

function inputFor(artifact = ARTIFACT) {
  return {
    version: VERSION,
    repository: REPOSITORY,
    artifact,
    artifactName: ARTIFACT_NAME,
    signatureAsset: `${SIGNATURE}\r\n`,
    manifest: manifestFor(artifact),
    config: configWith(),
  };
}

let passed = 0;
function test(name, callback) {
  callback();
  passed += 1;
  console.log(`ok ${passed} - ${name}`);
}

test('canonical Base64 requires exact padding and rejects whitespace', () => {
  assert.deepEqual(decodeCanonicalBase64('Zg=='), Buffer.from('f'));
  for (const malformed of ['Zg', 'Zg=', 'Zg===', ' Zg==', 'Zg==\n']) {
    assert.throws(() => decodeCanonicalBase64(malformed), /not canonical Base64/);
  }
});

test('strict RFC 3339 accepts Z, offsets, leap dates, and up to nine fractional digits', () => {
  for (const value of [
    '2026-08-22T01:02:03Z',
    '2000-02-29T23:59:59.123456789Z',
    '2026-08-22T01:02:03.1-00:30',
    '2026-08-22T01:02:03+23:59',
  ]) assert.equal(isStrictRfc3339(value), true, value);
});

test('strict RFC 3339 rejects loose syntax and invalid calendar or clock fields', () => {
  for (const value of [
    'August 22, 2026', '2026-08-22', '1900-02-29T00:00:00Z',
    '2026-02-30T00:00:00Z', '2026-00-01T00:00:00Z', '2026-01-00T00:00:00Z',
    '2026-08-22T24:00:00Z', '2026-08-22T00:60:00Z', '2026-08-22T00:00:60Z',
    '2026-08-22T00:00:00.1234567890Z', '2026-08-22t00:00:00z',
    '2026-08-22T00:00:00+24:00', '2026-08-22T00:00:00+00:60',
  ]) assert.equal(isStrictRfc3339(value), false, value);
});

test('updater config requires exactly the frozen one-element endpoint array', () => {
  assert.doesNotThrow(() => validateLegacyConfig(configWith(), TEST_CONTRACT));
  for (const endpoints of [
    [],
    ['https://example.invalid/latest.json'],
    [TEST_CONTRACT.endpoint, 'https://example.invalid/latest.json'],
    ['https://example.invalid/latest.json', TEST_CONTRACT.endpoint],
    TEST_CONTRACT.endpoint,
  ]) {
    assert.throws(() => validateLegacyConfig(configWith(endpoints), TEST_CONTRACT), /endpoint differs/);
  }
});

test('valid manifest selects the preferred target and verifies both Minisign signatures', () => {
  const result = verifyLegacyManifestContract(inputFor(), TEST_CONTRACT);
  assert.equal(result.selectedKey, 'darwin-aarch64-app');
  assert.equal(result.digest, crypto.createHash('sha256').update(ARTIFACT).digest('hex'));
});

test('manifest rejects loose dates and missing platform data', () => {
  const looseDate = inputFor();
  looseDate.manifest.pub_date = 'August 22, 2026';
  assert.throws(() => verifyLegacyManifestContract(looseDate, TEST_CONTRACT), /strict RFC 3339/);

  const missingPlatforms = inputFor();
  delete missingPlatforms.manifest.platforms;
  assert.throws(() => verifyLegacyManifestContract(missingPlatforms, TEST_CONTRACT), /platforms are missing/);
});

test('manifest requires matching preferred and fallback targets', () => {
  const missingPreferred = inputFor();
  delete missingPreferred.manifest.platforms['darwin-aarch64-app'];
  assert.throws(() => verifyLegacyManifestContract(missingPreferred, TEST_CONTRACT), /preferred app target/);

  const missingFallback = inputFor();
  delete missingFallback.manifest.platforms['darwin-aarch64'];
  assert.throws(
    () => verifyLegacyManifestContract(missingFallback, TEST_CONTRACT),
    /target is missing: darwin-aarch64/,
  );

  const mismatchedFallback = inputFor();
  mismatchedFallback.manifest.platforms['darwin-aarch64'].url += '?other';
  assert.throws(() => verifyLegacyManifestContract(mismatchedFallback, TEST_CONTRACT), /same artifact/);
});

// An Intel Mac running 1.3.9 reads darwin-x86_64 and nothing else. Dropping the key does not make
// the release arm64-only for those users, it makes their update check fail with no explanation, so
// the omission has to fail here instead.
test('manifest requires the Intel targets the last 1.x release also published', () => {
  for (const target of ['darwin-x86_64-app', 'darwin-x86_64']) {
    const missing = inputFor();
    delete missing.manifest.platforms[target];
    assert.throws(
      () => verifyLegacyManifestContract(missing, TEST_CONTRACT),
      new RegExp(`target is missing: ${target}`),
    );

    const divergent = inputFor();
    divergent.manifest.platforms[target].sha256 = 'f'.repeat(64);
    assert.throws(
      () => verifyLegacyManifestContract(divergent, TEST_CONTRACT),
      new RegExp(`same artifact: ${target}`),
    );
  }
});

test('tampered artifact with a matching SHA-256 still fails Minisign verification', () => {
  const tampered = inputFor(Buffer.from('tampered'));
  assert.throws(() => verifyLegacyManifestContract(tampered, TEST_CONTRACT), /artifact signature verification failed/);
});

test('signature asset permits only one terminal LF or CRLF', () => {
  const oneLf = inputFor();
  oneLf.signatureAsset = `${SIGNATURE}\n`;
  assert.doesNotThrow(() => verifyLegacyManifestContract(oneLf, TEST_CONTRACT));

  const repeated = inputFor();
  repeated.signatureAsset = `${SIGNATURE}\n\n`;
  assert.throws(() => verifyLegacyManifestContract(repeated, TEST_CONTRACT), /signature differs/);
});

console.log(`verified ${passed} legacy Tauri manifest validator cases`);
