/* One conversation row in the left list: badges, tags, content-hit snippet, times. */
import { icons } from '../../core/icons.js';
import { esc, relTime, fmtSizeKB, SOURCE_NAMES, isForeignSource, readErrorKey, L } from './format.js';
import { cs, isLive } from './state.js';
import { markSnippet } from './search.js';

// Two timestamps: the session's start (createdAt, the sort key) and — only when it meaningfully
// differs — the last-updated time, so an edited/active session shows both without redundancy.
function metaTimes(c) {
  const created = c.createdAt || c.lastActivity;
  const start = `<span data-tip="${esc(L('conv.startedAt'))}">${esc(relTime(created))}</span>`;
  const updated = (c.lastActivity && created && c.lastActivity - created > 60000)
    ? `<span data-tip="${esc(L('conv.updatedAt'))}">${esc(L('conv.updatedPrefix'))} ${esc(relTime(c.lastActivity))}</span>`
    : '';
  return start + updated;
}

/** Trash-mode restore/delete-forever, or the imported-copy remove affordance. */
function rowActions(c) {
  // Recycle bin rows swap the import-remove affordance for restore + delete-forever; everywhere else
  // imported copies (which live only in the app store) keep their remove affordance.
  const inTrash = cs.activeDir === '__trash__';
  // A LIVE session of another CLI (codex/grok/copilot/antigravity/qoder, not an imported
  // copy) is that tool's file — it can be restored but NEVER permanently deleted, since the
  // app must not rm another tool's data.
  const foreign = isForeignSource(c.source) && !c.imported;
  const restoreBtn = `<button class="conv-restore ml-auto shrink-0 opacity-55 group-hover:opacity-100 text-caption hover:text-brand hover:bg-chip-bg rounded text-[12px] leading-none w-[18px] h-[18px] flex items-center justify-center transition-all" data-restore="${esc(c.file || '')}" title="${esc(L('conv.restore'))}">${icons.refresh || '↺'}</button>`;
  const deleteForeverBtn = `<button class="conv-delete-forever shrink-0 opacity-55 group-hover:opacity-100 text-caption hover:text-red hover:bg-chip-bg rounded text-[12px] leading-none w-[18px] h-[18px] flex items-center justify-center transition-all" data-delete-forever="${esc(c.file || '')}" title="${esc(L('conv.deleteForever'))}">${icons.trash || '✕'}</button>`;
  if (inTrash) return restoreBtn + (foreign ? '' : deleteForeverBtn);
  return c.imported ? `<button class="conv-remove-import ml-auto shrink-0 opacity-55 group-hover:opacity-100 text-caption hover:text-red hover:bg-chip-bg rounded text-[12px] leading-none w-[18px] h-[18px] flex items-center justify-center transition-all" data-remove-import="${esc(c.file || '')}" title="${esc(L('conv.removeImport'))}">✕</button>` : '';
}

export function sessionItem(c) {
  const live = isLive(c.lastActivity) ? '<span class="conv-live w-1.25 h-1.25 rounded-full bg-green animate-[pulse_1.6s_infinite] shrink-0"></span>' : '';
  const subLabel = [L('conv.subagent'), c.agentNickname].filter(Boolean).join(' · ');
  const sub = c.isSubagent ? `<span class="conv-badge text-[10.5px] px-1.5 py-0.25 rounded-full bg-chip-bg text-fg font-sans">${esc(subLabel)}</span>` : '';
  const imp = c.imported ? `<span class="conv-badge conv-badge-import inline-flex items-center gap-1 text-[10.5px] px-1.5 py-0.25 rounded-full bg-brand-soft text-brand font-sans">${icons.download || ''}${esc(L('conv.imported'))}</span>` : '';
  // Non-Claude sources carry a small origin chip so a mixed project group stays readable.
  const srcName = SOURCE_NAMES[c.source];
  const srcBadge = srcName ? `<span class="conv-badge conv-badge-source text-[10.5px] px-1.5 py-0.25 rounded-full bg-chip-bg text-fg font-sans">${esc(srcName)}</span>` : '';
  // A row whose transcript couldn't be read explains itself on hover instead of sitting as a
  // silent untitled entry (the reason only became visible after clicking before).
  const rerr = c.readError;
  const errBadge = rerr ? `<span class="conv-badge conv-badge-error text-[10.5px] px-1.5 py-0.25 rounded-full bg-chip-bg text-red font-sans" data-tip="${esc(L(readErrorKey(rerr.kind)))}">⚠</span>` : '';
  const rm = rowActions(c);
  const model = c.model ? `<span class="conv-model text-brand">${esc(c.model)}</span>` : '';
  // User tags (deletable: x; double-click to edit; click to filter). The import badge stays
  // separate and non-deletable. Empty when the conversation has no custom tags.
  const tags = (c.tags || []).map((t) =>
    `<span class="conv-tag ${t === cs.tagFilter ? 'active' : ''}" data-tag="${esc(t)}" data-file="${esc(c.file || '')}"><span class="conv-tag-label">${esc(t)}</span><button type="button" class="conv-tag-x" data-del-tag="${esc(t)}" data-file="${esc(c.file || '')}" title="${esc(L('conv.delTag'))}">×</button></span>`).join('');
  const tagsRow = tags ? `<div class="conv-item-tags" data-file="${esc(c.file || '')}">${tags}</div>` : '';
  // Content-search hit: show WHERE the query matched — a highlighted snippet, badged with the
  // subagent's type when the match lives inside one (clicking auto-opens there).
  const hit = (cs.search && cs.contentHits) ? cs.contentHits.get(c.file) : null;
  const snipRow = hit && hit.snippet
    ? `<div class="conv-item-snippet">${hit.agent && hit.agent !== 'main' ? `<span class="conv-snip-agent">🤖 ${esc(hit.agentType || L('conv.subagent'))}</span> ` : ''}${markSnippet(hit.snippet, cs.search)}${hit.count > 1 ? ` <span class="conv-snip-n">×${hit.count}</span>` : ''}</div>`
    : '';
  // Full title on hover; when a custom title overrides the auto one, also surface the original first line.
  const fullTitle = c.title || L('conv.untitled');
  const tip = (c.autoTitle && c.title && c.autoTitle !== c.title) ? (fullTitle + ' · ' + c.autoTitle) : fullTitle;
  const treeDepth = c.source === 'codex' && c.isSubagent ? Math.max(1, Math.min(Number(c.agentDepth) || 1, 5)) : 0;
  const treeIndent = 22 + treeDepth * 13;
  const treeMark = treeDepth ? '<span class="text-caption shrink-0" aria-hidden="true">↳</span>' : '';
  return `<div class="conv-item group cursor-pointer flex flex-col gap-0.75 py-2.5 pr-3 pl-[22px] transition-colors duration-150 hover:bg-chip-bg border-0 ${c.id === cs.openId ? 'active' : ''}" style="padding-left:${treeIndent}px" data-id="${esc(c.id)}" data-file="${esc(c.file || '')}">
      <div class="conv-item-top flex items-center gap-1.25">${treeMark}${live}<span class="conv-title text-[13.5px] font-semibold truncate min-w-0" data-tip="${esc(tip)}">${esc(fullTitle)}</span>${rm}</div>
      <div class="conv-item-sub flex items-center gap-1.5 text-[11.5px] text-caption font-mono truncate">${model}${srcBadge}${errBadge}${sub}${imp}</div>
      ${snipRow}
      ${tagsRow}
      <div class="conv-item-meta flex items-center gap-1.5 text-[11px] text-caption">${metaTimes(c)}${c.sizeKB ? '<span>' + fmtSizeKB(c.sizeKB) + '</span>' : ''}</div>
    </div>`;
}
