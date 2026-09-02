'use strict';

// Runs the packaged self-check launcher against a tiny fake app. The fake process stops before
// macOS-only report inspection, allowing this argument and environment contract to run on Linux.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const launcher = path.join(ROOT, 'native/Scripts/run-packaged-selfcheck.sh');
const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ccbud-selfcheck-mode-'));
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
  const app = path.join(fixtureRoot, 'CC Buddy.app');
  const executable = path.join(app, 'Contents', 'MacOS', 'CC Buddy');
  const mockBin = path.join(fixtureRoot, 'bin');
  const mockJq = path.join(mockBin, 'jq');
  fs.mkdirSync(path.dirname(executable), { recursive: true });
  fs.mkdirSync(mockBin);
  fs.writeFileSync(
    executable,
    '#!/usr/bin/env bash\nprintf %s "${CCBUD_SELFCHECK_BIFROST_MODE:-missing}" > "$CCBUD_TEST_MODE_CAPTURE"\nexit 7\n'
  );
  fs.writeFileSync(mockJq, '#!/usr/bin/env bash\nexit 0\n');
  fs.chmodSync(executable, 0o755);
  fs.chmodSync(mockJq, 0o755);

  const invoke = (args, captureName) => {
    const capture = path.join(fixtureRoot, captureName);
    const result = spawnSync('bash', [launcher, app, '5', ...args], {
      encoding: 'utf8',
      timeout: 10_000,
      env: {
        ...process.env,
        PATH: `${mockBin}${path.delimiter}${process.env.PATH || ''}`,
        CCBUD_TEST_MODE_CAPTURE: capture,
        CCBUD_SELFCHECK_BIFROST_MODE: 'ambient-value-must-not-win',
      },
    });
    return {
      result,
      captured: fs.existsSync(capture) ? fs.readFileSync(capture, 'utf8') : null,
    };
  };

  const missing = invoke([], 'missing');
  check(
    'missing mode is rejected before app launch',
    missing.result.status === 1
      && missing.result.stderr.includes('Bifrost verification mode must be raw or developer-id')
      && missing.captured === null
  );
  const invalid = invoke(['signed'], 'invalid');
  check(
    'unknown mode is rejected before app launch',
    invalid.result.status === 1
      && invalid.result.stderr.includes('Bifrost verification mode must be raw or developer-id')
      && invalid.captured === null
  );
  for (const mode of ['raw', 'developer-id']) {
    const invocation = invoke([mode], `accepted-${mode}`);
    check(
      `${mode} mode is forwarded unchanged`,
      invocation.result.status === 1
        && invocation.result.stderr.includes('app exited 7')
        && invocation.captured === mode
    );
  }
} finally {
  fs.rmSync(fixtureRoot, { recursive: true, force: true });
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
