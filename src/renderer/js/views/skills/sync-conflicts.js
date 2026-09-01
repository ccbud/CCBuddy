import { escapeHtml } from '../../core/dom.js';
import { I18n } from '../../core/i18n.js';
import { showToast } from '../../core/toast.js';
import { skillsApi } from './api.js';
import { formDialog } from './layout.js';

const errorText = (error) => String(error && error.message || error || I18n.t('skills.error'));
let confirmationQueue = Promise.resolve();

function mergeConflicts(groups) {
  const byPath = new Map();
  groups.flat().forEach((conflict) => {
    const path = String(conflict?.path || ''); if (!path) return;
    let entry = byPath.get(path);
    if (!entry) { entry = { path, keys: new Set() }; byPath.set(path, entry); }
    (Array.isArray(conflict.keys) ? conflict.keys : []).forEach((key) => entry.keys.add(String(key)));
  });
  return [...byPath.values()].map((entry) => ({ path: entry.path, keys: [...entry.keys] }));
}

async function confirmConflicts(conflicts, tools) {
  const labels = new Map(tools.map((tool) => [tool.key, tool.label]));
  const rows = conflicts.map((conflict) => {
    const names = conflict.keys.map((key) => labels.get(key) || key).join(', ');
    const detail = names ? `<small class="block mt-1 text-[10px] text-caption">${escapeHtml(I18n.t('skills.syncConflict.tools', { tools: names }))}</small>` : '';
    return `<li class="rounded-lg border border-border-custom bg-bg-input px-3 py-2.5"><code class="block break-all text-[10.5px] text-fg" translate="no">${escapeHtml(conflict.path)}</code>${detail}</li>`;
  }).join('');
  const data = await formDialog({
    title: I18n.t('skills.syncConflict.title'), confirm: I18n.t('skills.syncConflict.confirm'), danger: true,
    body: `<p class="text-[12.5px] text-caption leading-relaxed">${escapeHtml(I18n.t('skills.syncConflict.message', { count: conflicts.length }))}</p><ul class="max-h-[210px] flex flex-col gap-2 overflow-y-auto" role="list">${rows}</ul>`,
  });
  return Boolean(data);
}

function queuedConfirmation(conflicts, tools) {
  const result = confirmationQueue.then(() => confirmConflicts(mergeConflicts([conflicts]), tools));
  confirmationQueue = result.then(() => undefined, () => undefined);
  return result;
}

function confirmationRequired(error) {
  const candidates = [error, error?.message];
  for (let value of candidates) {
    if (typeof value === 'string') {
      try { value = JSON.parse(value); } catch (_) { continue; }
    }
    if (value?.code === 'confirmation_required' && Array.isArray(value.conflicts)) return value.conflicts;
  }
  return null;
}

export async function authorizeSyncOperations(operations, tools, changeBusy) {
  changeBusy(1);
  let previews;
  try {
    previews = await Promise.all(operations.map((operation) =>
      skillsApi.syncConflicts(operation.id, operation.targetKeys)));
  } catch (error) {
    showToast(I18n.t('skills.error.withMessage', { msg: errorText(error) }), 'err');
    return null;
  } finally { changeBusy(-1); }
  const authorized = operations.map((operation, index) => ({
    ...operation, authorizing: Array.isArray(previews[index]) ? previews[index] : [],
  }));
  const conflicts = mergeConflicts(previews);
  if (!conflicts.length) return authorized;
  return await queuedConfirmation(conflicts, tools) ? authorized : null;
}

export async function syncAuthorizedOperation(operation, tools) {
  let authorizing = operation.authorizing || [];
  let retriedWithoutConflicts = false;
  for (;;) {
    try {
      return await skillsApi.sync(operation.id, operation.targetKeys, operation.mode, authorizing);
    } catch (error) {
      const conflicts = confirmationRequired(error); if (!conflicts) throw error;
      if (!conflicts.length) {
        if (retriedWithoutConflicts) throw error;
        retriedWithoutConflicts = true; authorizing = []; continue;
      }
      if (!await queuedConfirmation(conflicts, tools)) {
        const cancellation = new Error(I18n.t('skills.action.cancel'));
        cancellation.syncCancelled = true;
        throw cancellation;
      }
      retriedWithoutConflicts = false;
      authorizing = conflicts;
    }
  }
}
