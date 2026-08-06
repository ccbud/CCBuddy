'use strict';

// Renderer smoke test — loads the real index.html/popover.html in headless Chromium with a
// stubbed Tauri bridge, walks every view, and fails on any console error or page exception.
// This is what catches a broken import or a missing DOM id after a module split, which the
// static tests cannot see.
//
// Opt-in: skipped (exit 0) unless playwright-core AND a Chromium binary are available, so a
// plain `npm test` on a fresh clone never fails for a missing browser. Install with
// `npm i --no-save playwright-core` and set PLAYWRIGHT_CHROMIUM to the executable if needed.

const http = require('http');
const fs = require('fs');
const path = require('path');
const { stubScript } = require('./smoke-fixtures');

const ROOT = path.join(__dirname, '..', 'src', 'renderer');
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png' };
const PORT = 4599;
// Not ours: the browser's implicit favicon probe and the external analytics host (in Tauri
// neither request exists). Matched against request URLs.
const IGNORED = /favicon\.ico|clarity|bing/;
// Console "Failed to load resource" lines carry no URL, so they can't be filtered by origin —
// the response/requestfailed listeners below cover the same failures with a URL to judge on.
const NO_URL_NOISE = /Failed to load resource/;

function chromiumPath() {
  const explicit = process.env.PLAYWRIGHT_CHROMIUM;
  if (explicit && fs.existsSync(explicit)) return explicit;
  for (const p of ['/opt/pw-browsers/chromium', '/usr/bin/chromium', '/usr/bin/chromium-browser']) {
    if (fs.existsSync(p)) return p;
  }
  return null;
}

let pass = 0, fail = 0;
const check = (n, c, d) => {
  if (c) { pass++; console.log(`  \x1b[32mPASS\x1b[0m ${n}`); }
  else { fail++; console.log(`  \x1b[31mFAIL\x1b[0m ${n}${d ? ' — ' + d : ''}`); }
};

function serve() {
  const server = http.createServer((req, res) => {
    const file = path.join(ROOT, decodeURIComponent(req.url.split('?')[0]));
    fs.readFile(file, (err, buf) => {
      if (err) { res.writeHead(404); res.end('404'); return; }
      res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream' });
      res.end(buf);
    });
  });
  return new Promise((r) => server.listen(PORT, () => r(server)));
}

async function run(chromium, exe) {
  const server = await serve();
  const browser = await chromium.launch({ executablePath: exe });
  const errors = [];
  const watch = (p, label) => {
    p.on('console', (m) => {
      if (m.type() === 'error' && !NO_URL_NOISE.test(m.text())) errors.push(`${label} console: ${m.text()}`);
    });
    p.on('pageerror', (e) => errors.push(`${label} pageerror: ${e.message}`));
    p.on('requestfailed', (r) => { if (!IGNORED.test(r.url())) errors.push(`${label} request failed: ${r.url()}`); });
    p.on('response', (r) => { if (r.status() >= 400 && !IGNORED.test(r.url())) errors.push(`${label} HTTP ${r.status()}: ${r.url()}`); });
  };

  const page = await browser.newPage();
  watch(page, 'main');
  await page.addInitScript(stubScript());
  await page.goto(`http://127.0.0.1:${PORT}/index.html`, { waitUntil: 'networkidle' });
  await page.waitForTimeout(600);

  check('服务 renders the active provider', (await page.textContent('#heroTitle')) === 'GLM');
  check('provider list renders a row', (await page.locator('.provider').count()) === 1);
  check('i18n applied to static nodes', !!(await page.textContent('[data-i18n="nav.providers"]')));

  for (const view of ['plugins', 'monitor', 'settings', 'conversations']) {
    await page.click(`[data-view="${view}"]`);
    await page.waitForTimeout(500);
    check(`${view} view lazy-mounts and shows`, await page.locator(`#view-${view}`).isVisible());
  }

  // 会话: open the session and exercise the transcript renderer (markdown, thinking, tool card).
  await page.click('.conv-item');
  await page.waitForTimeout(900);
  check('transcript renders messages', (await page.locator('#convDetail .msg').count()) >= 2);
  check('transcript renders a tool card', (await page.locator('.tool-card').count()) >= 1);
  check('overview stats render', (await page.locator('#convStats .stat-row').count()) > 0);

  await page.click('[data-view="settings"]');
  await page.waitForTimeout(300);
  for (const pane of ['general', 'data', 'about']) {
    await page.click(`[data-settings="${pane}"]`);
    await page.waitForTimeout(250);
  }
  check('settings About shows the running version', (await page.textContent('#updVersion')) !== '—');

  await page.click('[data-view="providers"]');
  await page.waitForTimeout(350);
  await page.click('#btnAdd');
  await page.waitForTimeout(300);
  check('provider modal injects on first open', await page.locator('#modal').isVisible());
  check('preset grid renders', (await page.locator('.preset-chip').count()) > 5);
  await page.click('#btnCancel');

  const before = await page.getAttribute('html', 'data-theme');
  await page.click('#btnTheme');
  await page.waitForTimeout(200);
  check('theme toggle flips data-theme', (await page.getAttribute('html', 'data-theme')) !== before);

  const pop = await browser.newPage();
  watch(pop, 'popover');
  await pop.addInitScript(stubScript());
  await pop.goto(`http://127.0.0.1:${PORT}/popover.html`, { waitUntil: 'networkidle' });
  await pop.waitForTimeout(600);
  check('popover renders usage', (await pop.textContent('#sTokens')) !== '—');
  check('popover renders the heatmap', (await pop.locator('.hm-cell').count()) > 0);

  await browser.close();
  server.close();
  check('no console errors or page exceptions', errors.length === 0, errors.slice(0, 5).join(' | '));
}

(async () => {
  let chromium = null;
  try { ({ chromium } = require('playwright-core')); } catch (_) {}
  const exe = chromiumPath();
  if (!chromium || !exe) {
    console.log('Renderer smoke: SKIPPED (needs playwright-core + a Chromium binary)');
    process.exit(0);
  }
  console.log('Renderer smoke (headless Chromium, stubbed Tauri bridge):');
  await run(chromium, exe);
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('smoke crashed:', e); process.exit(1); });
