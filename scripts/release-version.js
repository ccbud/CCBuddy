#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const VERSION_RE = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const MINIMUM_NATIVE_MAJOR = 2n;

const file = (relative) => path.join(ROOT, relative);
const read = (relative) => fs.readFileSync(file(relative), 'utf8');

function replaceOne(relative, pattern, replacement) {
  const before = read(relative);
  const globalPattern = new RegExp(
    pattern.source,
    pattern.flags.includes('g') ? pattern.flags : `${pattern.flags}g`
  );
  const matches = [...before.matchAll(globalPattern)];
  if (matches.length !== 1) {
    throw new Error(`${relative}: expected exactly one version field, found ${matches.length}`);
  }
  const after = before.replace(pattern, replacement);
  const temporary = `${file(relative)}.version-sync`;
  fs.writeFileSync(temporary, after);
  fs.renameSync(temporary, file(relative));
}

function packageVersion() {
  return JSON.parse(read('package.json')).version;
}

const sources = [
  {
    name: 'package.json',
    get: () => JSON.parse(read('package.json')).version,
    set: (version) => replaceOne(
      'package.json',
      /^  "version": "[^"]+",$/m,
      `  "version": "${version}",`
    ),
  },
  {
    name: 'package-lock.json',
    get: () => {
      const lock = JSON.parse(read('package-lock.json'));
      const root = lock.packages?.['']?.version;
      return lock.version === root ? lock.version : `${lock.version} / ${root}`;
    },
    set: (version) => {
      replaceOne(
        'package-lock.json',
        /^  "version": "[^"]+",$/m,
        `  "version": "${version}",`
      );
      replaceOne(
        'package-lock.json',
        /^(  "packages": \{\n    "": \{\n      "name": "[^"]+",\n)      "version": "[^"]+",$/m,
        `$1      "version": "${version}",`
      );
    },
  },
  {
    name: 'src-tauri/tauri.conf.json',
    get: () => JSON.parse(read('src-tauri/tauri.conf.json')).version,
    set: (version) => replaceOne(
      'src-tauri/tauri.conf.json',
      /^  "version": "[^"]+",$/m,
      `  "version": "${version}",`
    ),
  },
  {
    name: 'src-tauri/Cargo.toml',
    get: () => read('src-tauri/Cargo.toml').match(/^name = "app"\nversion = "([^"]+)"/m)?.[1],
    set: (version) => replaceOne(
      'src-tauri/Cargo.toml',
      /^name = "app"\nversion = "[^"]+"/gm,
      `name = "app"\nversion = "${version}"`
    ),
  },
  {
    name: 'src-tauri/Cargo.lock',
    get: () => read('src-tauri/Cargo.lock')
      .match(/^\[\[package\]\]\nname = "app"\nversion = "([^"]+)"/m)?.[1],
    set: (version) => replaceOne(
      'src-tauri/Cargo.lock',
      /^\[\[package\]\]\nname = "app"\nversion = "[^"]+"/gm,
      `[[package]]\nname = "app"\nversion = "${version}"`
    ),
  },
  {
    name: 'native/project.yml',
    get: () => read('native/project.yml').match(/^    MARKETING_VERSION: "([^"]+)"$/m)?.[1],
    set: (version) => replaceOne(
      'native/project.yml',
      /^    MARKETING_VERSION: "[^"]+"$/gm,
      `    MARKETING_VERSION: "${version}"`
    ),
  },
];

function assertVersion(version) {
  const match = VERSION_RE.exec(version || '');
  if (!match) {
    throw new Error(`invalid release version: ${version || '<empty>'} (expected x.y.z)`);
  }
  if (BigInt(match[1]) < MINIMUM_NATIVE_MAJOR) {
    throw new Error(`invalid native release version: ${version} (major must be at least 2)`);
  }
}

function check(expected = packageVersion(), includeGenerated = true) {
  assertVersion(expected);
  let failed = false;
  for (const source of sources) {
    const actual = source.get();
    const ok = actual === expected;
    console.log(`${ok ? 'OK' : 'MISMATCH'} ${source.name}: ${actual || '<missing>'}`);
    failed ||= !ok;
  }

  const project = file('native/CCBuddy.xcodeproj/project.pbxproj');
  if (includeGenerated && fs.existsSync(project)) {
    const generated = [...read('native/CCBuddy.xcodeproj/project.pbxproj')
      .matchAll(/MARKETING_VERSION = ([^;]+);/g)]
      .map((match) => match[1]);
    const ok = generated.length > 0 && generated.every((version) => version === expected);
    console.log(`${ok ? 'OK' : 'MISMATCH'} generated Xcode project: ${[...new Set(generated)].join(', ') || '<missing>'}`);
    failed ||= !ok;
  }

  if (failed) throw new Error(`release versions are not all ${expected}`);
  return expected;
}

function set(version) {
  assertVersion(version);
  for (const source of sources) source.set(version);
  return check(version, false);
}

function main() {
  const [command = 'check', value] = process.argv.slice(2);
  if (command === 'print') {
    console.log(packageVersion());
  } else if (command === 'check') {
    check(value);
  } else if (command === 'set') {
    if (!value) throw new Error('usage: release-version.js set <x.y.z>');
    set(value);
  } else {
    throw new Error('usage: release-version.js <check [x.y.z] | set <x.y.z> | print>');
  }
}

if (require.main === module) {
  try { main(); }
  catch (error) { console.error(`ERROR ${error.message}`); process.exit(1); }
}

module.exports = { check, set };
