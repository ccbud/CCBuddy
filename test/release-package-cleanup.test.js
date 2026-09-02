'use strict';

// Executes the packager's real EXIT cleanup function with a mocked hdiutil. This proves a failed
// detach cannot turn into a recursive delete of a still-mounted release image.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const packager = fs.readFileSync(
  path.join(ROOT, 'native/Scripts/package-native-release.sh'),
  'utf8'
);
const cleanupSource = packager.match(/^cleanup\(\) \{[\s\S]*?^\}/m)?.[0];
if (!cleanupSource) throw new Error('package cleanup function is missing');

const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ccbud-package-cleanup-'));
const mockBin = path.join(fixtureRoot, 'bin');
let pass = 0;
let fail = 0;
const check = (name, condition) => {
  if (condition) {
    pass++;
    console.log(`  \x1b[32mPASS\x1b[0m ${name}`);
  } else {
    fail++;
    console.log(`  \x1b[31mFAIL\x1b[0m ${name}`);
  }
};

try {
  fs.mkdirSync(mockBin);
  const mockHdiutil = path.join(mockBin, 'hdiutil');
  fs.writeFileSync(mockHdiutil, `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$CCBUD_TEST_HDIUTIL_LOG"
if [[ "\${2:-}" == -force ]]; then
  exit "$CCBUD_TEST_FORCE_STATUS"
fi
exit "$CCBUD_TEST_NORMAL_STATUS"
`);
  fs.chmodSync(mockHdiutil, 0o755);

  const runCleanup = (name, normalStatus, forceStatus, initialStatus = 0) => {
    const scenarioRoot = path.join(fixtureRoot, name);
    const workRoot = path.join(scenarioRoot, 'work');
    const mountpoint = path.join(workRoot, 'mounted-dmg');
    const log = path.join(scenarioRoot, 'hdiutil.log');
    fs.mkdirSync(mountpoint, { recursive: true });
    const harness = `set -euo pipefail
WORK_ROOT="$1"
DMG_MOUNTPOINT="$2"
${cleanupSource}
trap cleanup EXIT
exit ${initialStatus}
`;
    const result = spawnSync('bash', ['-c', harness, 'cleanup-test', workRoot, mountpoint], {
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${mockBin}${path.delimiter}${process.env.PATH || ''}`,
        CCBUD_TEST_HDIUTIL_LOG: log,
        CCBUD_TEST_NORMAL_STATUS: String(normalStatus),
        CCBUD_TEST_FORCE_STATUS: String(forceStatus),
      },
    });
    return {
      result,
      workRootExists: fs.existsSync(workRoot),
      calls: fs.readFileSync(log, 'utf8').trim().split('\n'),
    };
  };

  const forceRecovery = runCleanup('force-recovers', 1, 0);
  check(
    'forced detach recovery removes the work directory and preserves success',
    forceRecovery.result.status === 0
      && !forceRecovery.workRootExists
      && forceRecovery.calls.length === 2
      && forceRecovery.calls[1].startsWith('detach -force ')
  );

  const doubleFailure = runCleanup('double-failure', 1, 1);
  check(
    'double detach failure preserves the mount and changes success to failure',
    doubleFailure.result.status === 1
      && doubleFailure.workRootExists
      && doubleFailure.result.stderr.includes('preserved')
  );

  const originalFailure = runCleanup('preserve-original-status', 1, 1, 23);
  check(
    'double detach failure preserves an existing failure status',
    originalFailure.result.status === 23
      && originalFailure.workRootExists
      && originalFailure.result.stderr.includes('preserved')
  );
} finally {
  fs.rmSync(fixtureRoot, { recursive: true, force: true });
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
