/* 设置 view — subnav shell + four panes (gateway/general/data/about), each its own module. */
import { $, injectIcons } from '../../core/dom.js';
import { icons } from '../../core/icons.js';
import { I18n } from '../../core/i18n.js';
import { onRender } from '../../core/state.js';
import { gatewayPaneTemplate, renderGatewayPane, bindGatewayPane } from './gateway-pane.js';
import { generalPaneTemplate, renderGeneralPane, bindGeneralPane } from './general-pane.js';
import { dataPaneTemplate, renderDataPane, bindDataPane } from './data-pane.js';
import { aboutPaneTemplate, bindAboutPane, loadUpdateState, checkUpdate } from './about-pane.js';

const SECTION_HTML = () => `
        <section id="view-settings" class="panel hidden flex-1 min-h-0 max-w-[1120px] mx-auto px-10 pt-4 pb-5 w-full flex flex-col gap-6 animate-[panelIn_0.28s_ease-[cubic-bezier(0.23,1,0.32,1)]]">
          <header class="panel-toolbar settings-head shrink-0 mb-6 px-[2px] py-1">
            <div class="settings-head-row flex items-center gap-2.5">
              <button type="button" id="btnSubnavCollapse" class="tool-btn shrink-0 w-[26px] h-[26px] border border-border-custom rounded-[7px] bg-bg-elev text-muted cursor-pointer flex items-center justify-center transition-all duration-140 hover:text-fg hover:bg-chip-bg hover:border-border-strong" data-i18n-title="settings.nav.collapse" title="收起 / 展开" aria-label="收起 / 展开"><span data-icon="chevronLeft"></span></button>
              <h2 class="panel-label text-[12.5px] font-semibold tracking-[0.04em] uppercase text-caption" data-i18n="settings.title">设置</h2>
            </div>
            <p class="caption text-[12px] text-caption settings-head-sub" data-i18n="settings.subtitle">网关与应用偏好</p>
          </header>

          <div class="settings-layout flex gap-5 items-stretch flex-1 min-h-0">
            <nav id="settingsNav" class="settings-subnav shrink-0 flex flex-col gap-0.5" aria-label="Settings sections">
              ${['gateway', 'general', 'data', 'about'].map((p, i) => `
              <button type="button" data-settings="${p}" class="settings-subnav-item ${i === 0 ? 'active ' : ''}flex items-center gap-2.5 w-full px-2.5 py-2 rounded-[9px] border-none bg-transparent text-muted font-medium text-[13px] leading-tight cursor-pointer text-left transition-all duration-150 hover:bg-chip-bg hover:text-fg active:scale-[0.985] [&.active]:bg-brand-soft [&.active]:text-brand [&.active]:font-semibold">
                <span class="w-4 h-4 flex items-center justify-center opacity-80 [.active_&]:opacity-100" data-icon="${{ gateway: 'gateway', general: 'sliders', data: 'folder', about: 'download' }[p]}"></span>
                <span class="settings-subnav-label" data-i18n="settings.nav.${p}">${{ gateway: '网关', general: '常规', data: '数据', about: '关于与更新' }[p]}</span>
              </button>`).join('')}
            </nav>

            <div id="settingsPanes" class="settings-content flex-1 min-w-0 min-h-0 max-w-[920px] overflow-y-auto overflow-x-hidden pr-1 pb-2 flex flex-col gap-7">
            ${gatewayPaneTemplate()}
            ${generalPaneTemplate()}
            ${dataPaneTemplate()}
            ${aboutPaneTemplate()}
            </div>
          </div>
        </section>`;

// Settings sub-nav: keep the main panel focused on one section at a time.
export function switchSettings(pane) {
  const nav = $('settingsNav');
  if (nav) nav.querySelectorAll('.settings-subnav-item').forEach((b) => b.classList.toggle('active', b.dataset.settings === pane));
  const panes = $('settingsPanes');
  if (panes) panes.querySelectorAll('[data-pane]').forEach((p) => p.classList.toggle('hidden', p.dataset.pane !== pane));
  // Refresh the live cards the moment their section is revealed.
  if (pane === 'about') loadUpdateState();
}

function bindSubnav() {
  const settingsNav = $('settingsNav');
  settingsNav.addEventListener('click', (e) => {
    const b = e.target.closest('.settings-subnav-item');
    if (b && b.dataset.settings) switchSettings(b.dataset.settings);
  });
  // Settings sub-nav collapse (icons-only, auto-shrinks width) — persisted like the main sidebar.
  const subnavBtn = $('btnSubnavCollapse');
  try {
    if (localStorage.getItem('ccbud-subnav-collapsed') === '1') {
      settingsNav.classList.add('collapsed');
      const ic = subnavBtn.querySelector('[data-icon]');
      if (ic && icons.chevronRight) ic.innerHTML = icons.chevronRight;
    }
  } catch (_) {}
  subnavBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    const collapsed = settingsNav.classList.toggle('collapsed');
    const ic = subnavBtn.querySelector('[data-icon]');
    if (ic) ic.innerHTML = collapsed ? (icons.chevronRight || '›') : (icons.chevronLeft || '‹');
    try { localStorage.setItem('ccbud-subnav-collapsed', collapsed ? '1' : '0'); } catch (_) {}
  });
}

export default {
  id: 'settings',
  mount(host) {
    host.insertAdjacentHTML('beforeend', SECTION_HTML());
    const section = $('view-settings');
    I18n.apply(section);
    injectIcons(section);
    bindSubnav();
    bindGatewayPane();
    bindGeneralPane();
    bindDataPane();
    bindAboutPane();
    onRender(() => { renderGatewayPane(); renderGeneralPane(); renderDataPane(); });
    renderGatewayPane(); renderGeneralPane(); renderDataPane();
  },
  onShow() {},
  /** Jump straight to the About pane and run a check (tray “检查更新” entry point). */
  openAboutAndCheck() { switchSettings('about'); checkUpdate(); },
};
