/* Detail-pane event wiring: TOC, agent tabs, message search, window loading, toolbar actions. */
import { $ } from '../../core/dom.js';
import { cs } from './state.js';
import { jumpToMessage, loadEarlier, loadLater } from './window.js';
import { performDetailSearch, gotoDetailSearchMatch, clearDetailSearchHighlights } from './search.js';
import { setPanelAgent, switchAgent, focusSubagent } from './agents.js';
import { fillSubBody } from './subagents.js';
import { doCopyPath, doReplay, doChatgpt, doExport, hideExportMenu, updateToolbarLayout } from './actions.js';

const goto = (i) => gotoDetailSearchMatch(i, setPanelAgent);

function bindAgentTabs() {
  // Session tabs: [主会话] [子代理 (N) ▾]. The dropdown lists subagents; picking one jumps the main
  // thread to where it was spawned and expands it inline there (focusSubagent), so it reads in context.
  const tabs = $('convAgentTabs');
  tabs.addEventListener('click', (e) => {
    if (e.target.closest('[data-agent-dd]')) {
      cs.agentMenuOpen = !cs.agentMenuOpen;
      const menu = tabs.querySelector('.conv-agent-menu');
      if (menu) menu.classList.toggle('hidden', !cs.agentMenuOpen);
      return;
    }
    const it = e.target.closest('[data-agent]');
    if (it) { if (it.dataset.agent === 'main') switchAgent('main'); else focusSubagent(it.dataset.agent); }
  });
  // Close the subagent menu when clicking outside the tab bar.
  document.addEventListener('click', (e) => {
    if (!cs.agentMenuOpen) return;
    if (e.target.closest('#convAgentTabs')) return;
    cs.agentMenuOpen = false;
    const menu = document.querySelector('#convAgentTabs .conv-agent-menu');
    if (menu) menu.classList.add('hidden');
  });
}

function bindDetailSearch() {
  // Typing searches (and highlights) without pulling the view to another agent; Enter CONFIRMS —
  // it jumps straight to the first match, switching to its thread if needed — and further Enter
  // presses step next/previous (Shift). ↑/↓ step across agents too.
  const dsearch = $('convDetailSearch');
  let t;
  dsearch.addEventListener('input', () => { clearTimeout(t); t = setTimeout(() => performDetailSearch(dsearch.value.trim()), 200); });
  dsearch.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      const q = dsearch.value.trim();
      clearTimeout(t);
      if (q !== cs.searchQuery) performDetailSearch(q, { first: true });
      else if (cs.searchOcc.length) goto(cs.searchIndex < 0 ? 0 : cs.searchIndex + (e.shiftKey ? -1 : 1));
    }
    if (e.key === 'Escape') { dsearch.value = ''; clearDetailSearchHighlights(); }
  });
  $('convDetailSearchPrev').addEventListener('click', () => { if (cs.searchOcc.length) goto(cs.searchIndex < 0 ? -1 : cs.searchIndex - 1); });
  $('convDetailSearchNext').addEventListener('click', () => { if (cs.searchOcc.length) goto(cs.searchIndex < 0 ? 0 : cs.searchIndex + 1); });
  $('convDetailSearchClear').addEventListener('click', () => { const inp = $('convDetailSearch'); if (inp) inp.value = ''; clearDetailSearchHighlights(); });
}

function bindDetailHost() {
  // Load-earlier / load-later (delegated; #convDetail is stable, its innerHTML isn't).
  $('convDetail').addEventListener('click', (e) => {
    // Markdown preview ↔ source toggle (Read/Write of .md files).
    const mdTab = e.target.closest('.md-tab');
    if (mdTab) {
      const doc = mdTab.closest('.md-doc');
      if (doc) {
        const which = mdTab.dataset.mdTab;
        doc.querySelectorAll('.md-tab').forEach((tab) => tab.classList.toggle('active', tab === mdTab));
        const prev = doc.querySelector('.md-preview'); if (prev) prev.classList.toggle('hidden', which !== 'preview');
        const src = doc.querySelector('.md-source'); if (src) src.classList.toggle('hidden', which !== 'source');
      }
      return;
    }
    if (e.target.closest('[data-load-earlier]')) { loadEarlier(); return; }
    if (e.target.closest('[data-load-later]')) { loadLater(); return; }
    // Lazily render an inline subagent transcript the first time its disclosure is opened (its
    // children render the same way, so the tree fills one level per click — never all at once).
    const sum = e.target.closest('.subagent-inline > summary');
    if (sum) fillSubBody(sum.parentElement);
  });
}

function bindToolbar() {
  $('convCopyPathBtn').addEventListener('click', doCopyPath);
  const replayBtn = $('convReplayBtn');
  replayBtn.addEventListener('click', () => doReplay(replayBtn));
  const chatgptBtn = $('convChatgptBtn');
  chatgptBtn.addEventListener('click', () => doChatgpt(chatgptBtn));

  const moreBtn = $('convMoreBtn');
  const moreMenu = $('convMoreMenu');
  moreBtn.addEventListener('click', (e) => { e.stopPropagation(); if (moreBtn.disabled) return; moreMenu.classList.toggle('hidden'); });
  moreMenu.addEventListener('click', (e) => {
    const it = e.target.closest('[data-more]'); if (!it) return;
    moreMenu.classList.add('hidden');
    const a = it.dataset.more;
    if (a === 'replay') doReplay();
    else if (a === 'chatgpt') doChatgpt();
    else if (a === 'copyPath') doCopyPath();
    else if (a === 'jsonl') doExport('jsonl');
    else if (a === 'html') doExport('html');
  });
  document.addEventListener('click', (e) => { if (!e.target.closest('.conv-more-wrap')) moreMenu.classList.add('hidden'); });

  // Responsive toolbar: collapse the action buttons into the "⋯" menu when space is tight.
  const toolbar = document.querySelector('.conv-detail-toolbar');
  if (toolbar && window.ResizeObserver) new ResizeObserver(() => updateToolbarLayout()).observe(toolbar);
  updateToolbarLayout();

  // Export menu (JSONL / HTML)
  const exportBtn = $('convExportBtn');
  exportBtn.addEventListener('click', (e) => { e.stopPropagation(); if (exportBtn.disabled) return; const m = $('convExportMenu'); if (m) m.classList.toggle('hidden'); });
  $('convExportMenu').addEventListener('click', (e) => { const it = e.target.closest('[data-export]'); if (it) doExport(it.dataset.export); });
  document.addEventListener('click', (e) => { if (!e.target.closest('.conv-export-wrap')) hideExportMenu(); });
}

export function bindDetailEvents() {
  $('convToc').addEventListener('click', (e) => { const it = e.target.closest('.toc-item'); if (it) jumpToMessage(+it.dataset.go, 'start'); });
  bindAgentTabs();
  bindDetailSearch();
  bindDetailHost();
  bindToolbar();
}
