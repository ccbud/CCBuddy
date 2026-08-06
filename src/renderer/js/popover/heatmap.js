/* Popover activity heatmap + its instant styled tooltip. */
import { api } from '../core/bridge.js';
import { I18n } from '../core/i18n.js';
import { fmtNum } from '../core/dom.js';

const esc = (s) => String(s == null ? '' : s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function fmtDate(d) {
  try {
    const dt = new Date(`${d}T00:00:00`);
    if (isNaN(dt)) return d;
    return dt.toLocaleDateString(I18n.localeTag, { year: 'numeric', month: 'short', day: 'numeric' });
  } catch (_) { return d; }
}

// Instant, styled heatmap tooltip (replaces the slow/ugly native title).
let _tip = null;
function showHeatTip(cell) {
  if (!_tip) { _tip = document.createElement('div'); _tip.className = 'hm-tip'; document.body.appendChild(_tip); }
  _tip.innerHTML = `<div class="hm-tip-d">${esc(cell.dataset.date || '')}</div><div class="hm-tip-v">${esc(cell.dataset.val || '')}</div>`;
  _tip.classList.add('show');
  const r = cell.getBoundingClientRect();
  const tw = _tip.offsetWidth, th = _tip.offsetHeight;
  let x = Math.max(6, Math.min(r.left + r.width / 2 - tw / 2, window.innerWidth - tw - 6));
  let y = r.top - th - 7;
  if (y < 4) y = r.bottom + 7;
  _tip.style.left = `${Math.round(x)}px`;
  _tip.style.top = `${Math.round(y)}px`;
}
function hideHeatTip() { if (_tip) _tip.classList.remove('show'); }

const LEVEL_BGS = {
  0: 'bg-[#c6ccd8] dark:bg-white/14',
  1: 'bg-[#5856d6]/34 dark:bg-[#7d7aff]/32',
  2: 'bg-[#5856d6]/55 dark:bg-[#7d7aff]/54',
  3: 'bg-[#5856d6]/76 dark:bg-[#7d7aff]/76',
  4: 'bg-brand dark:bg-[#7d7aff]',
};

export async function renderHeatmap() {
  let u;
  try {
    u = await api.usageGet('all');
  } catch (e) {
    console.error('usageGet(all) failed', e);
    u = { heatmap: [] };
  }
  const hm = document.getElementById('heatmap');
  if (!hm) return;
  hm.innerHTML = '';
  if (u && u.heatmap) {
    for (const c of u.heatmap) {
      const cell = document.createElement('div');
      cell.className = `hm-cell lv${c.level} rounded-[3px] transition-colors duration-200 ${LEVEL_BGS[c.level] || LEVEL_BGS[0]}`;
      cell.dataset.date = fmtDate(c.date);
      cell.dataset.val = `${fmtNum(c.tokens)} ${I18n.t('pop.tokensUnit')}`;
      hm.appendChild(cell);
    }
  }
}

export function bindHeatmap() {
  const hm = document.getElementById('heatmap');
  if (!hm) return;
  hm.addEventListener('mouseover', (e) => { const c = e.target.closest('.hm-cell'); if (c) showHeatTip(c); });
  hm.addEventListener('mouseleave', hideHeatTip);
}
