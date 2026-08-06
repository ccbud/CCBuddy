/*
 * App entry point. Cold-start contract: this module and the core modules it imports are the
 * ONLY JS parsed before first paint. Everything else — the other four views, their markup, the
 * markdown/highlight vendor bundles, and all but the active language's dictionary — loads on
 * demand (see core/loader.js, views/registry.js).
 */
import './core/bridge.js';
import { $, injectIcons } from './core/dom.js';
import { icons } from './core/icons.js';
import { I18n, detectLang } from './core/i18n.js';
import { idlePrefetch, ensureVendor } from './core/loader.js';
import { toggleTheme } from './core/theme.js';
import { refresh, bindBackendEvents, pushLocalLog, state } from './core/state.js';
import { api } from './core/bridge.js';
import { switchView, registerView, prefetchView } from './views/registry.js';
import providersView from './views/providers/index.js';
import { initMonitorFeed } from './views/monitor/feed.js';
import { applyConvFont } from './views/settings/conv-font.js';

/** Sidebar chrome shared by every view: nav, theme, collapse. */
function bindShell() {
  if ($('appLogo') && icons.logo) $('appLogo').innerHTML = icons.logo(30);
  injectIcons();

  $('tabs').addEventListener('click', (e) => {
    const btn = e.target.closest('.nav-item, .seg-btn');
    if (btn && btn.dataset.view) switchView(btn.dataset.view);
  });
  $('btnTheme').addEventListener('click', toggleTheme);

  // Main sidebar collapse (affects all views)
  const sidebar = document.querySelector('.sidebar');
  const collapseBtn = $('btnCollapseSidebar');
  if (collapseBtn && sidebar) {
    try {
      if (localStorage.getItem('ccbud-sidebar-collapsed') === '1') {
        sidebar.classList.add('collapsed');
        const icon = collapseBtn.querySelector('[data-icon]');
        if (icon && icons.chevronRight) icon.innerHTML = icons.chevronRight;
      }
    } catch (_) {}
    collapseBtn.addEventListener('click', () => {
      const isCollapsed = sidebar.classList.toggle('collapsed');
      const icon = collapseBtn.querySelector('[data-icon]');
      if (icon) icon.innerHTML = isCollapsed ? (icons.chevronRight || '›') : (icons.chevronLeft || '‹');
      try { localStorage.setItem('ccbud-sidebar-collapsed', isCollapsed ? '1' : '0'); } catch (_) {}
    });
  }
}

/** Update events are subscribed at BOOT, not at Settings mount, so a staged hot update is
    still recorded (and the tray's "检查更新" still works) before that view is ever opened. */
function bindUpdateEvents() {
  if (api.onUpdateStaged) api.onUpdateStaged(() => pushLocalLog({ level: 'info', msg: I18n.t('about.stagedLog') }));
  if (api.onUpdateOpenPane) api.onUpdateOpenPane(async () => {
    await switchView('settings');
    const settings = (await import('./views/settings/index.js')).default;
    settings.openAboutAndCheck();
  });
}

async function boot() {
  // Language first: the dictionary parts for the active locale must be in place before any
  // view renders a translated string. theme-boot.js already stamped theme + <html lang>.
  await I18n.setLang(detectLang());
  I18n.apply(document);

  bindShell();
  registerView('providers', providersView);
  providersView.mount();
  // Gateway traffic counts from launch, even before the 监控 view is first opened.
  initMonitorFeed();
  bindBackendEvents();
  bindUpdateEvents();

  await refresh();
  applyConvFont(); // config-driven --conv-fs, so 会话 is correct the first time it opens

  // Warm the two heaviest lazy paths while the app is idle, so the first click feels instant.
  idlePrefetch(() => { ensureVendor().catch(() => {}); });
  idlePrefetch(() => prefetchView('conversations'), 6000);
}

boot();
export { state };
