'use strict';

// JS test entry (`npm test`). The gateway, history, usage and export engines live in Rust now —
// `cargo test` (run in src-tauri) is their suite. What remains on this side is the shared i18n
// dictionary, the repo-wide source-size rule, and a browser smoke test of the renderer
// (self-skipping when no Chromium is available).

const { spawnSync } = require('child_process');
const path = require('path');

const SUITES = [
  'i18n.test.js',
  'file-size.test.js',
  'release-package-cleanup.test.js',
  'release-pipeline.test.js',
  'release-selfcheck-mode.test.js',
  'smoke.test.js',
];
let failed = 0;

for (const s of SUITES) {
  console.log(`\n\x1b[1m${s}\x1b[0m`);
  const r = spawnSync(process.execPath, [path.join(__dirname, s)], { stdio: 'inherit' });
  if (r.status !== 0) failed++;
}

console.log(failed ? `\n\x1b[31m${failed} suite(s) failed\x1b[0m` : '\n\x1b[32mAll suites passed\x1b[0m');
process.exit(failed ? 1 : 0);
