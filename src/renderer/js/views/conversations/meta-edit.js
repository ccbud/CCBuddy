/* Per-session customization: inline rename, tags, soft delete / restore / delete-forever. */
import { api } from '../../core/bridge.js';
import { confirmDialog } from '../../core/toast.js';
import { cssAttr, isForeignSource, L } from './format.js';
import { icons } from '../../core/icons.js';
import { cs, findSession } from './state.js';
import { esc } from './format.js';

// Persist a title/tags patch for one conversation, then refresh. The backend also broadcasts
// history:changed (which refreshes too) — the explicit refresh just makes it feel instant.
async function applyMeta(file, patch, refresh) {
  if (!file || !api.historySetMeta) return;
  try { await api.historySetMeta(file, patch); } catch (_) {}
  await refresh();
}

function itemEl(id, file) {
  return document.querySelector(`.conv-item[data-id="${cssAttr(id)}"]`)
    || (file ? document.querySelector(`.conv-item[data-file="${cssAttr(file)}"]`) : null);
}

// Swap a node for a single-line text input; commit on Enter/blur, cancel on Escape. The `done`
// guard makes Enter-then-blur (or Esc-then-blur) run the callback exactly once. onCommit(value|null):
// null = cancelled, '' = emptied (callers treat empty as clear/no-op), else the trimmed value.
function inlineEdit(node, opts) {
  const inp = document.createElement('input');
  inp.className = opts.cls;
  inp.value = opts.value || '';
  if (opts.placeholder) inp.setAttribute('placeholder', opts.placeholder);
  node.replaceWith(inp);
  inp.focus(); inp.select();
  let done = false;
  const finish = (save) => { if (done) return; done = true; opts.onCommit(save ? inp.value.trim() : null); };
  inp.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); finish(true); }
    else if (e.key === 'Escape') { e.preventDefault(); finish(false); }
  });
  inp.addEventListener('blur', () => finish(true));
}

export function startRename(file, id, deps) {
  const item = itemEl(id, file); if (!item) return;
  const titleEl = item.querySelector('.conv-title'); if (!titleEl) return;
  const s = findSession(id, file);
  inlineEdit(titleEl, {
    cls: 'conv-title-edit', value: (s && s.title) || '', placeholder: L('conv.renamePlaceholder'),
    onCommit: (v) => { if (v == null) { deps.renderList(); return; } applyMeta(file, { title: v }, deps.refresh); }, // '' clears → auto title
  });
}

export function startAddTag(file, id, deps) {
  const item = itemEl(id, file); if (!item) return;
  let row = item.querySelector('.conv-item-tags');
  if (!row) {
    row = document.createElement('div');
    row.className = 'conv-item-tags';
    row.dataset.file = file;
    const sub = item.querySelector('.conv-item-sub');
    if (sub) sub.after(row); else item.appendChild(row);
  }
  const holder = document.createElement('span');
  row.appendChild(holder);
  inlineEdit(holder, {
    cls: 'conv-tag-edit', value: '', placeholder: L('conv.tagPlaceholder'),
    onCommit: (v) => {
      if (!v) { deps.renderList(); return; }
      const s = findSession(id, file);
      applyMeta(file, { tags: ((s && s.tags) || []).concat([v]) }, deps.refresh);
    },
  });
}

export function startEditTag(file, oldTag, chip, deps) {
  if (!chip) return;
  inlineEdit(chip, {
    cls: 'conv-tag-edit', value: oldTag, placeholder: L('conv.tagPlaceholder'),
    onCommit: (v) => {
      if (v == null) { deps.renderList(); return; }
      const s = findSession(null, file);
      const cur = (s && s.tags) || [];
      const nextTags = v ? cur.map((t) => (t === oldTag ? v : t)) : cur.filter((t) => t !== oldTag); // empty = delete
      if (cs.tagFilter === oldTag) cs.tagFilter = v || null;
      applyMeta(file, { tags: nextTags }, deps.refresh);
    },
  });
}

export async function deleteTag(file, tag, deps) {
  const s = findSession(null, file);
  await applyMeta(file, { tags: ((s && s.tags) || []).filter((t) => t !== tag) }, deps.refresh);
}

// Soft delete: confirm, flag __ccbud__.delete=true, then refresh (the session drops out of every
// normal view and reappears only in the recycle bin).
export async function softDelete(file, deps) {
  if (!file) return;
  const ok = await confirmDialog({ title: L('conv.deleteTitle'), message: L('conv.deleteConfirm'), confirmText: L('conv.ctxDelete'), cancelText: L('modal.cancel'), danger: true });
  if (!ok) return;
  if (file === cs.openFile) { cs.openId = null; cs.openFile = null; deps.syncConvNav(); }
  await applyMeta(file, { delete: true }, deps.refresh);
}

export async function restoreSession(file, deps) {
  if (!file) return;
  await applyMeta(file, { delete: false }, deps.refresh); // drop the flag → back to its working dir
}

export async function deleteForever(file, deps) {
  if (!file || !api.historyDeleteForever) return;
  const ok = await confirmDialog({ title: L('conv.deleteForeverTitle'), message: L('conv.deleteForeverConfirm'), confirmText: L('conv.deleteForever'), cancelText: L('modal.cancel'), danger: true });
  if (!ok) return;
  let res; try { res = await api.historyDeleteForever(file); } catch (_) { res = null; }
  if (!res || !res.ok) return;
  if (file === cs.openFile) { cs.openId = null; cs.openFile = null; deps.syncConvNav(); }
  await deps.refresh();
}

// Right-click context menu on a conversation row: rename / add tag / delete (or restore /
// delete-forever in the recycle bin). A single body-level element, re-targeted per open (the
// list re-renders, so a list-child menu would be wiped out).
let ctxMenuEl = null;
export function hideCtxMenu() { if (ctxMenuEl) ctxMenuEl.classList.add('hidden'); }

export function showCtxMenu(x, y, file, id, deps) {
  if (!ctxMenuEl) {
    ctxMenuEl = document.createElement('div');
    ctxMenuEl.className = 'conv-ctx-menu hidden';
    document.body.appendChild(ctxMenuEl);
    ctxMenuEl.addEventListener('click', (e) => {
      const it = e.target.closest('[data-ctx]'); if (!it) return;
      const act = it.dataset.ctx, f = ctxMenuEl._file, i = ctxMenuEl._id;
      hideCtxMenu();
      if (act === 'rename') startRename(f, i, deps);
      else if (act === 'addtag') startAddTag(f, i, deps);
      else if (act === 'delete') softDelete(f, deps);
      else if (act === 'restore') restoreSession(f, deps);
      else if (act === 'deleteforever') deleteForever(f, deps);
    });
  }
  ctxMenuEl._file = file; ctxMenuEl._id = id;
  // A live session of another CLI can be restored but never permanently deleted (the file
  // belongs to that tool); imported copies (which live in our store) keep delete-forever.
  const s = findSession(id, file);
  const foreign = s && isForeignSource(s.source) && !s.imported;
  ctxMenuEl.innerHTML = (cs.activeDir === '__trash__')
    ? `<button type="button" class="conv-ctx-item" data-ctx="restore">↺ ${esc(L('conv.restore'))}</button>` +
      (foreign ? '' : `<button type="button" class="conv-ctx-item conv-ctx-danger" data-ctx="deleteforever">${icons.trash || '🗑'} ${esc(L('conv.deleteForever'))}</button>`)
    : `<button type="button" class="conv-ctx-item" data-ctx="rename">✎ ${esc(L('conv.ctxRename'))}</button>` +
      `<button type="button" class="conv-ctx-item" data-ctx="addtag"># ${esc(L('conv.ctxAddTag'))}</button>` +
      `<button type="button" class="conv-ctx-item conv-ctx-danger" data-ctx="delete">${icons.trash || '🗑'} ${esc(L('conv.ctxDelete'))}</button>`;
  ctxMenuEl.classList.remove('hidden');
  ctxMenuEl.style.left = Math.min(x, window.innerWidth - 180) + 'px';
  ctxMenuEl.style.top = Math.min(y, window.innerHeight - 80) + 'px';
}
