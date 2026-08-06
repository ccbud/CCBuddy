'use strict';

// Enforces the repo's module-size rule: no source file may exceed MAX_LINES. Small files keep
// each module single-purpose and reviewable; the limit is what stops the slow slide back to
// thousand-line files. Generated/vendored artifacts and lockfiles are exempt.

const fs = require('fs');
const path = require('path');

const MAX_LINES = 220;
const ROOT = path.join(__dirname, '..');
const ROOTS = ['src', 'src-tauri/src', 'scripts', 'build', 'test'];
const EXTS = new Set(['.js', '.mjs', '.cjs', '.rs', '.css', '.html']);
// Vendored bundles, generated CSS and synced copies are not hand-maintained source.
const EXEMPT = [
  /^src\/renderer\/vendor\//,
  /^src\/renderer\/shared\//,
  /^src\/renderer\/styles\.css$/,
];

let pass = 0, fail = 0;
const check = (n, c, d) => {
  if (c) { pass++; console.log(`  \x1b[32mPASS\x1b[0m ${n}`); }
  else { fail++; console.log(`  \x1b[31mFAIL\x1b[0m ${n}${d ? ' — ' + d : ''}`); }
};

function walk(dir, out) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return out; }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) { if (e.name !== 'node_modules' && e.name !== 'target') walk(full, out); }
    else if (EXTS.has(path.extname(e.name))) out.push(full);
  }
  return out;
}

const files = [];
ROOTS.forEach((r) => walk(path.join(ROOT, r), files));
const offenders = files
  .map((f) => ({ rel: path.relative(ROOT, f).split(path.sep).join('/'), lines: fs.readFileSync(f, 'utf8').split('\n').length }))
  .filter((f) => !EXEMPT.some((re) => re.test(f.rel)))
  .filter((f) => f.lines > MAX_LINES)
  .sort((a, b) => b.lines - a.lines);

console.log(`File size (max ${MAX_LINES} lines) — scanned ${files.length} files:`);
check(
  `no source file exceeds ${MAX_LINES} lines`,
  offenders.length === 0,
  offenders.map((f) => `${f.rel}:${f.lines}`).join(', ')
);

module.exports = { pass, fail };
if (require.main === module) {
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
}
