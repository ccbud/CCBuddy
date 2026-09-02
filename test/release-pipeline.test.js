'use strict';

// Guards the release-only preparation that a dirty developer checkout can accidentally hide:
// the ignored Bifrost helper and loopback CLI fixtures must also exist in a clean checkout.

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const releaseScript = fs.readFileSync(path.join(ROOT, 'scripts/release.js'), 'utf8');
const prBuildWorkflow = fs.readFileSync(
  path.join(ROOT, '.github/workflows/pr-build.yml'),
  'utf8'
);
const releaseWorkflow = fs.readFileSync(
  path.join(ROOT, '.github/workflows/release.yml'),
  'utf8'
);
const nativePackager = fs.readFileSync(
  path.join(ROOT, 'native/Scripts/package-native-release.sh'),
  'utf8'
);
const packagedSelfCheck = fs.readFileSync(
  path.join(ROOT, 'native/Scripts/run-packaged-selfcheck.sh'),
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

check(
  'release signing accepts an unencrypted updater key',
  releaseWorkflow.includes('TAURI_SIGNING_PRIVATE_KEY_PASSWORD="$updater_password"')
    && !releaseWorkflow.includes('missing TAURI_SIGNING_PRIVATE_KEY_PASSWORD')
    && !nativePackager.includes(
      'require_value TAURI_SIGNING_PRIVATE_KEY_PASSWORD "$updater_signing_password"'
    )
);
check(
  'notarization requires Accepted and prints the Apple rejection log',
  nativePackager.includes('--wait --timeout 30m --output-format json')
    && nativePackager.includes('"$submission_status" != Accepted')
    && nativePackager.includes('xcrun notarytool log "$submission_id"')
    && nativePackager.includes('fail "$label notarization failed')
);
check(
  'packaged self-check ignores persisted window restoration state',
  packagedSelfCheck.includes('"$EXECUTABLE" -ApplePersistenceIgnoreState YES')
);
check(
  'packaged self-check requires an explicit Bifrost verification mode',
  packagedSelfCheck.includes('readonly BIFROST_MODE="${3:-}"')
    && packagedSelfCheck.includes('raw|developer-id) ;;')
    && packagedSelfCheck.includes(
      'fail "Bifrost verification mode must be raw or developer-id"'
    )
);
check(
  'packaged self-check passes the selected Bifrost mode to the app',
  packagedSelfCheck.includes('CCBUD_SELFCHECK_BIFROST_MODE="$BIFROST_MODE"')
    && packagedSelfCheck.includes('--arg expectedBifrostMode "$BIFROST_MODE"')
    && packagedSelfCheck.includes('.values.mode] == [$expectedBifrostMode]')
);

const appNotary = nativePackager.indexOf('notarize_and_staple "$NOTARY_ZIP" "$APP" app');
const appStapledVerification = nativePackager.indexOf(
  'verify-release-app.sh" "$APP" "$VERSION" stapled'
);
const appSignedSelfCheck = nativePackager.indexOf('"$APP" 150 developer-id');
const updaterCreation = nativePackager.indexOf('/usr/bin/tar -czf "$UPDATER"');
check(
  'signed packaging gates the stapled app before creating updater artifacts',
  appNotary >= 0
    && appStapledVerification > appNotary
    && appSignedSelfCheck > appStapledVerification
    && updaterCreation > appSignedSelfCheck
);

const updaterExtraction = nativePackager.indexOf('/usr/bin/tar -xzf "$UPDATER"');
const extractedVerification = nativePackager.indexOf(
  'verify-release-app.sh" "$EXTRACTED/CC Buddy.app" "$VERSION" "$VERIFY_MODE"'
);
const extractedSelfCheck = nativePackager.indexOf(
  '"$EXTRACTED/CC Buddy.app" 150 developer-id'
);
const dmgCreation = nativePackager.indexOf('hdiutil create -volname');
check(
  'signed packaging gates the extracted updater app before creating the DMG',
  updaterExtraction >= 0
    && extractedVerification > updaterExtraction
    && extractedSelfCheck > extractedVerification
    && dmgCreation > extractedSelfCheck
);

const dmgAssessment = nativePackager.indexOf('spctl --assess --type open');
const dmgAttachment = nativePackager.indexOf('hdiutil attach -readonly -nobrowse -noautoopen');
const mountedVerification = nativePackager.indexOf(
  'verify-release-app.sh" "$MOUNTED_APP" "$VERSION" stapled'
);
const mountedSelfCheck = nativePackager.indexOf('"$MOUNTED_APP" 150 developer-id');
const dmgDetach = nativePackager.indexOf('detach_mounted_dmg "$DMG_MOUNTPOINT"', mountedSelfCheck);
const updaterSigning = nativePackager.indexOf('npx --no-install tauri signer sign');
check(
  'signed packaging verifies and exercises the app from the final read-only DMG',
  dmgAssessment >= 0
    && dmgAttachment > dmgAssessment
    && mountedVerification > dmgAttachment
    && mountedSelfCheck > mountedVerification
    && dmgDetach > mountedSelfCheck
    && updaterSigning > dmgDetach
);
check(
  'DMG mounting is noninteractive and cleanup safely handles detach failure',
  nativePackager.includes('hdiutil attach -readonly -nobrowse -noautoopen')
    && nativePackager.includes('-mountpoint "$DMG_MOUNTPOINT" "$DMG"')
    && nativePackager.includes('trap cleanup EXIT')
    && nativePackager.includes("trap 'exit 130' INT")
    && nativePackager.includes("trap 'exit 143' TERM")
    && nativePackager.includes("trap 'exit 129' HUP")
    && nativePackager.includes('detach_mounted_dmg() {')
    && nativePackager.includes('detach_mounted_dmg "$DMG_MOUNTPOINT"')
    && nativePackager.includes('hdiutil detach -force "$mountpoint"')
    && nativePackager.includes('could not detach $DMG_MOUNTPOINT; preserved $WORK_ROOT')
    && nativePackager.includes('[[ "$status" -ne 0 ]] || status=1')
    && nativePackager.indexOf('exit "$status"')
      < nativePackager.indexOf('rm -rf -- "$WORK_ROOT"')
    && nativePackager.indexOf('hdiutil detach -force "$mountpoint"')
      < nativePackager.indexOf('rm -rf -- "$WORK_ROOT"')
);
check(
  'signed packaging has exactly three Developer ID packaged self-check gates',
  (nativePackager.match(/run-packaged-selfcheck\.sh/g) || []).length === 3
    && (nativePackager.match(/150 developer-id/g) || []).length === 3
);

check(
  'PR and release unsigned packaged checks explicitly request raw verification',
  /run-packaged-selfcheck\.sh[\s\\]*\n?[\s\S]{0,160}? 150 raw/.test(prBuildWorkflow)
    && /run-packaged-selfcheck\.sh[\s\\]*\n?[\s\S]{0,160}? 150 raw/.test(releaseWorkflow)
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
