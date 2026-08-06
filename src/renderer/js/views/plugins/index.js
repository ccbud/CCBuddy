/* 插件 view — sidecar coding-agent backends. Mounted lazily on first switch. */
import { $, escapeHtml, injectIcons } from '../../core/dom.js';
import { api } from '../../core/bridge.js';
import { I18n } from '../../core/i18n.js';
import { icons } from '../../core/icons.js';
import { renderAll } from '../../core/state.js';
import { showToast } from '../../core/toast.js';
import { renderProviderIcon } from '../providers/icon.js';
import { pluginActionsById, onPluginAction } from './actions.js';
import { openPluginGitModal, closePluginGitModal, importFromGit } from './git.js';

const PLUGIN_DOCS_URL = 'https://github.com/ccbud/ccbud/blob/main/docs/plugin-system.md';

const SECTION_HTML = `
        <section id="view-plugins" class="panel hidden flex-none max-w-[1120px] mx-auto px-10 pt-4 pb-10 w-full flex flex-col gap-6 animate-[panelIn_0.28s_ease-[cubic-bezier(0.23,1,0.32,1)]]">
          <header class="panel-hero flex items-center gap-3 p-6 bg-bg-elev border border-border-custom rounded-[18px] shadow-card">
            <div class="hero-icon w-[38px] h-[38px] rounded-[10px] bg-chip-bg text-muted flex items-center justify-center shrink-0"><span data-icon="plugins"></span></div>
            <div class="min-w-0">
              <h1 class="text-[16.5px] font-semibold tracking-[-0.02em] leading-tight" data-i18n="plugins.title">插件</h1>
              <p class="text-[12.5px] text-muted mt-[2.5px] leading-[1.35]">
                <span data-i18n="plugins.desc">复用第三方 coding agent 的本机登录态直连推理。</span>
                <a id="linkPluginDocs" href="#" class="text-brand hover:underline ml-1" data-i18n="plugins.docs" data-i18n-title="plugins.docsTitle">开发插件</a>
              </p>
            </div>
          </header>

          <div class="panel-toolbar flex items-center justify-between px-[2px] py-1">
            <h2 class="panel-label text-[12.5px] font-semibold tracking-[0.04em] uppercase text-caption" data-i18n="plugins.installed">已安装</h2>
            <div class="flex items-center gap-2">
              <button id="btnPluginOpenDir" class="btn btn-sm bg-bg-elev text-muted border border-border-custom rounded-md px-2.5 py-1.25 font-medium text-[11px] leading-none cursor-pointer hover:bg-chip-bg hover:text-fg active:scale-[0.985]" data-i18n="plugins.openDir">打开目录</button>
              <button id="btnPluginGit" class="btn btn-sm bg-bg-elev text-fg border border-border-custom rounded-md px-2.5 py-1.25 font-medium text-[11px] leading-none cursor-pointer hover:bg-chip-bg hover:border-border-strong active:scale-[0.985]" data-i18n="plugins.addGit">从 Git 添加</button>
              <button id="btnPluginInstall" class="btn btn-sm bg-bg-elev text-fg border border-border-custom rounded-md px-2.5 py-1.25 font-medium text-[11px] leading-none cursor-pointer hover:bg-chip-bg hover:border-border-strong active:scale-[0.985]" data-i18n="plugins.addLocal">添加插件…</button>
            </div>
          </div>

          <div id="pluginList" class="plugin-list flex flex-col gap-2"></div>

          <div id="emptyPlugins" class="state-empty hidden text-center px-5 py-8 border border-dashed border-border-custom rounded-xl text-muted text-[12px] leading-normal">
            <p data-i18n="plugins.empty">未发现插件。把插件目录放到 ~/.ccbud/plugins/&lt;id&gt;/ 后回到本页。</p>
          </div>

          <!-- 从 Git 添加 弹窗 -->
          <div id="pluginGitModal" class="overlay fixed inset-0 bg-black/28 flex items-center justify-center z-[120] backdrop-blur-md hidden">
            <div class="sheet w-[460px] max-w-[92vw] bg-bg-elev backdrop-blur-[40px] border border-window-border rounded-2xl shadow-[0_24px_64px_rgba(0,0,0,0.18)] flex flex-col">
              <header class="flex items-center gap-2 p-[14px_18px] border-b border-border-custom">
                <button class="tool-btn w-[26px] h-[26px] border border-border-custom rounded-[7px] bg-bg-elev text-muted cursor-pointer flex items-center justify-center transition-all duration-140 hover:text-fg hover:bg-chip-bg hover:border-border-strong" id="btnGitCancel" aria-label="close"><span data-icon="chevronLeft"></span></button>
                <h3 class="text-[14px] font-semibold tracking-tight" data-i18n="plugins.addGit">从 Git 添加</h3>
              </header>
              <div class="p-[18px_20px] flex flex-col gap-3">
                <label class="field flex flex-col gap-1.25">
                  <span class="field-label text-[11px] font-semibold text-caption uppercase tracking-[0.03em]" data-i18n="plugins.gitUrlLabel">Git 仓库地址</span>
                  <input id="pluginGitUrl" type="text" placeholder="https://github.com/owner/repo" class="bg-bg-input border border-border-custom rounded-[7px] px-2.75 py-2 text-fg text-[13px] font-mono w-full outline-none transition-colors duration-120 focus:border-primary" />
                </label>
                <p class="text-[11.5px] text-caption leading-[1.5]" data-i18n="plugins.gitWarn">⚠️ 从 Git 导入会 clone 并构建该仓库代码（需本机有 git 与构建工具链），请仅从可信来源导入。</p>
                <div class="flex justify-end gap-2 mt-1">
                  <button id="btnPluginGitGo" class="btn bg-brand text-white border-none rounded-md px-3.5 py-2 font-semibold text-[12px] leading-none cursor-pointer hover:opacity-90 active:scale-[0.985]" data-i18n="plugins.import">导入</button>
                </div>
              </div>
            </div>
          </div>
        </section>`;

export async function loadPlugins() {
  let plugins = [];
  try { plugins = await api.pluginList(); }
  catch (e) { showToast(I18n.t('plugins.loadFailed', { msg: (e && e.message) || e }), 'err'); }
  const arr = Array.isArray(plugins) ? plugins : [];
  renderPlugins(arr);
  for (const p of arr) { if (p.hasSource) checkPluginUpdate(p.id); }
}

async function checkPluginUpdate(id) {
  let r;
  try { r = await api.pluginCheckUpdate(id); } catch (_) { return; }
  if (!r || !r.updateAvailable) return;
  const sel = (window.CSS && CSS.escape) ? CSS.escape(id) : id;
  const slot = document.querySelector('[data-update-slot="' + sel + '"]');
  if (slot) slot.innerHTML = '<button class="text-[10.5px] font-semibold text-amber bg-amber-soft rounded-full px-1.75 py-0.25 border-none cursor-pointer hover:opacity-85" data-plugin-update="' + escapeHtml(id) + '" title="' + escapeHtml(I18n.t('plugins.updateTitle', { ver: r.latest || '' })) + '">↑ v' + escapeHtml(r.latest || '') + '</button>';
}

function renderPlugins(plugins) {
  const list = $('pluginList');
  if (!list) return;
  const empty = $('emptyPlugins');
  if (empty) empty.classList.toggle('hidden', plugins.length > 0);
  list.innerHTML = '';
  for (const p of plugins) {
    const running = !!p.running;
    const auth = p.auth || {};
    const st = auth.state || '';
    const authLabel = st === 'logged_in' ? (I18n.t('plugins.authLoggedIn') + (auth.account ? ' · ' + auth.account : ''))
      : st === 'expired' ? I18n.t('plugins.authExpired')
        : st === 'logged_out' ? I18n.t('plugins.authLoggedOut')
          : running ? I18n.t('plugins.authUnknown') : I18n.t('plugins.authNotRunning');
    const authColor = st === 'logged_in' ? 'text-green' : (st === 'expired' ? 'text-amber' : 'text-caption');
    const iconData = renderProviderIcon(p.name, p.icon);
    const dot = `<span class="inline-block w-1.5 h-1.5 rounded-full ${running ? 'bg-green' : 'bg-border-strong'} shrink-0"></span>`;
    const toggleBtn = `<button class="btn btn-sm ${running ? 'bg-red-soft text-red border border-red/18' : 'bg-green-soft text-green border border-green/18'} rounded-md px-2.75 py-1.25 font-semibold text-[11px] leading-none cursor-pointer hover:opacity-90 active:scale-[0.985]" data-plugin-toggle="${escapeHtml(p.id)}" data-enabled="${running ? '1' : '0'}">${running ? escapeHtml(I18n.t('plugins.disable')) : escapeHtml(I18n.t('plugins.enable'))}</button>`;
    const delBtn = `<button class="w-6.5 h-6.5 border-0 rounded-[6px] bg-transparent text-muted cursor-pointer flex items-center justify-center transition-all duration-100 hover:bg-red-soft hover:text-red" title="${escapeHtml(I18n.t('plugins.deleteTitle'))}" data-plugin-uninstall="${escapeHtml(p.id)}" data-plugin-name="${escapeHtml(p.name || p.id)}">${icons.trash || '⌫'}</button>`;
    // Plugin-declared actions (buttons/forms) — display driven entirely by the manifest.
    const actionBtns = (Array.isArray(p.actions) ? p.actions : []).map((a) => {
      if (!a || !a.id) return '';
      // Links open in a browser and never touch the plugin, so they don't need it
      // running; form/call actions default to requiring a running plugin.
      const needsRun = a.kind === 'link' ? (a.requiresRunning === true) : (a.requiresRunning !== false);
      const disabled = needsRun && !running;
      const label = escapeHtml(a.label || a.id);
      return `<button class="btn btn-sm bg-bg-elev text-fg border border-border-custom rounded-md px-2.5 py-1.25 font-medium text-[11px] leading-none cursor-pointer hover:bg-chip-bg hover:border-border-strong active:scale-[0.985] disabled:opacity-45 disabled:cursor-not-allowed" data-plugin-actionbtn="${escapeHtml(p.id)}" data-action-id="${escapeHtml(a.id)}" data-action-kind="${escapeHtml(a.kind || 'call')}"${a.url ? ` data-action-url="${escapeHtml(a.url)}"` : ''}${disabled ? ' disabled' : ''}>${label}</button>`;
    }).join('');
    pluginActionsById[p.id] = Array.isArray(p.actions) ? p.actions : [];
    const el = document.createElement('div');
    el.className = 'plugin group grid grid-cols-[36px_1fr_auto] items-center gap-3 p-2.5 pr-3.5 min-h-[60px] bg-bg-elev border border-border-custom rounded-[13px] shadow-card relative transition-all duration-150 hover:border-border-strong';
    el.dataset.id = p.id;
    el.innerHTML = `
      <div class="prov-icon w-9 h-9 rounded-[9px] shrink-0 flex items-center justify-center text-white font-bold text-[13px] shadow-sm" style="${iconData.style}">${iconData.html}</div>
      <div class="min-w-0">
        <div class="flex items-center gap-1.5 font-semibold text-[14.5px] tracking-tight text-fg">${escapeHtml(p.name || p.id)} <span class="text-[10.5px] font-mono text-caption font-normal">v${escapeHtml(p.version || '')}</span>${p.official ? ' <span class="text-[10px] font-semibold text-brand bg-brand-soft rounded-full px-1.5 py-0.25 shrink-0" title="' + escapeHtml(I18n.t('plugins.trusted')) + '">' + escapeHtml(I18n.t('plugins.trusted')) + '</span>' : ''}<span data-update-slot="${escapeHtml(p.id)}"></span> <span class="proto-badge proto-badge-xlate">${escapeHtml(p.protocol || '')}</span></div>
        <div class="mt-0.5 text-xs text-caption truncate">${escapeHtml(p.description || '')}</div>
        <div class="mt-1 flex items-center gap-1.5 text-[11.5px] ${authColor}" data-plugin-status="${escapeHtml(p.id)}">${dot}<span>${running ? escapeHtml(I18n.t('plugins.running')) : escapeHtml(I18n.t('plugins.stopped'))} · ${escapeHtml(authLabel)}</span></div>
      </div>
      <div class="flex items-center gap-1.5 shrink-0">${actionBtns}${toggleBtn}${delBtn}</div>`;
    list.appendChild(el);
  }
}

export default {
  id: 'plugins',
  mount(host) {
    host.insertAdjacentHTML('beforeend', SECTION_HTML);
    const section = $('view-plugins');
    I18n.apply(section);
    injectIcons(section);
    const deps = { reload: loadPlugins, renderProviders: renderAll };
    $('pluginList').addEventListener('click', (e) => onPluginAction(e, deps));
    $('linkPluginDocs').addEventListener('click', (e) => { e.preventDefault(); try { api.openExternal(PLUGIN_DOCS_URL); } catch (_) {} });
    $('btnPluginInstall').addEventListener('click', async () => {
      try { const r = await api.pluginInstall(I18n.t('plugins.pickDir')); if (r && r.ok) showToast(I18n.t('plugins.added', { id: r.id }), 'ok'); }
      catch (e) { showToast(I18n.t('plugins.addFailed', { msg: (e && e.message) || e }), 'err'); }
      await loadPlugins();
    });
    $('btnPluginOpenDir').addEventListener('click', () => { try { api.pluginOpenDir(); } catch (_) {} });
    $('btnPluginGit').addEventListener('click', openPluginGitModal);
    $('btnGitCancel').addEventListener('click', closePluginGitModal);
    $('pluginGitModal').addEventListener('click', (e) => { if (e.target === $('pluginGitModal')) closePluginGitModal(); });
    $('btnPluginGitGo').addEventListener('click', () => importFromGit(loadPlugins));
    $('pluginGitUrl').addEventListener('keydown', (e) => { if (e.key === 'Enter') importFromGit(loadPlugins); });
  },
  onShow() { loadPlugins(); },
};
