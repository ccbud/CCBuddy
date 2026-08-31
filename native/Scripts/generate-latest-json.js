#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../..');
const TAURI_PUBLIC_KEY = JSON.parse(
  fs.readFileSync(path.join(ROOT, 'src-tauri/tauri.conf.json'), 'utf8')
).plugins.updater.pubkey;

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith('--') || value === undefined) throw new Error(`invalid argument: ${key || '<empty>'}`);
    result[key.slice(2)] = value;
  }
  return result;
}

function validateSignature(value) {
  const encoded = value.replace(/[\r\n]/g, '');
  const decoded = Buffer.from(encoded, 'base64');
  const canonical = decoded.toString('base64').replace(/=+$/, '');
  if (!decoded.length || canonical !== encoded.replace(/=+$/, '')) {
    throw new Error('signature file is not canonical Base64');
  }
  const lines = decoded.toString('utf8').trimEnd().split(/\r?\n/);
  if (lines.length !== 4 || !lines[0].startsWith('untrusted comment: ') ||
      !lines[2].startsWith('trusted comment: ')) {
    throw new Error('signature must decode to the four-line Tauri minisign format');
  }
  const publicKeyText = Buffer.from(TAURI_PUBLIC_KEY, 'base64').toString('utf8').trimEnd();
  const publicKey = Buffer.from(publicKeyText.split(/\r?\n/)[1], 'base64');
  const envelope = Buffer.from(lines[1], 'base64');
  const globalSignature = Buffer.from(lines[3], 'base64');
  if (publicKey.length !== 42 || envelope.length !== 74 || globalSignature.length !== 64 ||
      envelope[0] !== 0x45 || envelope[1] !== 0x44 ||
      !envelope.subarray(2, 10).equals(publicKey.subarray(2, 10))) {
    throw new Error('signature does not use the configured Tauri updater key');
  }
  return encoded;
}

// One universal archive under four keys. A Tauri updater resolves its own platform by name and
// treats an absent key as a failed check, so the Intel Macs still running 1.3.9 need
// `darwin-x86_64` spelled out even though it points at the same download as `darwin-aarch64`.
const MACOS_TARGETS = Object.freeze([
  'darwin-aarch64-app',
  'darwin-aarch64',
  'darwin-x86_64-app',
  'darwin-x86_64',
]);

function buildManifest({ version, pubDate, url, signature, sha256 }) {
  const platforms = {};
  for (const target of MACOS_TARGETS) platforms[target] = { url, signature, sha256 };
  return { version, pub_date: pubDate, platforms };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const required = ['version', 'repository', 'tag', 'artifact', 'signature', 'output'];
  for (const name of required) if (!args[name]) throw new Error(`missing --${name}`);
  if (!/^\d+\.\d+\.\d+$/.test(args.version)) throw new Error('version must be x.y.z');
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(args.repository)) throw new Error('invalid repository');
  if (args.tag !== `v${args.version}`) throw new Error('tag must equal v<version>');

  const artifact = path.resolve(args.artifact);
  if (!fs.statSync(artifact).isFile()) throw new Error('updater artifact is not a file');
  const asset = path.basename(artifact);
  const signature = validateSignature(fs.readFileSync(path.resolve(args.signature), 'utf8').trim());
  const sha256 = crypto.createHash('sha256').update(fs.readFileSync(artifact)).digest('hex');
  const url = `https://github.com/${args.repository}/releases/download/${args.tag}/${encodeURIComponent(asset)}`;
  const manifest = buildManifest({
    version: args.version,
    pubDate: args['pub-date'] || new Date().toISOString(),
    url,
    signature,
    sha256,
  });

  const output = path.resolve(args.output);
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`);
  console.log(`wrote ${output} (${sha256})`);
}

if (require.main === module) {
  try { main(); }
  catch (error) { console.error(`latest.json generation failed: ${error.message}`); process.exit(1); }
}

module.exports = { buildManifest, MACOS_TARGETS };
