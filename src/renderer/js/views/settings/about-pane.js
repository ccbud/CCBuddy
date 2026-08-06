/* 设置 → 关于与更新 pane: in-app update state machine + links + auto toggles. */
import { $, show, copyFeedback } from '../../core/dom.js';
import { api } from '../../core/bridge.js';
import { I18n } from '../../core/i18n.js';
import { state } from '../../core/state.js';
import { confirmDialog } from '../../core/toast.js';
import { SWITCH_TRACK } from './gateway-template.js';

export const aboutPaneTemplate = () => `
            <div data-pane="about" class="hidden">
            <div class="settings-card bg-bg-elev border border-border-custom rounded-xl shadow-card p-7 flex flex-col gap-6 transition-all duration-300">
              <div class="settings-card-header flex justify-between items-center gap-3">
                <h3 class="settings-card-title text-[13px] font-semibold text-fg flex items-center gap-2"><span data-i18n="about.title">检查更新</span><span id="updateChip" class="update-chip text-[10.5px] font-semibold rounded-full px-2 py-0.25 bg-chip-bg text-muted hidden"></span></h3>
                <button id="btnUpdateCheck" type="button" class="btn btn-sm btn-primary bg-primary text-white border-none rounded-md px-2.25 py-1.25 font-semibold text-[11px] leading-none cursor-pointer transition-all duration-140 hover:bg-primary-hover active:scale-[0.985]" data-i18n="about.check">检查更新</button>
              </div>
              <div class="flex items-center gap-x-8 gap-y-2 flex-wrap">
                <div class="flex flex-col gap-0.5">
                  <span class="text-[11px] uppercase tracking-[0.03em] text-caption font-semibold" data-i18n="about.version">当前版本</span>
                  <span id="updVersion" class="text-[15px] font-bold text-fg font-mono">—</span>
                </div>
                <div class="flex flex-col gap-0.5">
                  <span class="text-[11px] uppercase tracking-[0.03em] text-caption font-semibold" data-i18n="about.latest">最新版本</span>
                  <span id="updLatest" class="text-[15px] font-bold text-fg font-mono">—</span>
                </div>
              </div>
              <p id="updStatus" class="caption text-[12px] text-caption leading-[1.55]" data-i18n="about.idle">点击「检查更新」查看是否有新版本。</p>
              <div id="updActions" class="flex items-center gap-2 flex-wrap hidden">
                <button id="btnUpdateDownload" type="button" class="btn btn-sm btn-primary bg-primary text-white border-none rounded-md px-2.75 py-1.5 font-semibold text-[12px] leading-none cursor-pointer transition-all duration-140 hover:bg-primary-hover active:scale-[0.985] hidden" data-i18n="about.downloadInstall">下载并安装</button>
                <button id="btnUpdateApply" type="button" class="btn btn-sm btn-primary bg-primary text-white border-none rounded-md px-2.75 py-1.5 font-semibold text-[12px] leading-none cursor-pointer transition-all duration-140 hover:bg-primary-hover active:scale-[0.985] hidden" data-i18n="about.restartNow">立即重启更新</button>
                <button id="btnUpdateOpen" type="button" class="btn btn-sm bg-bg-elev text-fg border border-border-custom rounded-md px-2.75 py-1.5 font-medium text-[12px] leading-none cursor-pointer transition-all duration-140 hover:bg-chip-bg hover:border-border-strong active:scale-[0.985] hidden" data-i18n="about.openDownload">前往下载页</button>
                <button id="btnUpdateBrew" type="button" class="btn btn-sm bg-bg-elev text-fg border border-border-custom rounded-md px-2.75 py-1.5 font-mono text-[11.5px] leading-none cursor-pointer transition-all duration-140 hover:bg-chip-bg hover:border-border-strong active:scale-[0.985] hidden">brew upgrade --cask ccbud</button>
              </div>
              <pre id="updNotes" class="hidden m-0 px-3.5 py-3 rounded-lg bg-bg-input border border-border-custom font-mono text-[11px] leading-[1.6] text-caption max-h-[180px] overflow-auto whitespace-pre-wrap break-words"></pre>
              <div class="settings-row flex items-center gap-x-6 gap-y-4 flex-wrap pt-6 border-t border-border-custom">
                <label class="switch inline-flex items-center gap-1.75 cursor-pointer text-[12.5px] no-drag">
                  <input id="fAutoCheck" type="checkbox" class="hidden peer" />${SWITCH_TRACK}
                  <span class="switch-label" data-i18n="about.autoCheck">自动检查更新</span>
                </label>
                <label class="switch inline-flex items-center gap-1.75 cursor-pointer text-[12.5px] no-drag">
                  <input id="fAutoDownload" type="checkbox" class="hidden peer" />${SWITCH_TRACK}
                  <span class="switch-label" data-i18n="about.autoDownload">热更自动下载</span>
                </label>
              </div>
              <p class="caption text-[11.5px] text-caption leading-[1.5]" data-i18n="about.autoDesc">热更（仅 JS）满足条件时自动下载并在下次启动时生效；涉及原生改动的更新会提示你重新安装。</p>
              <div class="settings-row flex items-center gap-3 flex-wrap pt-6 border-t border-border-custom">
                <button id="btnRepo" type="button" class="text-[12px] text-brand hover:underline cursor-pointer no-drag" data-i18n="about.repo">项目主页</button>
                <span class="text-caption">·</span>
                <button id="btnReleases" type="button" class="text-[12px] text-brand hover:underline cursor-pointer no-drag" data-i18n="about.releaseNotes">发布记录</button>
              </div>
            </div>
            </div>

            <div id="startError" class="startError alert alert-err hidden text-[12px] px-3 py-2.25 rounded-lg border border-red/12 text-red bg-red-soft"></div>`;

let updateState = null;
let updateBusy = false;

export function renderUpdate() {
  const s = updateState;
  const verEl = $('updVersion'), latEl = $('updLatest'), stEl = $('updStatus'), chip = $('updateChip');
  const actions = $('updActions'), bDl = $('btnUpdateDownload'), bApply = $('btnUpdateApply'),
    bOpen = $('btnUpdateOpen'), bBrew = $('btnUpdateBrew'), notes = $('updNotes');
  if (!verEl) return;
  if (s) {
    verEl.textContent = s.runningVersion || s.shellVersion || '—';
    latEl.textContent = s.latestVersion || '—';
  }
  // reset
  [bDl, bApply, bOpen, bBrew].forEach((b) => show(b, false));
  show(actions, false); show(notes, false); show(chip, false);
  if (chip) chip.classList.remove('text-green', 'text-amber');

  if (!s) { stEl.textContent = I18n.t('about.idle'); return; }
  const staged = s.pending && s.pending.staged;
  if (staged) {
    stEl.textContent = I18n.t('about.stagedReady', { v: s.pending.version });
    chip.textContent = I18n.t('about.ready'); chip.classList.add('text-green'); show(chip, true);
    show(actions, true); show(bApply, true);
    return;
  }
  if (s.ok === false) { stEl.textContent = I18n.t('about.checkFailed', { msg: s.error || '' }); return; }
  if (!s.latestVersion || s.mode === 'unknown') { stEl.textContent = I18n.t('about.idle'); return; }
  if (s.mode === 'none') { stEl.textContent = I18n.t('about.upToDate'); chip.textContent = I18n.t('about.upToDateChip'); chip.classList.add('text-green'); show(chip, true); return; }

  // an update is available
  chip.textContent = I18n.t('about.availableChip'); chip.classList.add('text-amber'); show(chip, true);
  show(actions, true);
  if (s.notes) { notes.textContent = s.notes; show(notes, true); }
  if (s.mode === 'hot') {
    stEl.textContent = updateBusy ? I18n.t('about.downloading') : I18n.t('about.hotAvailable', { v: s.latestVersion });
    show(bDl, true); bDl.disabled = updateBusy; bDl.textContent = updateBusy ? I18n.t('about.downloading') : I18n.t('about.downloadInstall');
  } else { // full
    stEl.textContent = I18n.t('about.fullAvailable', { v: s.latestVersion });
    show(bOpen, true);
    if (s.installMethod === 'mac' || s.installMethod === 'linux') { bBrew.textContent = s.brewCommand || 'brew upgrade --cask ccbud'; show(bBrew, true); }
  }
}

export async function loadUpdateState() {
  try { updateState = await api.updateState(); } catch (_) {}
  syncAutoToggles();
  renderUpdate();
}

export async function checkUpdate() {
  const btn = $('btnUpdateCheck');
  if (btn) btn.disabled = true;
  $('updStatus').textContent = I18n.t('about.checking');
  try { updateState = await api.updateCheck(); } catch (e) { updateState = { ok: false, error: (e && e.message) || '' }; }
  if (btn) btn.disabled = false;
  renderUpdate();
}

async function downloadUpdate() {
  updateBusy = true; renderUpdate();
  let res;
  try { res = await api.updateDownload(); } catch (e) { res = { ok: false, error: (e && e.message) || '' }; }
  updateBusy = false;
  try { updateState = await api.updateState(); } catch (_) {}
  if (res && !res.ok && updateState) updateState.error = res.error;
  renderUpdate();
}

function syncAutoToggles() {
  const au = (state.config && state.config.autoUpdate) || {};
  const c = $('fAutoCheck'), d = $('fAutoDownload');
  if (c) c.checked = au.check !== false;
  if (d) d.checked = au.autoDownload !== false;
}

export function bindAboutPane() {
  $('btnUpdateCheck').addEventListener('click', checkUpdate);
  $('btnUpdateDownload').addEventListener('click', downloadUpdate);
  $('btnUpdateApply').addEventListener('click', async () => {
    const ok = await confirmDialog({ title: I18n.t('about.restartTitle'), message: I18n.t('about.restartMsg'), confirmText: I18n.t('about.restartNow') });
    if (ok) api.updateApply();
  });
  $('btnUpdateOpen').addEventListener('click', () => api.openExternal((updateState && updateState.releaseUrl) || 'https://github.com/ccbud/ccbud/releases/latest'));
  $('btnUpdateBrew').addEventListener('click', (e) => copyFeedback(e.currentTarget, (updateState && updateState.brewCommand) || 'brew upgrade --cask ccbud', I18n.t('copy.copiedCheck'), api.copy));
  $('btnRepo').addEventListener('click', () => api.openExternal('https://github.com/ccbud/ccbud'));
  $('btnReleases').addEventListener('click', () => api.openExternal('https://github.com/ccbud/ccbud/releases'));
  $('fAutoCheck').addEventListener('change', async (e) => { state.config.autoUpdate = await api.updateSetAuto({ check: e.target.checked }); });
  $('fAutoDownload').addEventListener('change', async (e) => { state.config.autoUpdate = await api.updateSetAuto({ autoDownload: e.target.checked }); });
  if (api.onUpdateState) api.onUpdateState((s) => { updateState = s; renderUpdate(); });
  // The staged-update LOG line is emitted from boot (main.js); here we only refresh this pane.
  if (api.onUpdateStaged) api.onUpdateStaged(() => loadUpdateState());
}
