/* Left list: project → session tree, dir chips, filtering, and the async content search. */
import { $ } from '../../core/dom.js';
import { api } from '../../core/bridge.js';
import { icons } from '../../core/icons.js';
import { esc, midEllip, L } from './format.js';
import { cs } from './state.js';
import { sessionItem } from './list-row.js';
import { orderSessionRows } from './list-order.js';

export async function refreshList() {
  try { cs.projects = (await api.historyProjects()) || []; } catch (_) { cs.projects = []; }
  // Fetch dir stats up front so activeDir (which renderList reads for trash mode) is set before
  // the list renders — and pass the data into renderDirSwitch to avoid a second round-trip.
  let dirData = null;
  if (api.historyDirs) { try { dirData = await api.historyDirs(); } catch (_) { dirData = null; } }
  cs.activeDir = (dirData && dirData.active) || 'all';
  renderDirSwitch(dirData);
  renderList();
}

export async function renderDirSwitch(pre) {
  const host = $('convDirSwitch');
  if (!host || !api.historyDirs) return;
  let data = pre;
  if (!data) { try { data = await api.historyDirs(); } catch (_) { data = { dirs: [], active: 'all' }; } }
  const active = data.active || 'all';
  const allDirs = data.dirs || [];
  // Recycle bin: a synthetic bucket of soft-deleted sessions. Surface its chip whenever something
  // is in it (or it's the active view), so single-dir users still get an entry point.
  const trashEntry = allDirs.find((d) => d.id === '__trash__' || d.trash);
  const trashN = trashEntry ? (trashEntry.sessions || 0) : 0;
  const showTrash = trashN > 0 || active === '__trash__';
  // Hide the synthetic 导入 chip until something is actually imported (keeps the bar clean /
  // unchanged for single-dir users). The + button is the import entry point regardless.
  const dirs = allDirs.filter((d) => d.id !== '__trash__' && !d.trash && !(d.imported && !d.sessions));
  const showDirs = dirs.length > 1;
  if (!showDirs && !showTrash) { host.classList.add('hidden'); host.innerHTML = ''; return; }
  const opts = [{ id: 'all', label: L('conv.all') }].concat(showDirs ? dirs.map((d) => ({ id: d.id, label: d.id === '__imported__' ? L('conv.importedDir') : d.label, imported: d.imported, sessions: d.sessions })) : []);
  host.classList.remove('hidden');
  let html = opts.map((o) => `<button class="dir-chip inline-flex items-center gap-1.25 border border-border-custom bg-transparent text-muted font-medium text-[11.5px] px-2.5 py-1 rounded-full cursor-pointer transition-all duration-150 hover:text-fg hover:bg-chip-bg whitespace-nowrap ${o.id === active ? 'active' : ''}" data-dir="${esc(o.id)}" title="${esc(o.label)}">${o.imported ? '<span class="dir-chip-ico">' + (icons.download || '') + '</span>' : ''}${esc(midEllip(o.label, 30))}${o.sessions != null ? ' <span class="dir-chip-n text-[10px] px-1.25 py-0 rounded-full bg-black/12">' + o.sessions + '</span>' : ''}</button>`).join('');
  if (showTrash) {
    html += `<button class="dir-chip dir-chip-trash inline-flex items-center gap-1.25 border border-border-custom bg-transparent text-muted font-medium text-[11.5px] px-2.5 py-1 rounded-full cursor-pointer transition-all duration-150 hover:text-fg hover:bg-chip-bg whitespace-nowrap ${active === '__trash__' ? 'active' : ''}" data-dir="__trash__" title="${esc(L('conv.trash'))}"><span class="dir-chip-ico">${icons.trash || ''}</span>${esc(L('conv.trash'))}${trashN ? ' <span class="dir-chip-n text-[10px] px-1.25 py-0 rounded-full bg-black/12">' + trashN + '</span>' : ''}</button>`;
  }
  host.innerHTML = html;
}

function filteredProjects() {
  if (!cs.search && !cs.tagFilter) return cs.projects;
  const q = cs.search.toLowerCase();
  return cs.projects
    .map((p) => {
      const sessions = p.sessions.filter((s) => {
        if (cs.tagFilter && (s.tags || []).indexOf(cs.tagFilter) < 0) return false;
        if (!q) return true;
        if ((s.title || '').toLowerCase().includes(q) ||
          (s.model || '').toLowerCase().includes(q) ||
          (p.name || '').toLowerCase().includes(q) ||
          (s.tags || []).some((t) => t.toLowerCase().includes(q))) return true;
        // Content match (async backend scan of message bodies, incl. subagents) — see
        // scheduleContentSearch; these rows carry a snippet in sessionItem.
        return !!(cs.contentHits && cs.contentHits.has(s.file));
      });
      return sessions.length ? Object.assign({}, p, { sessions }) : null;
    })
    .filter(Boolean);
}

// Big-search content matching: ask the backend to scan session BODIES (message text, thinking,
// tool calls/results — main thread, every subagent transcript, codex rollouts) for the query.
// Debounced per keystroke; responses for a superseded query are dropped. Field filtering above
// stays instant — content hits merge into the same list as they arrive.
export function scheduleContentSearch() {
  clearTimeout(cs.contentTimer);
  cs.contentSeq++;
  cs.contentHits = null;
  cs.contentSearching = false;
  const q = cs.search;
  if (!q || !api.historySearch) return;
  cs.contentSearching = true;
  const seq = cs.contentSeq;
  cs.contentTimer = setTimeout(async () => {
    let res = null;
    try { res = await api.historySearch(q); } catch (_) { res = null; }
    if (seq !== cs.contentSeq) return; // a newer query took over while this one was scanning
    cs.contentSearching = false;
    const map = new Map();
    for (const h of (Array.isArray(res) ? res : [])) if (h && h.file) map.set(h.file, h);
    cs.contentHits = map;
    renderList();
  }, 220);
}

export function renderList() {
  const el = $('convList');
  if (!el) return;
  const list = filteredProjects();
  const total = list.reduce((n, p) => n + p.sessions.length, 0);
  const fbar = cs.tagFilter
    ? `<div class="conv-tagfilter">🏷 <span class="conv-tag active"><span class="conv-tag-label">${esc(cs.tagFilter)}</span><button type="button" class="conv-tag-x" data-clear-tagfilter title="${esc(L('conv.clearTagFilter'))}">×</button></span></div>`
    : '';
  if (!total) {
    const emptyMsg = (cs.search || cs.tagFilter)
      ? esc(cs.search && cs.contentSearching ? L('conv.searching') : L('conv.noMatch'))
      : (cs.activeDir === '__trash__'
        ? esc(L('conv.trashEmpty'))
        : esc(L('conv.noLocal')) + '<br><span class="text-muted text-[11px]">~/.claude/projects</span>');
    el.innerHTML = fbar + `<div class="state-inline py-6 px-3 text-center text-[11.5px] text-caption" style="padding:24px 12px">${emptyMsg}</div>`;
    return;
  }
  el.innerHTML = fbar + list.map((p) => {
    const isCol = cs.collapsed.has(p.cwd || p.name) && !cs.search;
    const items = isCol ? '' : `<div class="conv-proj-sessions">${orderSessionRows(p.sessions).map(sessionItem).join('')}</div>`;
    return `<div class="conv-proj border-b border-border-custom">
        <div class="conv-proj-head flex items-center gap-1.5 px-3 py-2 cursor-pointer sticky top-0 z-10 bg-bg-sidebar/90 backdrop-blur-md select-none hover:bg-chip-bg transition-colors duration-150" data-proj="${esc(p.cwd || p.name)}">
          <span class="conv-proj-caret text-[10px] text-caption w-2.5 shrink-0">${isCol ? '▸' : '▾'}</span>
          <span class="conv-proj-name text-[12.5px] font-bold text-fg tracking-tight truncate flex-1" data-tip="${esc(p.cwd || p.name || '')}">${esc(p.name || L('conv.unknownProject'))}</span>
          <span class="conv-proj-count text-[10.5px] font-semibold text-muted bg-chip-bg px-1.75 py-0.25 rounded-full shrink-0">${p.sessions.length}</span>
        </div>${items}
      </div>`;
  }).join('');
}
