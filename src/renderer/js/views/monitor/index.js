/* 监控 view — metrics, request stream, gateway log. Mounted lazily on first switch. */
import { $, escapeHtml, fmtTime, injectIcons } from '../../core/dom.js';
import { api } from '../../core/bridge.js';
import { I18n } from '../../core/i18n.js';
import { state, activeProvider, onRender, onLocalLog } from '../../core/state.js';
import { scheduleHeroUsage } from '../providers/hero.js';
import { MONITOR_HTML } from './template.js';
import { attachMonitorSinks } from './feed.js';
import { pushRawLog, renderGwLogStatus, renderGatewayLog, refreshGatewayLog, gwLog } from './log.js';
import { openReqDetail, closeReqDrawer } from './drawer.js';

function renderMonitor() {
  $('mStatusText').textContent = state.status.connected ? I18n.t('status.connected') : state.status.running ? I18n.t('status.running') : I18n.t('status.disconnected');
  const dot = $('mStatus').querySelector('.pulse-dot, .live-dot');
  if (dot) {
    const isLive = !!(state.status.connected || state.status.running);
    dot.classList.toggle('on', isLive);
    dot.classList.toggle('off', !isLive);
  }
  $('mEndpoint').textContent = `localhost:${(state.status.running && state.status.port) || state.config.port}`;
  const ap = activeProvider();
  $('mActive').textContent = ap ? ap.name : '—';
  $('mActiveUrl').textContent = ap ? ap.baseUrl : I18n.t('monitor.noService');
  $('mTotal').textContent = state.stats.total;
  $('mSuccess').textContent = state.stats.total ? I18n.t('monitor.successRate', { pct: Math.round((state.stats.ok / state.stats.total) * 100) }) : I18n.t('monitor.successRateNone');
  $('mAvg').innerHTML = state.stats.total ? `${Math.round(state.stats.sumMs / state.stats.total)} <span class="unit">ms</span>` : `— <span class="unit">ms</span>`;
  $('mLast').textContent = state.stats.last ? I18n.t('monitor.recent', { time: state.stats.last }) : I18n.t('monitor.recentNone');
  renderGwLogStatus();
}

// Stats already accumulated by the boot-time feed (see feed.js) — this only paints the row.
function pushStreamRow(r) {
  renderMonitor();
  $('streamHint').textContent = I18n.t('monitor.forwarded', { n: state.stats.total });
  const list = $('streamList');
  const empty = list.querySelector('.state-inline, .empty');
  if (empty) empty.remove();
  const okCls = r.status >= 200 && r.status < 400 ? 'ok' : 'err';
  const row = document.createElement('div');
  row.className = 'stream-row flex items-center gap-2.5 py-2.25 px-3.5 border-b border-border-custom text-[11.5px] transition-colors duration-100 hover:bg-chip-bg last:border-b-0 [&.clickable]:cursor-pointer';
  if (r.id != null) { row.dataset.id = r.id; row.classList.add('clickable'); row.title = I18n.t('monitor.rowTitle'); }
  const agentTag = r.agentId ? `<span class="agent-tag sub text-[9px] font-bold px-1 py-0.25 rounded-[4px] leading-[1.2] shrink-0 text-muted bg-chip-bg border border-border-custom" title="${escapeHtml(I18n.t('monitor.subReq'))}">sub</span>` : '';
  row.innerHTML = `
    <span class="sdot w-1.5 h-1.5 rounded-full shrink-0 [&.ok]:bg-green [&.err]:bg-red ${okCls}"></span>
    <span class="method font-mono text-[10px] text-caption w-10">${escapeHtml(r.method || '')}</span>
    ${agentTag}
    <span class="models flex-1 min-w-0 font-mono text-[11px] flex items-center gap-1.25 overflow-hidden">
      <span class="req text-fg truncate" title="HTTP body.model">${escapeHtml(r.requestedModel || '-')}</span>
      <span class="arrow text-brand opacity-55">→</span>
      <span class="out text-muted truncate" title="${escapeHtml(I18n.t('monitor.upstreamModel'))}">${escapeHtml(r.outgoingModel || '-')}</span>
      ${r.rewritten ? `<span class="rewrite text-brand text-[10px]" title="${escapeHtml(I18n.t('monitor.rewriteTitle'))}">✎</span>` : ''}
    </span>
    <span class="prov text-caption text-[11px] max-w-[100px] truncate">${escapeHtml(r.provider || '')}</span>
    <span class="code font-mono font-semibold w-8.5 text-right [&.ok]:text-green [&.err]:text-red ${okCls}">${r.status}</span>
    <span class="ms font-mono text-caption w-12 text-right">${r.ms}ms</span>
    <span class="ts font-mono text-caption text-[10px] w-14 text-right">${fmtTime()}</span>`;
  list.insertBefore(row, list.firstChild);
  // Live window only — keep the last 100 rows (matches the backend's exchange-detail buffer).
  while (list.children.length > 100) list.removeChild(list.lastChild);
  scheduleHeroUsage();
}

function clearLog() {
  $('streamList').innerHTML = `<div class="state-inline p-4 text-center text-[11.5px] text-caption">${escapeHtml(I18n.t('monitor.streamEmpty'))}</div>`;
  gwLog.items.length = 0; gwLog.seen.clear();
  renderGatewayLog();
  state.stats.total = state.stats.ok = state.stats.sumMs = 0; state.stats.last = null;
  $('streamHint').textContent = I18n.t('monitor.waitingDots');
  renderMonitor();
  if (api.monitorClear) api.monitorClear();
  if (api.logsClear) api.logsClear();
  closeReqDrawer();
}

export default {
  id: 'monitor',
  mount(host) {
    host.insertAdjacentHTML('beforeend', MONITOR_HTML);
    const section = $('view-monitor');
    I18n.apply(section);
    injectIcons(section);
    $('btnClearLog').addEventListener('click', clearLog);
    // Request inspector: click a stream row to open its full captured exchange.
    $('streamList').addEventListener('click', (e) => {
      const row = e.target.closest('.stream-row');
      if (row && row.dataset.id) openReqDetail(row.dataset.id);
    });
    attachMonitorSinks((r) => pushStreamRow(r), (l) => pushRawLog(l));
    onLocalLog((l) => pushRawLog(l));
    onRender(renderMonitor);
    renderMonitor();
  },
  onShow() { refreshGatewayLog(); },
};
