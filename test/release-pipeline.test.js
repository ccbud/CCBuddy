'use strict';

// Guards the release-only preparation that a dirty developer checkout can accidentally hide:
// the ignored Bifrost helper and loopback CLI fixtures must also exist in a clean checkout.

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const releaseScript = fs.readFileSync(path.join(ROOT, 'scripts/release.js'), 'utf8');
const releaseWorkflow = fs.readFileSync(
  path.join(ROOT, '.github/workflows/release.yml'),
  'utf8'
);
const caskGenerator = fs.readFileSync(path.join(ROOT, 'scripts/update-cask.js'), 'utf8');

let pass = 0;
let fail = 0;
const check = (name, condition, detail = '') => {
  if (condition) {
    pass += 1;
    console.log(`  \x1b[32mPASS\x1b[0m ${name}`);
  } else {
    fail += 1;
    console.log(`  \x1b[31mFAIL\x1b[0m ${name}${detail ? ` — ${detail}` : ''}`);
  }
};

const helperFetch = releaseScript.indexOf("run('native/Scripts/fetch-bifrost.sh'");
const helperVerify = releaseScript.indexOf("run('native/Scripts/verify-bifrost.sh'");
const versionSet = releaseScript.indexOf("run(process.execPath, ['scripts/release-version.js', 'set'");
const firstGenerate = releaseScript.indexOf("run('xcodegen', ['generate'");

check('release script fetches the pinned Bifrost helper', helperFetch >= 0);
check(
  'release script applies child-only environment overrides',
  releaseScript.includes('env: { ...process.env, ...(options.env || {}) }')
);
check(
  'release script requests the universal Bifrost helper',
  /env:\s*\{\s*CCBUD_BIFROST_ARCH:\s*'universal'\s*\}/.test(releaseScript)
);
check(
  'release script verifies the helper before changing version files',
  helperFetch >= 0 && helperVerify > helperFetch && versionSet > helperVerify
);
check(
  'release script verifies both universal helper slices',
  /verify-bifrost\.sh'[\s\S]*?'arm64 x86_64'/.test(releaseScript.slice(helperVerify, versionSet))
);
check(
  'release script prepares the helper before XcodeGen generation',
  helperFetch >= 0 && firstGenerate > helperFetch
);

const nativeStart = releaseWorkflow.indexOf('\n  native-test:');
const buildStart = releaseWorkflow.indexOf('\n  build-native:');
const nativeJob = releaseWorkflow.slice(nativeStart, buildStart);
const codexCopy = 'cp "$codex" native/Vendor/test-tools/codex';
const claudeCopy = 'cp "$claude" native/Vendor/test-tools/claude';

check('release workflow contains an isolated native-test job', nativeStart >= 0 && buildStart > nativeStart);
check(
  'native-test installs both loopback CLIs into Vendor test-tools',
  nativeJob.includes(codexCopy) && nativeJob.includes(claudeCopy)
);
check(
  'native-test verifies both copied loopback CLIs',
  nativeJob.includes('cmp -s "$codex" native/Vendor/test-tools/codex')
    && nativeJob.includes('cmp -s "$claude" native/Vendor/test-tools/claude')
);
check(
  'native-test never receives release secrets',
  !nativeJob.includes('secrets.')
    && !/APPLE_(?:CERTIFICATE|API|SIGNING)|TAURI_SIGNING_PRIVATE_KEY/.test(nativeJob)
);

const homebrewStart = releaseWorkflow.indexOf('\n  homebrew:');
const homebrewJob = releaseWorkflow.slice(homebrewStart);
check(
  'cask generator publishes the universal macOS DMG without an architecture pin',
  caskGenerator.includes('CC.Buddy_${version}_universal.dmg')
    && caskGenerator.includes('CC.Buddy_#{version}_universal.dmg')
    && !caskGenerator.includes('depends_on arch:')
);
check(
  'Homebrew job verifies the universal DMG URL and rejects architecture pins',
  homebrewStart >= 0
    && homebrewJob.includes('Publish universal macOS Homebrew cask')
    && homebrewJob.includes('CC.Buddy_#{version}_universal.dmg')
    && homebrewJob.includes("if grep -Fq 'depends_on arch:'")
    && homebrewJob.includes('universal cask must not be architecture-restricted')
    && !homebrewJob.includes('depends_on arch: :arm64')
);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
