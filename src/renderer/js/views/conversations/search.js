/*
 * In-conversation search — DATA-driven: matches are found in the parsed message text (fast, no
 * DOM) across EVERY thread of the open session, so search never has to render the whole thread.
 * Navigation steps through matching messages and switches the panel across thread boundaries.
 */
import { $ } from '../../core/dom.js';
import { esc, escapeRegExp, normContent, contentToText } from './format.js';
import { stripInjected } from './codex-format.js';
import { cs, threadMessages } from './state.js';
import { buildResults } from './message.js';
import { buildSubIndex } from './subagents.js';
import { jumpToMessage } from './window.js';

const hasHighlightAPI = () => !!(window.CSS && CSS.highlights && typeof Highlight !== 'undefined');

export function clearDetailSearchHighlights() {
  if (hasHighlightAPI()) { CSS.highlights.delete('cd-search'); CSS.highlights.delete('cd-current'); }
  cs.searchOcc = []; cs.searchIndex = -1; cs.searchQuery = ''; cs.searchTotalOcc = 0;
  const countEl = $('convDetailSearchCount');
  if (countEl) countEl.textContent = '';
}

// Mirror renderMessage's logic so a thread's texts[i] is non-empty iff message i actually renders,
// and holds the SAME searchable text (incl. tool results, which render inside the assistant's tool
// card — not the user turn that carries them). Keeps search matches aligned with rendered messages.
function messagePlainText(m, results) {
  const blocks = normContent(m.content);
  const skillLoads = blocks.filter((b) => b && b.type === 'skill_load');
  if (skillLoads.length) {
    return skillLoads.map((b) => [b.name, b.path, b.snapshot].filter(Boolean).join('\n')).join('\n');
  }
  if (m.role === 'user') {
    const vis = blocks.filter((b) => b.type === 'text' || b.type === 'image');
    if (!vis.length) return '';
    // Same stripping renderMessage applies: injected reminders/commands are unsearchable, but the
    // human prose beside them (e.g. the first turn, which carries a reminder) IS.
    return vis.map((b) => (b.type === 'text' ? stripInjected(b.text) : '')).filter(Boolean).join('\n');
  }
  let s = '';
  for (const b of blocks) {
    if (b.type === 'text') s += (b.text || '') + '\n';
    else if (b.type === 'thinking') s += (b.thinking || '') + '\n';
    else if (b.type === 'tool_use') { s += (b.name || '') + ' ' + (b.input ? JSON.stringify(b.input) : '') + '\n'; const r = results && results[b.id]; if (r) s += contentToText(r.content) + '\n'; }
  }
  return s;
}

// Thread keys in reading order — main first, then subagents by where they were spawned in the
// main thread (unresolved call sites sort last). Cross-agent search steps through this order.
export function searchAgentOrder() {
  const subs = (cs.currentDetail && cs.currentDetail.subagents) || {};
  const keys = Object.keys(subs);
  if (!keys.length) return ['main'];
  if (!cs.subIndex) buildSubIndex();
  const pos = (k) => { const site = cs.subIndex.callSite.get(k); return site && site.thread === 'main' ? site.mi : Infinity; };
  keys.sort((a, b) => pos(a) - pos(b));
  return ['main'].concat(keys);
}

function buildSearchDocs() {
  cs.searchDocs = new Map();
  for (const agent of searchAgentOrder()) {
    const msgs = threadMessages(agent);
    const results = buildResults(msgs);
    cs.searchDocs.set(agent, msgs.map((m) => messagePlainText(m, results)));
  }
}

// Highlight every match inside the CURRENT window via the CSS Custom Highlight API (Range-based, zero
// DOM mutation). The window is bounded, so this is tiny + fast. Re-run after each window paint.
export function refreshWindowHighlights() {
  if (!hasHighlightAPI()) return;
  const host = $('convDetail');
  if (!host || !cs.searchQuery) { CSS.highlights.delete('cd-search'); return; }
  let re; try { re = new RegExp(escapeRegExp(cs.searchQuery), 'gi'); } catch (_) { return; }
  const h = new Highlight();
  const w = document.createTreeWalker(host, NodeFilter.SHOW_TEXT, null); let node;
  while ((node = w.nextNode())) {
    const text = node.nodeValue; if (!text || !text.trim()) continue; re.lastIndex = 0; let m;
    while ((m = re.exec(text)) !== null) {
      try { const r = document.createRange(); r.setStart(node, m.index); r.setEnd(node, m.index + m[0].length); h.add(r); } catch (_) {}
      if (m[0].length === 0) re.lastIndex++;
    }
  }
  CSS.highlights.set('cd-search', h);
}

export function updateSearchCount() {
  const c = $('convDetailSearchCount'); if (!c) return;
  if (!cs.searchOcc.length) { c.textContent = cs.searchQuery ? '0/0' : ''; return; }
  const pos = cs.searchIndex >= 0 ? String(cs.searchIndex + 1) : '–';
  c.textContent = `${pos}/${cs.searchOcc.length}` + (cs.searchTotalOcc > cs.searchOcc.length ? ` · ${cs.searchTotalOcc}` : '');
}

// Run the message search across EVERY thread (main + subagents). Landing rules:
//  - opts.agent (big-search auto-locate): jump to that thread's first match, switching the panel;
//  - opts.first (Enter confirm): jump to the first match overall, switching if needed;
//  - opts.silent (live refresh): recompute counts/highlights only, never move the view;
//  - default (typing): jump only within the CURRENT thread — matches elsewhere just show in the
//    count until the user navigates (Enter / ↑↓), so the panel never switches under the cursor.
export function performDetailSearch(query, opts) {
  opts = opts || {};
  cs.searchQuery = query || '';
  if (hasHighlightAPI()) { CSS.highlights.delete('cd-search'); CSS.highlights.delete('cd-current'); }
  cs.searchOcc = []; cs.searchIndex = -1; cs.searchTotalOcc = 0;
  const c = $('convDetailSearchCount');
  if (!query) { if (c) c.textContent = ''; return; }
  if (!cs.searchDocs) buildSearchDocs();
  let re; try { re = new RegExp(escapeRegExp(query), 'gi'); } catch (_) { return; }
  // Scan the parsed message texts (NOT the DOM) — each matching message lists once in searchOcc,
  // and every match inside it is highlighted on arrival. Map iteration = insertion order =
  // reading order (main first, then subagents by call site), so navigation is deterministic.
  for (const [agent, texts] of cs.searchDocs) {
    for (let i = 0; i < texts.length; i++) {
      const t = texts[i]; if (!t) continue; re.lastIndex = 0; let m, has = false;
      while ((m = re.exec(t)) !== null) { cs.searchTotalOcc++; has = true; if (m[0].length === 0) re.lastIndex++; }
      if (has) cs.searchOcc.push({ agent, mi: i });
    }
  }
  if (!cs.searchOcc.length) { if (c) c.textContent = '0/0'; return; }
  if (opts.silent) { updateSearchCount(); refreshWindowHighlights(); return; }
  let target = -1;
  if (opts.agent) { target = cs.searchOcc.findIndex((o) => o.agent === opts.agent); if (target < 0) target = 0; }
  else if (opts.first) target = 0;
  else target = cs.searchOcc.findIndex((o) => o.agent === cs.activeAgent);
  if (target >= 0) gotoDetailSearchMatch(target);
  else { updateSearchCount(); refreshWindowHighlights(); } // matches exist, none here — count only
}

// Navigate to match #newIndex (wraps): switch the panel to the match's thread when it lives in a
// different agent, bring the message into the window, highlight every match in the window, and
// mark + centre the first match in the target message. Bounded — never renders a whole thread.
export function gotoDetailSearchMatch(newIndex, setPanelAgent) {
  const len = cs.searchOcc.length; if (!len) return;
  cs.searchIndex = ((newIndex % len) + len) % len;
  const occ = cs.searchOcc[cs.searchIndex];
  if (occ.agent !== cs.activeAgent && setPanelAgent) setPanelAgent(occ.agent); // cross-agent step
  const mi = occ.mi;
  jumpToMessage(mi, 'center');
  refreshWindowHighlights();
  const host = $('convDetail');
  const el = host && host.querySelector(`[data-mi="${mi}"]`);
  const skillSnapshot = el && el.querySelector('.skill-snapshot');
  const skillBody = skillSnapshot && skillSnapshot.querySelector('.skill-snapshot-body');
  if (skillSnapshot && skillBody && cs.searchQuery
    && String(skillBody.textContent || '').toLocaleLowerCase().includes(cs.searchQuery.toLocaleLowerCase())) {
    skillSnapshot.open = true;
    refreshWindowHighlights();
  }
  if (el && hasHighlightAPI() && cs.searchQuery) {
    let re; try { re = new RegExp(escapeRegExp(cs.searchQuery), 'gi'); } catch (_) { re = null; }
    let curRange = null;
    if (re) {
      const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null); let node;
      while ((node = w.nextNode()) && !curRange) {
        const text = node.nodeValue; if (!text) continue; re.lastIndex = 0; const m = re.exec(text);
        if (m) { curRange = document.createRange(); curRange.setStart(node, m.index); curRange.setEnd(node, m.index + m[0].length); }
      }
    }
    if (curRange) {
      const cur = new Highlight(); cur.add(curRange); CSS.highlights.set('cd-current', cur);
      const rect = curRange.getBoundingClientRect(); const hr = host.getBoundingClientRect();
      if (rect && hr && rect.height) host.scrollTop += (rect.top - hr.top) - host.clientHeight / 2;
    }
  }
  updateSearchCount();
}

/** Escape a content snippet and wrap query matches in <mark> for the session row. */
export function markSnippet(text, q) {
  const s = String(text || '');
  if (!q) return esc(s);
  let re; try { re = new RegExp(escapeRegExp(q), 'gi'); } catch (_) { return esc(s); }
  let out = '', last = 0, m;
  while ((m = re.exec(s)) !== null) {
    out += esc(s.slice(last, m.index)) + '<mark>' + esc(m[0]) + '</mark>';
    last = m.index + m[0].length;
    if (m[0].length === 0) re.lastIndex++;
  }
  return out + esc(s.slice(last));
}
