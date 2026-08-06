/*
 * Shared app state — the one place config/status live, plus the render fan-out.
 * View modules register a render callback; renderAll() invokes only what is mounted,
 * so lazily-mounted views never receive renders before their DOM exists.
 */
import { api } from './bridge.js';
import { I18n } from './i18n.js';

export const state = {
  config: { port: 8788, activeProviderId: null, providers: [] },
  status: { running: false, port: null, connected: false, lastStartError: null, claudePath: '' },
  stats: { total: 0, ok: 0, sumMs: 0, last: null },
};

export const activeProvider = () =>
  state.config.providers.find((p) => p.id === state.config.activeProviderId) || null;

const renderers = new Set();
/** Register a mounted view's render function; returns an unsubscribe. */
export function onRender(fn) {
  renderers.add(fn);
  return () => renderers.delete(fn);
}
export function renderAll() {
  renderers.forEach((fn) => { try { fn(); } catch (e) { console.error('[ccbud] render failed', e); } });
}

const logHandlers = new Set();
const pendingLogs = []; // buffered until the (lazily-mounted) 监控 view registers
/** The monitor view registers here to receive locally-generated log lines. */
export function onLocalLog(fn) {
  logHandlers.add(fn);
  pendingLogs.splice(0).forEach((l) => { try { fn(l); } catch (_) {} });
}
/** Record a renderer-side notice (save error, provider test, staged update, …). */
export function pushLocalLog(l) {
  if (!logHandlers.size) {
    pendingLogs.push(l);
    while (pendingLogs.length > 100) pendingLogs.shift();
    return;
  }
  logHandlers.forEach((fn) => { try { fn(l); } catch (_) {} });
}

/** Re-pull config + status from the backend and re-render every mounted view. */
export async function refresh() {
  state.config = await api.getConfig();
  state.status = await api.serverStatus();
  // Reconcile the boot language (from localStorage) with the persisted config truth.
  try {
    if (state.config.language && state.config.language !== I18n.lang) {
      await I18n.setLang(state.config.language);
      I18n.apply(document);
    } else {
      localStorage.setItem('ccbud-lang', I18n.lang);
    }
  } catch (_) {}
  renderAll();
}

/** Persist a config patch, then refresh status + views. */
export async function persist(patch) {
  try { state.config = await api.saveConfig(Object.assign({}, state.config, patch)); }
  catch (e) { pushLocalLog({ level: 'error', msg: I18n.t('err.saveFailed', { msg: (e && e.message ? e.message : e) }) }); }
  state.status = await api.serverStatus();
  renderAll();
}

const configHooks = new Set();
/** Run when the backend pushes a replacement config: fn(prevConfig, nextConfig).
    Used by the provider modal to keep an in-flight edit in sync. */
export function onConfigReplaced(fn) { configHooks.add(fn); }

/** Wire the backend push events shared by every view. Called once at boot. */
export function bindBackendEvents() {
  api.onStatus((s) => { state.status = s; renderAll(); });
  if (api.onConfigChanged) api.onConfigChanged(async (next) => {
    const prev = state.config;
    state.config = next && Array.isArray(next.providers) ? next : await api.getConfig();
    configHooks.forEach((fn) => { try { fn(prev, state.config); } catch (_) {} });
    renderAll();
  });
}
