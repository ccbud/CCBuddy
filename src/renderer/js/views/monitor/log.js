/* Gateway log panel — lifecycle + error events, backfilled from the backend's ring buffer. */
import { $, escapeHtml, fmtTime } from '../../core/dom.js';
import { api } from '../../core/bridge.js';
import { I18n } from '../../core/i18n.js';
import { state } from '../../core/state.js';

export const gwLog = { seen: new Set(), items: [] };

// Add an entry to the local model. Live/replayed entries carry a `seq` (deduped); local renderer
// notices (provider test, save error, …) have none and are always appended.
export function addGatewayLog(l) {
  if (!l) return false;
  if (l.seq != null) {
    if (gwLog.seen.has(l.seq)) return false;
    gwLog.seen.add(l.seq);
  }
  if (l.ts == null) l.ts = Date.now();
  gwLog.items.push(l);
  while (gwLog.items.length > 100) gwLog.items.shift();
  return true;
}

export function renderGwLogStatus() {
  const el = $('gwLogStatus');
  if (!el) return;
  const running = !!(state.status.connected || state.status.running);
  const port = (state.status.running && state.status.port) || state.config.port;
  el.className = 'raw-log-badge ml-auto ' + (running ? 'on' : 'off');
  el.innerHTML = `<span class="rl-dot"></span>${escapeHtml(I18n.t(running ? 'monitor.gwRunning' : 'monitor.gwStopped'))} · localhost:${escapeHtml(String(port))}`;
}

export function renderGatewayLog() {
  const el = $('rawLog');
  if (!el) return;
  if (!gwLog.items.length) {
    el.innerHTML = `<div class="raw-log-empty">${escapeHtml(I18n.t('monitor.logEmpty'))}</div>`;
    return;
  }
  const rows = gwLog.items.slice().sort((a, b) => (a.ts || 0) - (b.ts || 0)).reverse();
  el.innerHTML = rows.map((l) => {
    const lv = String(l.level || 'info');
    const t = fmtTime(l.ts);
    return `<div class="raw-log-line lv-${escapeHtml(lv)}"><span class="rl-lv">${escapeHtml(lv)}</span><span class="rl-msg">${escapeHtml(l.msg || '')}</span><span class="rl-t">${escapeHtml(t)}</span></div>`;
  }).join('');
}

export function pushRawLog(l) { if (addGatewayLog(l)) renderGatewayLog(); }

// Backfill from the backend ring buffer (events fire once and aren't otherwise replayed) + refresh banner.
export async function refreshGatewayLog() {
  if (api.logsGet) {
    try { ((await api.logsGet()) || []).forEach(addGatewayLog); } catch (_) {}
  }
  renderGwLogStatus();
  renderGatewayLog();
}
