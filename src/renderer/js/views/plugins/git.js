/* 插件 — “从 Git 添加” modal + full-screen busy overlay for clone/build runs. */
import { $, escapeHtml } from '../../core/dom.js';
import { api } from '../../core/bridge.js';
import { I18n } from '../../core/i18n.js';
import { showToast } from '../../core/toast.js';

export function openPluginGitModal() {
  const m = $('pluginGitModal'); if (!m) return;
  m.classList.remove('hidden');
  const u = $('pluginGitUrl'); if (u) { u.value = ''; u.focus(); }
}
export function closePluginGitModal() { const m = $('pluginGitModal'); if (m) m.classList.add('hidden'); }

// Full-screen blocking overlay shown while a git clone/build runs — the user
// cannot interact with the rest of the app until it finishes.
export function showPluginBusy(text) {
  let ov = document.getElementById('pluginBusy');
  if (!ov) {
    ov = document.createElement('div');
    ov.id = 'pluginBusy';
    ov.className = 'overlay fixed inset-0 flex flex-col items-center justify-center z-[300] backdrop-blur-md';
    ov.style.background = 'rgba(0,0,0,0.45)';
    ov.innerHTML = '<div class="animate-spin" style="width:34px;height:34px;border:3px solid rgba(255,255,255,0.28);border-top-color:#fff;border-radius:50%"></div><p id="pluginBusyText" style="color:#fff;margin-top:14px;font-size:13px;font-weight:600"></p>';
    document.body.appendChild(ov);
  }
  const t = ov.querySelector('#pluginBusyText'); if (t) t.textContent = text || '';
  ov.style.display = 'flex';
}
export function hidePluginBusy() { const ov = document.getElementById('pluginBusy'); if (ov) ov.style.display = 'none'; }

/** Import a plugin from the URL typed into the git modal; refreshes via `reload()`. */
export async function importFromGit(reload) {
  const u = $('pluginGitUrl');
  const url = ((u && u.value) || '').trim();
  if (!url) return;
  closePluginGitModal();
  showPluginBusy(I18n.t('plugins.importing'));
  try {
    const r = await api.pluginInstallGit(url);
    hidePluginBusy();
    if (r && r.ok) showToast(I18n.t('plugins.gitImported', { id: r.id }), 'ok');
  } catch (e) {
    hidePluginBusy();
    showToast(I18n.t('plugins.gitFailed', { msg: (e && e.message) || e }), 'err');
  }
  await reload();
}

// Small inline spinner used for per-button loading (enable/start).
export function pluginSpinner() {
  return '<span class="animate-spin inline-block w-3 h-3 rounded-full border-[1.5px] border-current border-t-transparent align-[-2px]"></span>';
}
// Turn a button into a busy state: spinner + text, disabled. Reset happens on the
// next renderPlugins() (loadPlugins re-renders the whole list from fresh status).
export function setPluginBtnBusy(btn, text) {
  if (!btn) return;
  btn.disabled = true;
  btn.innerHTML = `<span class="inline-flex items-center gap-1.25">${pluginSpinner()}${escapeHtml(text || '')}</span>`;
}
// Dim the card and swap its status line to a "starting" spinner while the sidecar
// spins up, so the whole row reads as in-progress (not just the button).
export function markPluginCardBusy(btn) {
  const card = btn && btn.closest('.plugin');
  if (!card) return;
  card.classList.add('opacity-60', 'pointer-events-none');
  const line = card.querySelector('[data-plugin-status]');
  if (line) line.innerHTML = `${pluginSpinner()}<span>${escapeHtml(I18n.t('plugins.starting'))}</span>`;
}
