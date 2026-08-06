/* Hero card (gateway service state + usage summary) and the sidebar status pill. */
import { $, fmtNum, sparkSVG, escapeHtml } from '../../core/dom.js';
import { api } from '../../core/bridge.js';
import { I18n } from '../../core/i18n.js';
import { icons } from '../../core/icons.js';
import { state, activeProvider, refresh } from '../../core/state.js';
import { renderProviderIcon } from './icon.js';

export function showHeroNote(text, warn) {
  const n = $('heroNote');
  if (n) {
    n.textContent = text;
    n.classList.remove('hidden');
    n.classList.toggle('warn', !!warn);
  }
}
export function hideHeroNote() {
  const n = $('heroNote');
  if (n) n.classList.add('hidden');
}

let heroRange = '30d';
export async function renderHeroUsage() {
  const wrap = $('heroUsage');
  if (!wrap || !api.usageGet) return;
  let u; try { u = await api.usageGet(heroRange); } catch (_) { return; }
  if (!u) return;
  const port = (state.status.running && state.status.port) || state.config.port;
  const ep = $('heroEndpointText'); if (ep) ep.textContent = `localhost:${port}`;
  // a11y: the button's accessible name must contain its visible text (localhost:port).
  const epBtn = $('heroEndpoint'); if (epBtn) epBtn.setAttribute('aria-label', `localhost:${port} · ${I18n.t('hero.copyEndpoint')}`);
  const tk = $('heroTokens'); if (tk) tk.textContent = fmtNum(u.tokens || 0);
  const rq = $('heroReqs'); if (rq) rq.textContent = I18n.t('hero.reqsN', { n: (u.requests || 0).toLocaleString() });
  const md = $('heroModel'); if (md) md.textContent = u.favoriteModel && u.favoriteModel !== '—' ? `· ${u.favoriteModel}` : '';
  const days = heroRange === '7d' ? 7 : heroRange === '30d' ? 30 : 90;
  const series = (u.heatmap || []).slice(-days).map((c) => c.tokens || 0);
  const sp = $('heroSpark'); if (sp) sp.innerHTML = sparkSVG(series);
}

let _heroUsageT = null;
/** Debounced refresh after monitor traffic — keeps the spark current while requests stream. */
export function scheduleHeroUsage() {
  clearTimeout(_heroUsageT);
  _heroUsageT = setTimeout(() => {
    const w = $('heroUsage');
    if (state.status.connected && w && !w.classList.contains('hidden')) renderHeroUsage();
  }, 2500);
}

// Hero state = the gateway SERVICE (running/stopped). The button stays the config-file action
// ("一键接入"/"断开" writes or restores the CLIs' configs) — independent of the service switch.
export function renderHero() {
  const hero = $('hero');
  const ap = activeProvider();
  $('btnConnect').textContent = I18n.t(state.status.running ? 'hero.stopSvc' : 'hero.startSvc');
  if (state.status.running) {
    hero.classList.add('connected');
    const icon = $('heroIcon');
    if (ap) { const pi = renderProviderIcon(ap.name, ap.icon); icon.setAttribute('style', pi.style || ''); icon.innerHTML = pi.html; }
    else { icon.removeAttribute('style'); icon.innerHTML = icons.connected || ''; }
    $('heroTitle').textContent = ap ? ap.name : I18n.t('hero.running');
    $('heroSub').innerHTML = ap ? I18n.t('hero.connectedVia', { name: escapeHtml(ap.name) }) : I18n.t('hero.running');
    hideHeroNote();
    $('heroUsage').classList.remove('hidden');
    renderHeroUsage();
  } else {
    hero.classList.remove('connected');
    const icon = $('heroIcon');
    icon.removeAttribute('style');
    icon.innerHTML = icons.connect || '';
    $('heroTitle').textContent = I18n.t('hero.titleIdle');
    $('heroSub').textContent = I18n.t('hero.subIdle');
    hideHeroNote();
    $('heroUsage').classList.add('hidden');
  }
}

/** Sidebar status pill + brand-title tint. */
export function renderStatus() {
  const chip = $('statusPill');
  if (chip) {
    chip.classList.toggle('on', !!state.status.running);
    const txt = chip.querySelector('.status-text');
    if (txt) txt.textContent = I18n.t(state.status.running ? 'status.gwRunning' : 'status.gwStopped');
    const bt = $('brandTitle');
    if (bt) bt.classList.toggle('running', !!state.status.running);
  }
}

/** Hero button + endpoint/ranges wiring. Called once from the providers view mount. */
export function bindHero() {
  $('btnConnect').addEventListener('click', async () => {
    const btn = $('btnConnect');
    const on = !state.status.running;
    btn.disabled = true;
    let res;
    try { res = await api.gatewaySetEnabled(on); } catch (_) { res = null; }
    btn.disabled = false;
    await refresh();
    if (res && res.ok === false) showHeroNote(res.message || I18n.t('err.opFailed'), true);
  });
  const heroRanges = $('heroRanges');
  if (heroRanges) heroRanges.addEventListener('click', (e) => {
    const b = e.target.closest('[data-hrange]');
    if (!b) return;
    heroRange = b.dataset.hrange;
    heroRanges.querySelectorAll('.seg-btn').forEach((x) => x.classList.toggle('active', x === b));
    renderHeroUsage();
  });
  const heroEndpoint = $('heroEndpoint');
  if (heroEndpoint) heroEndpoint.addEventListener('click', () => {
    const port = (state.status.running && state.status.port) || state.config.port;
    if (api.copy) api.copy(`http://localhost:${port}`);
    const t = $('heroEndpointText');
    if (t) { const restore = `localhost:${port}`; t.textContent = I18n.t('copy.copiedCheck'); clearTimeout(t._t); t._t = setTimeout(() => { t.textContent = restore; }, 1400); }
  });
}
