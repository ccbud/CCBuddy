/* Skills Hub — lazy sub-pages over ~/.ccbud/skills. */
import { $, escapeHtml } from '../../core/dom.js';
import { I18n } from '../../core/i18n.js';
import { showToast } from '../../core/toast.js';
import { skillsApi } from './api.js';
import { confirmAction, formDialog, localize, pageState, setActiveNav, template } from './layout.js';
import { canUpdate, setSnapshot, skillsState } from './state.js';
import { authorizeSyncOperations as authorizeSync, syncAuthorizedOperation as syncAuthorized } from './sync-conflicts.js';

const loaders = {
  library: () => import('./library.js'), add: () => import('./add.js'),
  tags: () => import('./tags.js'), tools: () => import('./tools.js'),
  updates: () => import('./updates.js'), detail: () => import('./detail.js'),
};
let pageHost, renderToken = 0, loadToken = 0, routeToken = 0, busyDepth = 0, pendingFocus = false;

const errorText = (error) => String(error && error.message || error || I18n.t('skills.error'));

function changeBusy(delta) {
  busyDepth = Math.max(0, busyDepth + delta);
  const busy = busyDepth > 0, section = $('view-skills'), shell = section?.querySelector('.skills-shell');
  section?.setAttribute('aria-busy', String(busy));
  pageHost?.setAttribute('aria-busy', String(busy));
  if (shell) { shell.inert = busy; shell.toggleAttribute('inert', busy); }
}

function focusHeading() {
  if (!pendingFocus || !pageHost) return;
  const heading = pageHost.querySelector('h2, h1'); if (!heading) return;
  pendingFocus = false; heading.tabIndex = -1; heading.focus({ preventScroll: true });
  heading.addEventListener('blur', () => heading.removeAttribute('tabindex'), { once: true });
}

function bindRetry() {
  pageHost.onclick = (event) => { if (event.target.closest('[data-action="retry"]')) reload(); };
}

async function renderPage() {
  if (!pageHost) return;
  const page = skillsState.detailId ? 'detail' : skillsState.page;
  setActiveNav(page, skillsState);
  if (skillsState.loading && !skillsState.loaded) {
    pageHost.innerHTML = pageState('loading'); localize(pageHost); return;
  }
  if (skillsState.error && !skillsState.loaded) {
    pageHost.innerHTML = pageState('error', skillsState.error); localize(pageHost);
    bindRetry();
    return;
  }
  const token = ++renderToken;
  try {
    const mod = await loaders[page](); if (token !== renderToken) return;
    pageHost.onchange = null; pageHost.onclick = null; pageHost.oninput = null;
    mod.render(pageHost, context); focusHeading();
  } catch (error) {
    pageHost.innerHTML = pageState('error', errorText(error)); localize(pageHost);
    bindRetry();
  }
}

async function reload(showLoading = true) {
  if (showLoading && busyDepth) return null;
  changeBusy(1);
  if (showLoading) pendingFocus = true;
  const token = ++loadToken;
  skillsState.error = ''; skillsState.loading = true;
  try {
    if (showLoading) await renderPage();
    try {
      const snapshot = await skillsApi.snapshot(); if (token !== loadToken) return;
      setSnapshot(snapshot);
    } catch (error) {
      if (token !== loadToken) return;
      skillsState.error = errorText(error);
      if (skillsState.loaded) showToast(I18n.t('skills.error.withMessage', { msg: skillsState.error }), 'err');
    } finally {
      if (token === loadToken) { skillsState.loading = false; await renderPage(); }
    }
  } finally {
    changeBusy(-1);
  }
}

function navigate(page) {
  routeToken += 1; pendingFocus = true;
  skillsState.detailId = ''; skillsState.detail = null; skillsState.detailFile = ''; skillsState.detailContent = null;
  skillsState.page = page; renderPage();
}

function openDetail(id) {
  routeToken += 1; pendingFocus = true;
  skillsState.detailId = id; skillsState.detail = null; skillsState.detailFile = ''; skillsState.detailContent = null;
  renderPage();
}

async function run(task, successKey) {
  if (busyDepth) return null;
  changeBusy(1);
  const pending = showToast(I18n.t('skills.loading'), 'pending');
  try {
    const result = await task(); pending.dismiss();
    if (successKey) showToast(I18n.t(successKey), 'ok');
    return result;
  } catch (error) {
    pending.dismiss(); showToast(I18n.t('skills.error.withMessage', { msg: errorText(error) }), 'err');
    return null;
  } finally { changeBusy(-1); }
}

const settleBatch = (items, mutate) => Promise.allSettled(items.map((item, index) => Promise.resolve().then(() => mutate(item, index))));

function showBatchResult(outcomes, successKey) {
  const failed = outcomes.filter((item) => item.status === 'rejected' && !item.reason?.syncCancelled);
  const completed = outcomes.filter((item) => item.status === 'fulfilled');
  if (!failed.length) { if (successKey && (!outcomes.length || completed.length)) showToast(I18n.t(successKey), 'ok'); return; }
  const summary = I18n.t('skills.toast.batchResult', { success: completed.length, failed: failed.length });
  showToast(`${summary} ${errorText(failed[0].reason)}`, 'err');
}

async function runBatch(items, mutate, successKey, after) {
  const values = [...items]; if (!values.length) return [];
  let outcomes = [];
  return run(async () => {
    try { outcomes = await settleBatch(values, mutate); }
    finally {
      try { if (after) after(outcomes); }
      finally { pendingFocus = true; skillsState.detail = null; await reload(false); }
    }
    showBatchResult(outcomes, successKey); return outcomes;
  });
}

async function editTags(skill) {
  const data = await formDialog({ title: I18n.t('skills.tags.editTitle'), confirm: I18n.t('skills.action.save'),
    body: `<p class="text-[11px] text-caption" data-i18n="skills.tags.editHint">使用逗号分隔多个标签。</p><label><span class="sr-only" data-i18n="skills.tags.name">标签名称</span><input name="tags" type="text" autocomplete="off" value="${escapeHtml(skill.tags.join(', '))}" class="w-full bg-bg-input border border-border-custom rounded-lg px-3 py-2.5 text-[12px] outline-none focus:border-brand" data-i18n-placeholder="skills.tags.inputPlaceholder" placeholder="例如：开发、写作、效率…"></label>` });
  if (!data) return;
  const tags = [...new Set(String(data.get('tags') || '').split(/[,，]/).map((tag) => tag.trim()).filter(Boolean))];
  await run(async () => { await skillsApi.setTags(skill.id, tags); pendingFocus = true; skillsState.detail = null; await reload(false); }, 'skills.toast.tagsSaved');
}

async function deleteSkills(ids) {
  ids = [...new Set(ids)].filter(Boolean); if (!ids.length) return;
  const one = ids.length === 1, skill = skillsState.skills.find((item) => item.id === ids[0]);
  const ok = await confirmAction(I18n.t('skills.library.deleteTitle'), I18n.t(one ? 'skills.library.deleteOneConfirm' : 'skills.library.deleteManyConfirm', one ? { name: skill && skill.name || ids[0] } : { count: ids.length }), I18n.t('skills.library.delete'));
  if (!ok) return;
  await runBatch(ids, (id) => skillsApi.remove(id), 'skills.toast.deleted', (outcomes) => {
    const removed = new Set(ids.filter((_, index) => outcomes[index]?.status === 'fulfilled'));
    removed.forEach((id) => skillsState.selected.delete(id));
    if (removed.has(skillsState.detailId)) { routeToken += 1; skillsState.detailId = ''; skillsState.page = 'library'; }
  });
}

async function updateSkills(ids) {
  ids = [...new Set(ids)].filter((id) => canUpdate(skillsState.skills.find((skill) => skill.id === id))); if (!ids.length) return;
  await runBatch(ids, (id) => skillsApi.update(id), 'skills.toast.updated');
}

async function syncSkills(ids, targetKeys, mode = 'auto') {
  ids = [...new Set(ids)].filter(Boolean);
  const available = skillsState.tools.filter((tool) => tool.detected && tool.enabled).map((tool) => tool.key);
  const keys = targetKeys == null ? available : [...new Set(targetKeys)].filter(Boolean);
  if (!ids.length || !keys.length) { showToast(I18n.t('skills.library.noTargets'), 'err'); return; }
  const operations = ids.map((id) => ({ id, targetKeys: keys, mode }));
  const authorized = await authorizeSync(operations, skillsState.tools, changeBusy); if (!authorized) return;
  await runBatch(authorized, (operation) => syncAuthorized(operation, skillsState.tools), 'skills.toast.synced');
}

async function unsyncSkills(ids, targetKeys) {
  ids = [...new Set(ids)].filter(Boolean); if (!ids.length) return;
  await runBatch(ids, (id) => {
    const skill = skillsState.skills.find((item) => item.id === id);
    const keys = targetKeys == null ? (skill?.targets || []).map((target) => target.key) : targetKeys;
    return keys.length ? skillsApi.unsync(id, [...new Set(keys)]) : Promise.resolve();
  }, 'skills.toast.unsynced');
}

const context = {
  state: skillsState, api: skillsApi, render: renderPage, reload, navigate, openDetail,
  run, runBatch, settleBatch, showBatchResult, editTags, deleteSkills, updateSkills, syncSkills, unsyncSkills,
  authorizeSyncOperations: (operations) => authorizeSync(operations, skillsState.tools, changeBusy),
  syncAuthorizedOperation: (operation) => syncAuthorized(operation, skillsState.tools),
  localize, toast: showToast, focusHeading,
  routeStamp: () => routeToken,
  isCurrentDetail: (id, stamp) => stamp === routeToken && skillsState.detailId === id
    && pageHost?.isConnected && !$('view-skills')?.classList.contains('hidden'),
};

function bindShell() {
  $('skillsNav').onclick = (event) => { const button = event.target.closest('[data-skills-page]'); if (button) navigate(button.dataset.skillsPage); };
  $('skillsOpenRoot').onclick = () => run(() => skillsApi.openRoot());
}

export default {
  id: 'skills',
  mount(host) {
    host.insertAdjacentHTML('beforeend', template());
    const section = $('view-skills'); pageHost = $('skillsPage'); localize(section); bindShell();
    pageHost.innerHTML = pageState('loading'); localize(pageHost);
  },
  onShow() { routeToken += 1; pendingFocus = true; reload(skillsState.loaded === false); },
};
