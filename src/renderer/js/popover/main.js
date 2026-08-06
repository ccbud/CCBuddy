/* Popover window entry point (tray usage panel). Same lazy-i18n contract as the main window. */
import '../core/bridge.js';
import { $ } from '../core/dom.js';
import { api } from '../core/bridge.js';
import { I18n, detectLang } from '../core/i18n.js';
import { applyTheme } from '../core/theme.js';
import { renderHeatmap, bindHeatmap } from './heatmap.js';
import { renderStats, renderStatus } from './stats.js';

let range = '7d';
let heatmapReady = false;

async function render() {
  if (!heatmapReady) { await renderHeatmap(); heatmapReady = true; }
  await renderStats(range);
}

function setTab(t) {
  document.querySelectorAll('#popTabs .seg-btn').forEach((b) => b.classList.toggle('active', b.dataset.tab === t));
  $('tab-overview').classList.toggle('hidden', t !== 'overview');
  $('tab-models').classList.toggle('hidden', t !== 'models');
}
function setRange(r) {
  range = r;
  document.querySelectorAll('#popRanges .seg-btn').forEach((b) => b.classList.toggle('active', b.dataset.range === r));
  renderStats(range);
}

function bind() {
  $('popTabs').addEventListener('click', (e) => { if (e.target.dataset.tab) setTab(e.target.dataset.tab); });
  $('popRanges').addEventListener('click', (e) => { if (e.target.dataset.range) setRange(e.target.dataset.range); });
  $('popConnect').addEventListener('click', async (e) => {
    e.target.disabled = true;
    try { await api.gatewaySetEnabled(!e.target.dataset.running); } catch (_) {}
    e.target.disabled = false;
    renderStatus();
  });
  $('popOpen').addEventListener('click', () => api.openMain());
  $('popQuit').addEventListener('click', () => api.quitApp());
  bindHeatmap();
  if (api.onPopoverShow) {
    api.onPopoverShow(async () => {
      // The popover is a separate window: re-read theme + language from shared localStorage
      // (written by the main window) on every show, so a change propagates on next open.
      applyTheme(localStorage.getItem('ccbud-theme') || 'light');
      await applyLang();
      heatmapReady = false;
      await render();
      renderStatus();
    });
  }
}

async function applyLang() {
  await I18n.setLang(detectLang());
  I18n.apply(document);
}

(async () => {
  try { applyTheme(localStorage.getItem('ccbud-theme') || 'light'); } catch (_) { applyTheme('light'); }
  await applyLang();
  bind();
  await render();
  renderStatus();
})();
