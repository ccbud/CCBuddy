/*
 * View registry — lazy view mounting + switching.
 *
 * The 服务 view ships inline in index.html (first paint); every other view is an ES module
 * that mounts its template into #mainScroll on FIRST switch. That keeps cold start down to
 * the shell + one view, and gives each view a single owner module (high cohesion):
 * a view module exposes { id, mount(host), onShow?() } and registers its own renderer
 * via core/state.onRender once mounted.
 */
import { $ } from '../core/dom.js';
import { api } from '../core/bridge.js';

const LOADERS = {
  plugins: () => import('./plugins/index.js'),
  monitor: () => import('./monitor/index.js'),
  settings: () => import('./settings/index.js'),
  conversations: () => import('./conversations/index.js'),
};
const mounted = new Map(); // view -> module (providers pre-registered by main.js)

export function registerView(name, mod) { mounted.set(name, mod); }
export function isMounted(name) { return mounted.has(name); }

async function ensureView(name) {
  if (mounted.has(name)) return mounted.get(name);
  const mod = (await LOADERS[name]()).default;
  // Re-check: a fast double-click can race two imports of the same view.
  if (!mounted.has(name)) {
    mod.mount($('mainScroll'));
    mounted.set(name, mod);
  }
  return mounted.get(name);
}

/** Idle-time warm-up so the first click on a heavy view doesn't pay its mount. */
export function prefetchView(name) { ensureView(name).catch(() => {}); }

const viewIds = {
  providers: 'view-providers',
  plugins: 'view-plugins',
  monitor: 'view-monitor',
  conversations: 'view-conversations',
  settings: 'view-settings',
};
let current = 'providers';
export function currentView() { return current; }

export async function switchView(view) {
  if (!(view in LOADERS) && view !== 'providers') return;
  const mod = await ensureView(view).catch((e) => { console.error('[ccbud] view failed to load', view, e); return null; });
  if (!mod) return; // leave the current view in place rather than blanking the panel
  document.querySelectorAll('#tabs .nav-item, #tabs .seg-btn').forEach((b) => b.classList.toggle('active', b.dataset.view === view));
  current = view;

  // Smooth fade between views
  const views = Object.values(viewIds).map((id) => $(id)).filter(Boolean);
  const currentEl = views.find((el) => !el.classList.contains('hidden'));
  const target = $(viewIds[view] || 'view-providers');

  const doSwitch = () => {
    views.forEach((el) => {
      const isTarget = el === target;
      el.classList.toggle('hidden', !isTarget);
      if (!isTarget) {
        el.style.transition = '';
        el.style.opacity = '';
      }
    });
    $('btnAdd').classList.toggle('hidden', view !== 'providers');
    const emptyAdd = $('btnAddEmpty');
    if (emptyAdd) emptyAdd.classList.toggle('hidden', view !== 'providers');

    if (target) {
      target.style.transition = 'none';
      target.style.opacity = '0';
      // Restart the fade on the next frame instead of `void target.offsetWidth` — that read forced a
      // synchronous full-document layout on every view switch (costly on the heavy 对话 view; traced).
      requestAnimationFrame(() => {
        target.style.transition = 'opacity 0.22s cubic-bezier(0.23, 1, 0.32, 1)';
        target.style.opacity = '1';
        setTimeout(() => { if (target) target.style.transition = ''; }, 280);
      });
    }

    if (mod && mod.onShow) mod.onShow();
    // Lock the window to a fixed, non-resizable size on Settings; restore it elsewhere.
    if (api.setSettingsMode) api.setSettingsMode(view === 'settings');
    // 对话 needs the wide 3-column layout (min 1300); other views can be narrower (900) so a wide
    // window doesn't leave big side gaps. Switching to 对话 auto-grows the window to ≥1300.
    if (api.setViewMinWidth) api.setViewMinWidth(view === 'conversations' ? 1300 : 900);
  };

  if (currentEl && currentEl !== target) {
    currentEl.style.transition = 'opacity 0.12s ease';
    currentEl.style.opacity = '0';
    setTimeout(() => {
      currentEl.style.transition = '';
      currentEl.style.opacity = '';
      doSwitch();
    }, 110);
  } else {
    doSwitch();
  }
}
