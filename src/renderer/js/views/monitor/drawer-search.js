/* In-body find bar for the request inspector (request/response bodies can be 100KB+). */
import { $, escapeHtml } from '../../core/dom.js';

const DR_MARK_CAP = 800;
let drBodyText = '', drBodyHTML = '', drMatches = [], drMatchIdx = -1;

export function drCodeEl() { const b = $('reqDrawerBody'); return b ? b.querySelector('.dr-pre code') : null; }

/** Reset the search model for a freshly-rendered body. */
export function setDrBody(text, html) {
  drBodyText = text; drBodyHTML = html; drMatches = []; drMatchIdx = -1;
}
export function getDrBodyText() { return drBodyText; }

function updateDrCount() {
  const c = $('reqDrawerBody') && $('reqDrawerBody').querySelector('.dr-search-count');
  if (!c) return;
  const shown = Math.min(drMatches.length, DR_MARK_CAP);
  c.textContent = drMatches.length ? `${drMatchIdx + 1}/${shown}${drMatches.length > DR_MARK_CAP ? '+' : ''}` : '0/0';
}

export function applyDrSearch(q) {
  const code = drCodeEl();
  if (!code) return;
  q = q || '';
  if (!q) { code.innerHTML = drBodyHTML; drMatches = []; drMatchIdx = -1; updateDrCount(); return; }
  const hay = drBodyText.toLowerCase(), needle = q.toLowerCase();
  drMatches = [];
  for (let i = hay.indexOf(needle); i !== -1; i = hay.indexOf(needle, i + needle.length)) drMatches.push(i);
  if (!drMatches.length) { code.innerHTML = escapeHtml(drBodyText); drMatchIdx = -1; updateDrCount(); return; }
  const n = Math.min(drMatches.length, DR_MARK_CAP);
  let html = '', last = 0;
  for (let k = 0; k < n; k++) {
    const pos = drMatches[k];
    html += escapeHtml(drBodyText.slice(last, pos)) + '<mark class="dr-mark">' + escapeHtml(drBodyText.slice(pos, pos + q.length)) + '</mark>';
    last = pos + q.length;
  }
  html += escapeHtml(drBodyText.slice(last));
  code.innerHTML = html;
  drMatchIdx = 0; drHighlightCurrent(); updateDrCount();
}

function drHighlightCurrent() {
  const code = drCodeEl();
  if (!code) return;
  const marks = code.querySelectorAll('.dr-mark');
  marks.forEach((m, i) => m.classList.toggle('cur', i === drMatchIdx));
  if (marks[drMatchIdx]) marks[drMatchIdx].scrollIntoView({ block: 'center' });
}

export function drNavSearch(dir) {
  const n = Math.min(drMatches.length, DR_MARK_CAP);
  if (!n) return;
  drMatchIdx = (drMatchIdx + dir + n) % n;
  drHighlightCurrent(); updateDrCount();
}

/** Wire the find-bar events on the (stable) drawer body container. */
export function bindDrawerSearch(reqDrawerBody) {
  let _drSearchT = null;
  reqDrawerBody.addEventListener('input', (e) => {
    if (!e.target.classList || !e.target.classList.contains('dr-search')) return;
    const v = e.target.value;
    clearTimeout(_drSearchT);
    _drSearchT = setTimeout(() => applyDrSearch(v), 110);
  });
  reqDrawerBody.addEventListener('keydown', (e) => {
    if (!e.target.classList || !e.target.classList.contains('dr-search')) return;
    if (e.key === 'Enter') { e.preventDefault(); drNavSearch(e.shiftKey ? -1 : 1); }
    else if (e.key === 'Escape') {
      if (e.target.value) { e.preventDefault(); e.stopPropagation(); e.target.value = ''; applyDrSearch(''); }
      else e.target.blur();
    }
  });
}
