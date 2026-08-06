/* 插件 — list-row actions: enable/disable, uninstall, update, plugin-declared actions. */
import { api } from '../../core/bridge.js';
import { I18n } from '../../core/i18n.js';
import { state } from '../../core/state.js';
import { showToast, confirmDialog } from '../../core/toast.js';
import { setPluginBtnBusy, markPluginCardBusy } from './git.js';
import { openPluginActionForm } from './forms.js';

export const pluginActionsById = {}; // pluginId -> declared actions (for the form modal)

// ---- plugin-declared actions: buttons/forms whose shape comes from the manifest ----
async function runPluginDeclaredAction(btn, reload) {
  if (btn.disabled) return;
  const pid = btn.dataset.pluginActionbtn;
  const actionId = btn.dataset.actionId;
  const kind = btn.dataset.actionKind || 'call';
  if (kind === 'link') {
    const url = btn.dataset.actionUrl;
    if (url) { try { api.openExternal(url); } catch (_) {} }
    return;
  }
  const action = (pluginActionsById[pid] || []).find((a) => a && a.id === actionId) || { id: actionId };
  if (kind === 'form') { await openPluginActionForm(pid, action, reload); return; }
  // kind === 'call': fire-and-report, with an optional confirm gate
  // (confirmDialog, not window.confirm — the Tauri webview never shows the latter)
  if (action.confirm) {
    const ok = await confirmDialog({
      title: action.label || action.id,
      message: action.confirm,
      confirmText: action.label || action.id,
    });
    if (!ok) return;
  }
  btn.disabled = true;
  try {
    const r = await api.pluginAction(pid, actionId, {});
    showToast((r && r.message) || I18n.t('plugins.actionDone'), 'ok');
  } catch (err) {
    showToast(I18n.t('plugins.actionFailed', { msg: (err && err.message) || err }), 'err');
  }
  btn.disabled = false;
  await reload();
}

/** Delegated click handler for the plugin list; `deps` supplies reload + provider re-render. */
export async function onPluginAction(e, deps) {
  const { reload, renderProviders } = deps;
  const actionBtn = e.target.closest('[data-plugin-actionbtn]');
  if (actionBtn) { await runPluginDeclaredAction(actionBtn, reload); return; }
  const toggle = e.target.closest('[data-plugin-toggle]');
  const uninstall = e.target.closest('[data-plugin-uninstall]');
  const update = e.target.closest('[data-plugin-update]');
  const btn = toggle || uninstall || update;
  if (!btn) return;
  btn.disabled = true;
  try {
    if (toggle) {
      const enabling = toggle.dataset.enabled !== '1';
      // Starting a sidecar spawns a process and health-gates it (can take a
      // beat), so give the button an immediate spinner + "Starting…".
      if (enabling) setPluginBtnBusy(toggle, I18n.t('plugins.starting'));
      markPluginCardBusy(toggle);
      await api.pluginSetEnabled(toggle.dataset.pluginToggle, enabling);
      state.config = await api.getConfig();   // enabling adds a provider, disabling removes it
      renderProviders();
    } else if (uninstall) {
      const ok = await confirmDialog({
        title: I18n.t('plugins.deleteTitle'),
        message: I18n.t('plugins.deleteConfirmMsg', { name: uninstall.dataset.pluginName || uninstall.dataset.pluginUninstall }),
        confirmText: I18n.t('plugins.confirmDelete'),
        danger: true,
      });
      if (!ok) { uninstall.disabled = false; return; }
      const r = await api.pluginUninstall(uninstall.dataset.pluginUninstall);
      if (!(r && r.canceled)) { state.config = await api.getConfig(); renderProviders(); }
    } else if (update) {
      update.disabled = true;
      await api.pluginUpdate(update.dataset.pluginUpdate);
      state.config = await api.getConfig(); renderProviders();
    }
  } catch (err) {
    showToast(I18n.t('plugins.opFailed', { msg: (err && err.message) || err }), 'err');
  }
  await reload();
}
