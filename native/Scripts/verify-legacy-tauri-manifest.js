#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { isDeepStrictEqual } = require('util');

// Frozen from tag v1.3.9 (4b65286). The shipped Tauri application has this endpoint,
// public key, bundle identifier, and platform lookup order compiled into it.
const LEGACY_CONTRACT = Object.freeze({
  endpoint: 'https://github.com/ccbud/ccbud/releases/latest/download/latest.json',
  publicKey: 'dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IEZCMTMwRjI5MDhCNjE1NzUKUldSMUZiWUlLUThUK3kybFBUU3ljMWUyenAwR3U1NjdPZm1jM25ocndIclhLYUFGTU92KzJXRFQK',
  bundleIdentifier: 'dev.ccbud.gateway',
  version: Object.freeze([1, 3, 9]),
  platformCandidates: Object.freeze(['darwin-aarch64-app', 'darwin-aarch64']),
  // Every macOS key a 1.3.9 updater may ask for. It resolves its own platform by name and treats
  // an absent key as a failed check, so an Intel Mac needs darwin-x86_64 present even though the
  // release is one universal archive that both kinds of Mac download.
  requiredTargets: Object.freeze([
    'darwin-aarch64-app',
    'darwin-aarch64',
    'darwin-x86_64-app',
    'darwin-x86_64',
  ]),
});

function fail(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith('--') || value === undefined) fail(`invalid argument: ${key || '<empty>'}`);
    result[key.slice(2)] = value;
  }
  return result;
}

function parseVersion(value) {
  if (!/^\d+\.\d+\.\d+$/.test(value)) fail(`invalid version: ${value}`);
  return value.split('.').map(Number);
}

function compareVersions(left, right) {
  for (let index = 0; index < 3; index += 1) {
    if (left[index] !== right[index]) return left[index] - right[index];
  }
  return 0;
}

function removeOptionalTerminalLineEnding(value) {
  if (value.endsWith('\r\n')) return value.slice(0, -2);
  if (value.endsWith('\n')) return value.slice(0, -1);
  return value;
}

function decodeCanonicalBase64(value, label = 'value') {
  if (typeof value !== 'string' || !value.length || /\s/.test(value)) {
    fail(`${label} is not canonical Base64`);
  }
  const decoded = Buffer.from(value, 'base64');
  if (!decoded.length || decoded.toString('base64') !== value) {
    fail(`${label} is not canonical Base64`);
  }
  return decoded;
}

function isStrictRfc3339(value) {
  if (typeof value !== 'string') return false;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(?:Z|[+-](\d{2}):(\d{2}))$/.exec(value);
  if (!match) return false;
  const [, yearText, monthText, dayText, hourText, minuteText, secondText,
    offsetHourText, offsetMinuteText] = match;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (month < 1 || month > 12 || day < 1 || day > daysInMonth[month - 1]) return false;
  if (Number(hourText) > 23 || Number(minuteText) > 59 || Number(secondText) > 59) return false;
  return offsetHourText === undefined ||
    (Number(offsetHourText) <= 23 && Number(offsetMinuteText) <= 59);
}

function decodeMinisignPublicKey(encodedPublicKey) {
  const text = decodeCanonicalBase64(encodedPublicKey, 'legacy updater public key').toString('utf8');
  const lines = removeOptionalTerminalLineEnding(text).split(/\r?\n/);
  if (lines.length !== 2 || !lines[0].startsWith('untrusted comment: minisign public key: ')) {
    fail('legacy updater public key has an unexpected envelope');
  }
  const binary = decodeCanonicalBase64(lines[1], 'minisign public key payload');
  if (binary.length !== 42 || binary[0] !== 0x45 || (binary[1] !== 0x64 && binary[1] !== 0x44)) {
    fail('legacy updater public key payload is invalid');
  }
  return { keyID: binary.subarray(2, 10), rawKey: binary.subarray(10, 42) };
}

function verifyMinisign(artifact, encodedSignature, encodedPublicKey) {
  const { keyID, rawKey } = decodeMinisignPublicKey(encodedPublicKey);
  const signatureText = decodeCanonicalBase64(encodedSignature, 'updater signature').toString('utf8');
  const lines = removeOptionalTerminalLineEnding(signatureText).split(/\r?\n/);
  if (lines.length !== 4 || !lines[0].startsWith('untrusted comment: ') ||
      !lines[2].startsWith('trusted comment: ')) {
    fail('updater signature is not the four-line Tauri minisign format');
  }

  const envelope = decodeCanonicalBase64(lines[1], 'minisign signature payload');
  const globalSignature = decodeCanonicalBase64(lines[3], 'minisign global signature');
  if (envelope.length !== 74 || envelope[0] !== 0x45 || envelope[1] !== 0x44 ||
      !envelope.subarray(2, 10).equals(keyID) || globalSignature.length !== 64) {
    fail('updater signature does not use the legacy production updater key');
  }

  const signature = envelope.subarray(10, 74);
  const spkiPrefix = Buffer.from('302a300506032b6570032100', 'hex');
  const publicKey = crypto.createPublicKey({
    key: Buffer.concat([spkiPrefix, rawKey]),
    format: 'der',
    type: 'spki',
  });
  const digest = crypto.createHash('blake2b512').update(artifact).digest();
  if (!crypto.verify(null, digest, publicKey, signature)) {
    fail('updater artifact signature verification failed');
  }

  const trustedComment = lines[2].slice('trusted comment: '.length);
  const globalPayload = Buffer.concat([signature, Buffer.from(trustedComment, 'utf8')]);
  if (!crypto.verify(null, globalPayload, publicKey, globalSignature)) {
    fail('updater trusted-comment signature verification failed');
  }
}

function selectLegacyPlatform(platforms, candidates) {
  for (const candidate of candidates) {
    const value = platforms[candidate];
    if (value && typeof value === 'object' && !Array.isArray(value)) return { key: candidate, value };
  }
  fail(`manifest has none of the legacy targets: ${candidates.join(', ')}`);
}

function validateLegacyConfig(config, contract = LEGACY_CONTRACT) {
  if (config?.identifier !== contract.bundleIdentifier) fail('Tauri/native bundle identifier contract drifted');
  if (config?.plugins?.updater?.pubkey !== contract.publicKey) fail('configured updater key differs from v1.3.9');
  const endpoints = config?.plugins?.updater?.endpoints;
  if (!Array.isArray(endpoints) || endpoints.length !== 1 || endpoints[0] !== contract.endpoint) {
    fail('configured updater endpoint differs from v1.3.9');
  }
}

function verifyLegacyManifestContract(input, contract = LEGACY_CONTRACT) {
  const { version, repository, artifact, artifactName, signatureAsset, manifest, config } = input || {};
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository)) fail('invalid repository');
  if (compareVersions(parseVersion(version), contract.version) <= 0) {
    fail('release must be newer than legacy 1.3.9');
  }
  if (!Buffer.isBuffer(artifact)) fail('updater artifact must be a Buffer');
  if (typeof artifactName !== 'string' || !artifactName.length || path.basename(artifactName) !== artifactName) {
    fail('updater artifact name is invalid');
  }
  if (typeof signatureAsset !== 'string') fail('updater signature asset is invalid');
  const encodedSignature = removeOptionalTerminalLineEnding(signatureAsset);
  validateLegacyConfig(config, contract);

  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) fail('manifest is invalid');
  if (manifest.version !== version) fail(`manifest version is ${manifest.version || '<missing>'}`);
  if (!isStrictRfc3339(manifest.pub_date)) fail('manifest pub_date is not strict RFC 3339');
  if (!manifest.platforms || typeof manifest.platforms !== 'object' || Array.isArray(manifest.platforms)) {
    fail('manifest platforms are missing');
  }

  const selected = selectLegacyPlatform(manifest.platforms, contract.platformCandidates);
  const [preferredKey] = contract.platformCandidates;
  if (selected.key !== preferredKey) fail('legacy preferred app target is missing');
  for (const target of contract.requiredTargets) {
    const entry = manifest.platforms[target];
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
      fail(`legacy target is missing: ${target}`);
    }
    if (!isDeepStrictEqual(selected.value, entry)) {
      fail(`legacy target does not describe the same artifact: ${target}`);
    }
  }

  const expectedURL = `https://github.com/${repository}/releases/download/v${version}/${encodeURIComponent(artifactName)}`;
  if (selected.value.url !== expectedURL) fail(`selected updater URL is ${selected.value.url || '<missing>'}`);
  if (selected.value.signature !== encodedSignature) fail('manifest signature differs from the signature asset');
  const digest = crypto.createHash('sha256').update(artifact).digest('hex');
  if (selected.value.sha256 !== digest) fail('manifest SHA-256 differs from the updater artifact');
  verifyMinisign(artifact, encodedSignature, contract.publicKey);
  return { selectedKey: selected.key, digest };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  for (const name of ['version', 'repository', 'artifact', 'signature', 'manifest', 'config']) {
    if (!args[name]) fail(`missing --${name}`);
  }
  const artifactPath = path.resolve(args.artifact);
  const result = verifyLegacyManifestContract({
    version: args.version,
    repository: args.repository,
    artifact: fs.readFileSync(artifactPath),
    artifactName: path.basename(artifactPath),
    signatureAsset: fs.readFileSync(path.resolve(args.signature), 'utf8'),
    manifest: JSON.parse(fs.readFileSync(path.resolve(args.manifest), 'utf8')),
    config: JSON.parse(fs.readFileSync(path.resolve(args.config), 'utf8')),
  });
  console.log(`verified legacy Tauri manifest selection and production signature: ${result.selectedKey} (${result.digest})`);
}

module.exports = {
  LEGACY_CONTRACT,
  decodeCanonicalBase64,
  isStrictRfc3339,
  validateLegacyConfig,
  verifyLegacyManifestContract,
};

if (require.main === module) {
  try { main(); }
  catch (error) {
    console.error(`legacy Tauri updater manifest verification failed: ${error.message}`);
    process.exit(1);
  }
}
