#!/usr/bin/env node
'use strict';

/* Generate the arm64-only cask from a verified release DMG. Missing artifacts are fatal. */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const ROOT = path.resolve(__dirname, '..');
const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));
const version = process.env.VERSION || pkg.version;

if (!/^\d+\.\d+\.\d+$/.test(version)) {
  console.error('[update-cask] VERSION must be x.y.z');
  process.exit(1);
}

const dmgDir = process.argv[2] ? path.resolve(process.argv[2]) : path.join(ROOT, 'dist');
const outFile = process.argv[3] ? path.resolve(process.argv[3]) : path.join(ROOT, 'homebrew', 'Casks', 'ccbud.rb');

const candidates = [
  path.join(dmgDir, `CC.Buddy_${version}_aarch64.dmg`),
  path.join(dmgDir, `CC Buddy_${version}_aarch64.dmg`),
];
const dmg = candidates.find((candidate) => fs.existsSync(candidate));
if (!dmg || !fs.statSync(dmg).isFile()) {
  console.error('[update-cask] missing arm64 DMG:', candidates.join(' or '));
  process.exit(1);
}
const sha256 = crypto.createHash('sha256').update(fs.readFileSync(dmg)).digest('hex');

const cask = `cask "ccbud" do
  version "${version}"
  sha256 "${sha256}"

  url "https://github.com/ccbud/ccbud/releases/download/v#{version}/CC.Buddy_#{version}_aarch64.dmg",
      verified: "github.com/ccbud/ccbud/"
  name "CC Buddy"
  desc "CC Buddy — Claude Code gateway plus Claude Code/Codex session browser"
  homepage "https://github.com/ccbud/ccbud"

  # CC Buddy can update itself in-app; Homebrew handles normal cask upgrades.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :ventura

  app "CC Buddy.app"

  zap trash: [
    "~/Library/Application Support/ccbud",
    "~/Library/Preferences/dev.ccbud.gateway.plist",
    "~/Library/Saved Application State/dev.ccbud.gateway.savedState",
    "~/Library/Logs/ccbud",
  ]
end
`;

fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, cask);
console.log('[update-cask] wrote', path.relative(ROOT, outFile), 'for v' + version, sha256);
