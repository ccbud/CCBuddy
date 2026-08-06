/* Popover overview tiles + per-model usage bars. */
import { api } from '../core/bridge.js';
import { I18n } from '../core/i18n.js';
import { $, fmtNum, escapeHtml } from '../core/dom.js';

function hourLabel(h) {
  if (h == null) return '—';
  try { return new Date(2000, 0, 1, h).toLocaleTimeString(I18n.localeTag, { hour: 'numeric' }); }
  catch (_) { const ap = h < 12 ? 'AM' : 'PM'; const hh = h % 12 === 0 ? 12 : h % 12; return `${hh} ${ap}`; }
}

/** Set a tile's text and mirror the full value into the parent's tooltip when truncated. */
function setTile(id, value, full) {
  const el = $(id);
  if (!el) return;
  el.textContent = value;
  if (el.parentElement) {
    if (full) el.parentElement.setAttribute('data-tip', full);
    else el.parentElement.removeAttribute('data-tip');
  }
}

export async function renderStats(range) {
  let u = null;
  try { u = await api.usageGet(range); } catch (e) { console.error('usageGet failed', e); }
  if (!u) {
    // a failed scan must LOOK failed — zeros would read as "no usage"
    $('sTokens').textContent = '—';
    $('sReq').textContent = '—';
    return;
  }
  $('sTokens').textContent = fmtNum(u.tokens);
  $('sReq').textContent = (u.requests || 0).toLocaleString();
  $('sDays').textContent = u.activeDays || 0;
  setTile('sProv', u.favoriteProvider || '—', u.favoriteProvider && u.favoriteProvider !== '—' ? u.favoriteProvider : '');
  $('sCur').innerHTML = `${u.currentStreak || 0}<span class="text-[10px] text-muted font-normal ml-0.5">${escapeHtml(I18n.t('time.unitDay'))}</span>`;
  $('sLong').innerHTML = `${u.longestStreak || 0}<span class="text-[10px] text-muted font-normal ml-0.5">${escapeHtml(I18n.t('time.unitDay'))}</span>`;
  $('sPeak').textContent = u.peakHour == null ? '—' : hourLabel(u.peakHour);
  setTile('sModel', u.favoriteModel || '—', u.favoriteModel && u.favoriteModel !== '—' ? u.favoriteModel : '');

  const ml = $('modelList');
  if (!ml) return;
  ml.innerHTML = '';
  const byModel = u.byModel || [];
  if (!byModel.length) ml.innerHTML = `<div class="empty small text-center text-xs text-muted leading-relaxed py-4">${escapeHtml(I18n.t('pop.noData'))}</div>`;
  for (const m of byModel.slice(0, 12)) {
    const row = document.createElement('div');
    row.className = 'model-row flex items-center gap-2';
    row.innerHTML = `
        <div class="model-name w-[120px] text-[11px] font-mono truncate text-fg" title="${escapeHtml(m.model)}">${escapeHtml(m.model)}</div>
        <div class="model-bar flex-1 h-[5px] bg-chip-bg rounded-[3px] overflow-hidden"><div class="model-bar-fill h-full bg-brand" style="width:${Math.max(2, Math.round((m.pct || 0) * 100))}%"></div></div>
        <div class="model-tok mono w-11 text-right text-[10px] text-caption font-mono">${fmtNum(m.tokens)}</div>`;
    ml.appendChild(row);
  }
}

export async function renderStatus() {
  const s = await api.serverStatus();
  const dot = $('popStatus').querySelector('.pulse-dot, .live-dot');
  dot.className = 'pulse-dot w-1.75 h-1.75 rounded-full shrink-0 ' + (s.running ? 'on bg-green animate-[pulse_2s_infinite]' : 'off bg-muted');
  $('popStatusText').textContent = s.running ? I18n.t('status.gwRunning') : I18n.t('status.gwStopped');
  $('popConnect').textContent = s.running ? I18n.t('pop.svcStop') : I18n.t('pop.svcStart');
  $('popConnect').dataset.running = s.running ? '1' : '';
}
