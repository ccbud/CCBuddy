/* Left-list event wiring: open, tag filter/edit, restore/remove, project collapse, dir chips. */
import { $ } from '../../core/dom.js';
import { api } from '../../core/bridge.js';
import { cs, persistCollapsed } from './state.js';
import { refreshList, renderList, scheduleContentSearch } from './list.js';
import { openConversation } from './detail.js';
import { syncConvNav } from './panels.js';
import { applyImportResult } from './actions.js';
import { deleteTag, restoreSession, deleteForever, startEditTag, showCtxMenu, hideCtxMenu } from './meta-edit.js';

const metaDeps = { refresh: refreshList, renderList, syncConvNav };

async function onListClick(e) {
  if (e.target.closest('[data-clear-tagfilter]')) { e.stopPropagation(); cs.tagFilter = null; renderList(); return; }
  const delTag = e.target.closest('[data-del-tag]');
  if (delTag) { e.stopPropagation(); await deleteTag(delTag.dataset.file, delTag.dataset.delTag, metaDeps); return; }
  const tagChip = e.target.closest('.conv-tag');
  if (tagChip && tagChip.dataset.tag) {
    e.stopPropagation();
    // Defer the filter toggle so a double-click (edit) can cancel it — otherwise the first click
    // of the dblclick would re-render the list and destroy the chip before dblclick fires.
    const tag = tagChip.dataset.tag;
    clearTimeout(cs.tagClickTimer);
    cs.tagClickTimer = setTimeout(() => { cs.tagFilter = (cs.tagFilter === tag) ? null : tag; renderList(); }, 220);
    return;
  }
  const restoreBtn = e.target.closest('[data-restore]');
  if (restoreBtn) { e.stopPropagation(); await restoreSession(restoreBtn.dataset.restore, metaDeps); return; }
  const delFvr = e.target.closest('[data-delete-forever]');
  if (delFvr) { e.stopPropagation(); await deleteForever(delFvr.dataset.deleteForever, metaDeps); return; }
  const rm = e.target.closest('[data-remove-import]');
  if (rm) {
    e.stopPropagation();
    const file = rm.dataset.removeImport;
    if (!file || !api.historyRemoveImport) return;
    let res; try { res = await api.historyRemoveImport(file); } catch (_) { res = null; } // confirms in the backend
    if (!res || !res.ok) return; // cancelled or failed → leave the list as-is
    if (file === cs.openFile) { cs.openId = null; cs.openFile = null; syncConvNav(); }
    await refreshList();
    return;
  }
  const head = e.target.closest('.conv-proj-head');
  if (head) {
    const key = head.dataset.proj;
    if (cs.collapsed.has(key)) cs.collapsed.delete(key); else cs.collapsed.add(key);
    persistCollapsed();
    renderList();
    return;
  }
  const item = e.target.closest('.conv-item');
  if (item) {
    // Opening from a content hit carries the query along, so the conversation lands right on
    // the match — switching to the matching subagent first when that's where it lives.
    const hit = (cs.search && cs.contentHits) ? cs.contentHits.get(item.dataset.file) : null;
    cs.pendingLocate = hit ? { query: cs.search, agent: hit.agent || 'main' } : null;
    openConversation(item.dataset.id, item.dataset.file);
  }
}

export function bindListEvents() {
  const list = $('convList');
  list.addEventListener('click', onListClick);
  // Right-click a conversation → rename / add-tag menu.
  list.addEventListener('contextmenu', (e) => {
    const item = e.target.closest('.conv-item');
    if (!item) return;
    e.preventDefault();
    showCtxMenu(e.clientX, e.clientY, item.dataset.file, item.dataset.id, metaDeps);
  });
  // Double-click a tag chip → edit it in place.
  list.addEventListener('dblclick', (e) => {
    const label = e.target.closest('.conv-tag-label');
    if (!label) return;
    e.preventDefault(); e.stopPropagation();
    clearTimeout(cs.tagClickTimer); // cancel the pending single-click filter toggle
    const chip = label.closest('.conv-tag');
    if (chip && chip.dataset.tag) startEditTag(chip.dataset.file, chip.dataset.tag, chip, metaDeps);
  });
  list.addEventListener('scroll', hideCtxMenu, true);
  document.addEventListener('click', (e) => { if (!e.target.closest('.conv-ctx-menu')) hideCtxMenu(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') hideCtxMenu(); });

  const sb = $('convSearch');
  sb.addEventListener('input', (e) => { cs.search = e.target.value.trim(); scheduleContentSearch(); renderList(); });
  $('convClear').addEventListener('click', () => {
    const i = $('convSearch');
    if (i) { i.value = ''; cs.search = ''; scheduleContentSearch(); renderList(); i.focus(); }
  });
  const imp = $('convImportBtn');
  if (api.historyImport) imp.addEventListener('click', async () => {
    imp.disabled = true;
    let r; try { r = await api.historyImport(); } catch (_) { r = null; }
    imp.disabled = false;
    await applyImportResult(r, refreshList);
  });
  $('convDirSwitch').addEventListener('click', async (e) => {
    const btn = e.target.closest('[data-dir]');
    if (!btn) return;
    try { if (api.historySetActive) await api.historySetActive(btn.dataset.dir); } catch (_) {}
    await refreshList();
  });
}
