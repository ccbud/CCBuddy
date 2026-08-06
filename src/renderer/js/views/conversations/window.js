/*
 * Windowed (virtualized) detail rendering — only [vStart, vEnd) of the active thread is ever
 * in the DOM. Browsing extends it via load-earlier/later; search/TOC jump renders a fresh
 * window around the target. Keeps the DOM bounded so collapse/resize/scroll stay cheap.
 */
import { $ } from '../../core/dom.js';
import { esc, L } from './format.js';
import { cs, activeMessages, DETAIL_WIN, LOAD_MORE, MAX_WIN } from './state.js';
import { renderMessage, buildResults } from './message.js';
import { highlight } from './code.js';
import { refreshWindowHighlights } from './search.js';

function winBtn(dir, n) {
  const lbl = esc(L('conv.loadEarlier', { n }));
  return `<button type="button" data-load-${dir} class="conv-load-earlier block mx-auto my-2 px-3.5 py-1.5 rounded-full bg-chip-bg text-muted text-[12px] font-medium cursor-pointer border border-border-custom hover:text-fg hover:bg-bg-elev transition-colors" title="${lbl}">${dir === 'earlier' ? '↑ ' : '↓ '}${lbl}</button>`;
}

/** HTML for the current window, plus load-earlier/later buttons. */
function renderWindow() {
  const messages = activeMessages();
  const total = messages.length;
  if (!total) return `<div class="conv-empty">${esc(L('conv.emptyConv'))}</div>`;
  const results = buildResults(messages); // scan ALL so tool_use cards resolve their result even if out of window
  const inSub = cs.activeAgent !== 'main'; // in a subagent view the whole panel is that agent — drop per-turn badge
  let html = cs.vStart > 0 ? winBtn('earlier', cs.vStart) : '';
  for (let i = cs.vStart; i < cs.vEnd; i++) html += renderMessage(messages[i], results, i, inSub);
  if (cs.vEnd < total) html += winBtn('later', total - cs.vEnd);
  return html || `<div class="conv-empty">${esc(L('conv.emptyConv'))}</div>`;
}

export function paintWindow() {
  const host = $('convDetail'); if (!host) return;
  host.innerHTML = renderWindow();
  highlight(host);
  refreshWindowHighlights(); // re-paint search highlights for the new window (no-op if not searching)
}

export function isNearBottom(el) { return el.scrollHeight - el.scrollTop - el.clientHeight < 120; }

// The first message whose bottom is below the viewport top, with its offset within the viewport —
// used to keep the view fixed across a repaint even when content is both added AND trimmed.
function visibleAnchor() {
  const host = $('convDetail'); if (!host) return null;
  const hr = host.getBoundingClientRect();
  const els = host.querySelectorAll('[data-mi]');
  for (const el of els) { const r = el.getBoundingClientRect(); if (r.bottom > hr.top + 2) return { mi: +el.dataset.mi, off: r.top - hr.top }; }
  return null;
}

function anchoredPaint(a) {
  paintWindow();
  const host = $('convDetail');
  const el = a && host && host.querySelector(`[data-mi="${a.mi}"]`);
  if (el) host.scrollTop += (el.getBoundingClientRect().top - host.getBoundingClientRect().top) - a.off;
}

// Extend the window upward / downward; trim the far end past MAX_WIN so the DOM stays bounded.
// Anchored on a currently-visible message so the viewport doesn't jump despite add+trim.
export function loadEarlier() {
  const host = $('convDetail'); if (!host || cs.vStart <= 0) return;
  const a = visibleAnchor();
  cs.vStart = Math.max(0, cs.vStart - LOAD_MORE);
  if (cs.vEnd - cs.vStart > MAX_WIN) cs.vEnd = cs.vStart + MAX_WIN; // trim the (off-screen) bottom
  anchoredPaint(a);
}

export function loadLater() {
  const host = $('convDetail'); if (!host) return;
  const total = activeMessages().length;
  if (cs.vEnd >= total) return;
  const a = visibleAnchor();
  cs.vEnd = Math.min(total, cs.vEnd + LOAD_MORE);
  if (cs.vEnd - cs.vStart > MAX_WIN) cs.vStart = cs.vEnd - MAX_WIN; // trim the (off-screen) top
  anchoredPaint(a);
}

/** Render a fresh window centred on message `mi` and bring it into view. */
export function jumpToMessage(mi, block) {
  const total = activeMessages().length;
  if (!total) return null;
  mi = Math.max(0, Math.min(total - 1, mi));
  if (mi < cs.vStart || mi >= cs.vEnd || cs.vEnd - cs.vStart > DETAIL_WIN * 2) {
    cs.vStart = Math.max(0, mi - Math.floor(DETAIL_WIN / 2));
    cs.vEnd = Math.min(total, cs.vStart + DETAIL_WIN);
    paintWindow();
  }
  const host = $('convDetail');
  const el = host && host.querySelector(`[data-mi="${mi}"]`);
  if (el) el.scrollIntoView({ block: block || 'center' });
  return el;
}
