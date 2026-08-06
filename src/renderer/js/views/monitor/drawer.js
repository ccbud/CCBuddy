/* Request inspector — full headers + body of one forwarded exchange, per-tab. */
import { $, escapeHtml, fmtTime, fmtBytes, injectIcons } from '../../core/dom.js';
import { api } from '../../core/bridge.js';
import { I18n } from '../../core/i18n.js';
import { ensureVendor } from '../../core/loader.js';
import { DRAWER_HTML } from './template.js';
import { setDrBody, drCodeEl, drNavSearch, bindDrawerSearch } from './drawer-search.js';

let reqDrawerTab = 'req';
let reqDrawerData = null;

function prettyText(cap) {
  if (!cap || !cap.text) return { text: '', lang: 'plaintext' };
  let text = cap.text, lang = 'plaintext';
  const trimmed = text.trim();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try { text = JSON.stringify(JSON.parse(trimmed), null, 2); lang = 'json'; } catch (_) {}
  }
  return { text, lang };
}
function prettyBody(cap) {
  if (!cap || !cap.text) return `<div class="dr-empty p-2.5 text-caption text-[12.5px]">${escapeHtml(I18n.t('drawer.empty'))}</div>`;
  const { text, lang } = prettyText(cap);
  const note = cap.truncated ? `<div class="dr-trunc text-[11.5px] text-amber mb-1.5">${escapeHtml(I18n.t('drawer.truncated', { shown: fmtBytes(cap.bytes - cap.truncated), total: fmtBytes(cap.bytes) }))}</div>` : '';
  return note + `<pre class="dr-pre bg-[#f6f8fa] dark:bg-[#0c0e12] text-[#24292e] dark:text-[#e8edf4] border border-border-custom dark:border-white/8 rounded-sm p-3 overflow-x-auto text-xs leading-[1.55] max-h-[62vh]"><code class="language-${lang}">${escapeHtml(text)}</code></pre>`;
}
function kvTable(h) {
  const keys = Object.keys(h || {});
  if (!keys.length) return `<div class="dr-empty p-2.5 text-caption text-[12.5px]">${escapeHtml(I18n.t('drawer.none'))}</div>`;
  return '<div class="dr-kv border border-border-custom rounded-sm overflow-hidden">' + keys.map((k) => `<div class="dr-kv-row flex gap-2.5 py-1.5 px-2.5 font-mono text-xs odd:bg-transparent even:bg-chip-bg"><span class="dr-k text-brand shrink-0 min-w-[150px] break-all">${escapeHtml(k)}</span><span class="dr-v text-fg break-all">${escapeHtml(Array.isArray(h[k]) ? h[k].join(', ') : h[k])}</span></div>`).join('') + '</div>';
}

// A translated exchange (client wire ≠ provider wire) exposes all four sides; passthrough keeps
// the classic two. Each tab resolves to { headers, cap, isReq, sub } for the shared body renderer:
//   creq — what the gateway RECEIVED from the client (inbound URL/headers/original body)
//   req  — what the gateway SENT upstream (real upstream URL/headers/translated body)
//   ures — what the upstream RETURNED (raw, pre-translation)
//   res  — what the gateway RETURNED to the client (translated)
function drawerTabView(d, tab) {
  const creq = d.clientReq || {};
  const ures = d.upstreamRes || {};
  switch (tab) {
    case 'creq':
      return { headers: creq.headers, cap: creq.body || d.reqBody, isReq: true, sub: `${d.method || 'POST'} ${creq.url || d.path || ''}` };
    case 'ures':
      return { headers: ures.headers, cap: ures.body, isReq: false, sub: `HTTP ${ures.status != null ? ures.status : d.status || ''}` };
    case 'res':
      return { headers: d.resHeaders, cap: d.resBody, isReq: false, sub: `HTTP ${d.status || ''}` };
    default: // 'req'
      return { headers: d.reqHeaders, cap: d.reqBody, isReq: true, sub: `${d.method || 'POST'} ${d.url || d.path || ''}` };
  }
}
function drawerTabs(d) {
  return d && d.translated
    ? [['creq', I18n.t('drawer.tabClientReq')], ['req', I18n.t('drawer.tabUpstreamReq')],
       ['ures', I18n.t('drawer.tabUpstreamRes')], ['res', I18n.t('drawer.tabClientRes')]]
    : [['req', I18n.t('drawer.req')], ['res', I18n.t('drawer.res')]];
}
const DR_TAB_CLS = 'dr-tab border-none bg-transparent text-muted font-semibold text-[13px] leading-none p-[8px_14px] rounded-t-md cursor-pointer border-b-2 border-transparent -mb-[1px] hover:text-fg [&.active]:text-brand [&.active]:border-b-brand';
function renderDrawerTabs() {
  const wrap = $('drTabs');
  if (!wrap) return;
  wrap.innerHTML = drawerTabs(reqDrawerData)
    .map(([k, label]) => `<button class="${DR_TAB_CLS}${k === reqDrawerTab ? ' active' : ''}" data-tab="${k}">${escapeHtml(label)}</button>`)
    .join('');
}

function renderReqDrawerBody() {
  const d = reqDrawerData;
  if (!d) return;
  const body = $('reqDrawerBody');
  const view = drawerTabView(d, reqDrawerTab);
  const { isReq, headers, cap } = view;
  const which = reqDrawerTab;
  const copyLabel = cap && cap.truncated ? I18n.t('drawer.copyPartial') : I18n.t('drawer.copy');
  const headTitle = `${escapeHtml(I18n.t(isReq ? 'drawer.reqHeaders' : 'drawer.resHeaders'))} <span class="dr-sub font-medium font-mono text-caption normal-case tracking-normal truncate">${escapeHtml(view.sub)}</span>`;
  const bodyText = prettyText(cap).text;
  const searchBar = bodyText ? `<span class="flex-1"></span><div class="dr-search-wrap flex items-center gap-1 normal-case tracking-normal">
    <input class="dr-search w-[140px] bg-bg-input border border-border-custom rounded-md px-2 py-1 text-[11px] font-normal text-fg outline-none focus:border-primary" type="text" placeholder="${escapeHtml(I18n.t('drawer.searchBody'))}" />
    <span class="dr-search-count text-caption text-[10px] font-normal tabular-nums min-w-[36px] text-center">0/0</span>
    <button class="dr-search-prev tool-btn w-[22px] h-[22px] border border-border-custom rounded-[5px] bg-bg-elev text-muted cursor-pointer inline-flex items-center justify-center text-[11px] hover:text-fg hover:bg-chip-bg hover:border-border-strong" title="${escapeHtml(I18n.t('drawer.searchPrev'))}">↑</button>
    <button class="dr-search-next tool-btn w-[22px] h-[22px] border border-border-custom rounded-[5px] bg-bg-elev text-muted cursor-pointer inline-flex items-center justify-center text-[11px] hover:text-fg hover:bg-chip-bg hover:border-border-strong" title="${escapeHtml(I18n.t('drawer.searchNext'))}">↓</button>
  </div>` : '';
  const copyCls = bodyText ? '' : 'ml-auto ';
  body.innerHTML = `<div class="dr-section-title flex items-center gap-2 text-xs font-bold text-fg my-4 mt-4 mb-2 uppercase tracking-wide">${headTitle}</div>${kvTable(headers)}<div class="dr-section-title flex items-center gap-2 text-xs font-bold text-fg my-4 mt-4 mb-2 uppercase tracking-wide">${escapeHtml(isReq ? I18n.t('drawer.reqBody') : I18n.t('drawer.resBody'))}${searchBar}<button class="btn btn-sm dr-copy ${copyCls}bg-bg-elev text-fg border border-border-custom rounded-[6px] px-2.25 py-1 text-[11px] font-medium normal-case tracking-normal cursor-pointer transition-all duration-150 hover:bg-chip-bg hover:border-border-strong active:scale-[0.98]" data-copy-body="${which}" title="${escapeHtml(I18n.t('drawer.copy'))}">${escapeHtml(copyLabel)}</button></div>${prettyBody(cap)}`;
  // Skip syntax highlighting on very large bodies — hljs on multi-MB text freezes the UI.
  body.querySelectorAll('pre code').forEach((b) => { if (b.textContent.length > 100000) return; try { if (window.hljs) window.hljs.highlightElement(b); } catch (_) {} });
  const codeEl = drCodeEl();
  setDrBody(bodyText, codeEl ? codeEl.innerHTML : '');
}

export async function openReqDetail(id) {
  ensureDrawer();
  // Highlighting is optional but nice — load the vendor bundle lazily, tolerate failure.
  try { await ensureVendor(); } catch (_) {}
  let d = null;
  try { d = await api.monitorGet(id); } catch (_) {}
  if (!d) {
    // Entry rolled out of the bounded capture buffer — give feedback instead of a stale drawer.
    reqDrawerData = null;
    $('drMethod').textContent = '—';
    const drStatus = $('drStatus');
    if (drStatus) {
      drStatus.textContent = '';
      drStatus.classList.remove('ok', 'err');
    }
    $('drModel').textContent = '';
    $('reqMeta').innerHTML = '';
    $('reqDrawerBody').innerHTML = `<div class="dr-empty p-2.5 text-caption text-[12.5px]">${escapeHtml(I18n.t('drawer.expired'))}</div>`;
    $('reqDrawer').classList.remove('hidden');
    return;
  }
  // Translated exchanges open on the client request (what the gateway received) so the
  // before/after of the translation reads left-to-right across the tabs.
  reqDrawerData = d; reqDrawerTab = d.translated ? 'creq' : 'req';
  const ok = d.status >= 200 && d.status < 400;
  $('drMethod').textContent = d.method || 'POST';
  const drStatus = $('drStatus');
  if (drStatus) {
    drStatus.textContent = d.status != null ? d.status : '—';
    drStatus.classList.toggle('ok', ok);
    drStatus.classList.toggle('err', !ok);
  }
  $('drModel').innerHTML = `${escapeHtml(d.requestedModel || '-')} <span class="arrow">→</span> ${escapeHtml(d.outgoingModel || '-')}${d.rewritten ? ` <span class="rewrite" title="${escapeHtml(I18n.t('drawer.rewritten'))}">✎</span>` : ''}`;
  const meta = [
    [I18n.t('drawer.service'), d.provider],
    d.translated ? [I18n.t('drawer.translated'), d.translated] : null,
    d.aborted ? [I18n.t('drawer.aborted'), I18n.t('drawer.abortedVal')] : null,
    [I18n.t('drawer.latency'), d.ms != null ? d.ms + ' ms' : ''],
    [I18n.t('drawer.session'), d.sessionId ? String(d.sessionId).slice(0, 8) : ''],
    d.agentId ? [I18n.t('drawer.agent'), I18n.t('drawer.subagent')] : null,
    [I18n.t('drawer.time'), d.ts ? fmtTime(d.ts) : ''],
    d.error ? [I18n.t('drawer.error'), d.error] : null,
  ].filter((r) => r && r[1]);
  $('reqMeta').innerHTML = meta.map((r) => `<span class="dr-chip text-[11.5px] px-2.25 py-[2.5px] rounded-full bg-chip-bg text-fg"><span class="muted text-muted">${escapeHtml(r[0])}</span> ${escapeHtml(r[1])}</span>`).join('');
  renderDrawerTabs();
  renderReqDrawerBody();
  $('reqDrawer').classList.remove('hidden');
}

export function closeReqDrawer() { const d = $('reqDrawer'); if (d) d.classList.add('hidden'); reqDrawerData = null; }

let drawerBound = false;
function ensureDrawer() {
  if ($('reqDrawer')) return;
  document.body.insertAdjacentHTML('beforeend', DRAWER_HTML);
  I18n.apply($('reqDrawer'));
  injectIcons($('reqDrawer'));
  if (drawerBound) return;
  drawerBound = true;
  $('reqDrawerClose').addEventListener('click', closeReqDrawer);
  const reqDrawer = $('reqDrawer');
  reqDrawer.addEventListener('click', (e) => { if (e.target === reqDrawer) closeReqDrawer(); });
  // Tabs are re-rendered per exchange (2 or 4 of them) — delegate on the container.
  $('drTabs').addEventListener('click', (e) => {
    const t = e.target.closest('.dr-tab');
    if (!t) return;
    reqDrawerTab = t.dataset.tab;
    $('drTabs').querySelectorAll('.dr-tab').forEach((x) => x.classList.toggle('active', x === t));
    renderReqDrawerBody();
  });
  const reqDrawerBody = $('reqDrawerBody');
  reqDrawerBody.addEventListener('click', (e) => {
    if (e.target.closest('.dr-search-prev')) { drNavSearch(-1); return; }
    if (e.target.closest('.dr-search-next')) { drNavSearch(1); return; }
    const cb = e.target.closest('[data-copy-body]');
    if (cb && reqDrawerData) {
      const cap = drawerTabView(reqDrawerData, cb.dataset.copyBody).cap;
      api.copy((cap && cap.text) || '');
      cb.textContent = I18n.t('copy.copied'); setTimeout(() => { cb.textContent = I18n.t('drawer.copy'); }, 1200);
    }
  });
  bindDrawerSearch(reqDrawerBody);
  document.addEventListener('keydown', (e) => {
    const dr = $('reqDrawer');
    if (e.key === 'Escape' && dr && !dr.classList.contains('hidden')) closeReqDrawer();
  });
}
