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
  const platform = { url, signature, sha256 };
  const manifest = {
    version: args.version,
    pub_date: args['pub-date'] || new Date().toISOString(),
    platforms: {
      'darwin-aarch64-app': platform,
      'darwin-aarch64': { ...platform },
    },
  };

  const output = path.resolve(args.output);
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`);
  console.log(`wrote ${output} (${sha256})`);
}

try { main(); }
catch (error) { console.error(`latest.json generation failed: ${error.message}`); process.exit(1); }
