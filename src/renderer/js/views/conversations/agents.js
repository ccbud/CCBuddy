/* Moving the main panel between threads (main ↔ subagent) and focusing a subagent at its call site. */
import { $ } from '../../core/dom.js';
import { cs, activeMessages, DETAIL_WIN } from './state.js';
import { paintWindow, jumpToMessage } from './window.js';
import { renderAgentTabs, renderSidePanels } from './panels.js';
import { clearDetailSearchHighlights } from './search.js';
import { subChain, expandChain } from './subagents.js';

// Move the panel to another thread KEEPING search state — used by cross-agent search navigation
// and the big-search auto-locate, where the jump that follows paints the window. Resets the window
// to "unpainted" so the follow-up jumpToMessage always renders fresh.
export function setPanelAgent(key) {
  if (!cs.currentDetail || key === cs.activeAgent) return;
  cs.agentMenuOpen = false;
  cs.activeAgent = key;
  cs.vStart = 0; cs.vEnd = 0;
  renderAgentTabs(cs.currentDetail);
  renderSidePanels(cs.currentDetail);
}

// User-driven move of the main panel to a different session (main thread or a subagent). Resets
// the render window + search and repaints from the bottom, exactly like opening a fresh conversation.
export function switchAgent(key) {
  cs.agentMenuOpen = false;
  if (key === cs.activeAgent) { renderAgentTabs(cs.currentDetail); return; }
  clearDetailSearchHighlights();
  const ds = $('convDetailSearch'); if (ds) ds.value = '';
  setPanelAgent(key);
  const total = activeMessages().length;
  cs.vEnd = total; cs.vStart = Math.max(0, total - DETAIL_WIN);
  paintWindow();
  const host = $('convDetail'); if (host) host.scrollTop = host.scrollHeight;
}

// Bring a subagent into view AT ITS CALL SITE: jump the main thread to the outermost spawning turn,
// then expand each disclosure down the chain (filling lazily) and scroll/flash the target. Falls back
// to the standalone full-panel view when the call site is unknown, so orphan subagents stay reachable.
export function focusSubagent(key) {
  cs.agentMenuOpen = false;
  const menu = document.querySelector('#convAgentTabs .conv-agent-menu');
  if (menu) menu.classList.add('hidden'); // close the picker immediately as click feedback
  if (!cs.currentDetail || !(cs.currentDetail.subagents || {})[key]) return;
  const chain = subChain(key);
  if (!chain.length) { switchAgent(key); return; } // call site unknown → standalone full-panel view
  if (cs.activeAgent !== 'main') setPanelAgent('main'); // search docs span all threads — no rebuild
  const top = cs.subIndex.callSite.get(chain[0]); // { thread:'main', mi }
  jumpToMessage(top.mi, 'center');
  const det = expandChain(chain);
  renderAgentTabs(cs.currentDetail);
  if (!det) { switchAgent(key); return; } // couldn't place it inline → don't leave the click doing nothing
  // Land on the spawning CALL (the tool card), not the middle of the now-tall subagent body, so the
  // "why did this subagent appear" context reads top-down. Flash the whole block so it's unmistakable.
  const anchor = det.closest('.tool-card') || det;
  anchor.scrollIntoView({ block: 'start' });
  const host = $('convDetail');
  if (host) host.scrollTop = Math.max(0, host.scrollTop - 48);
  det.classList.remove('sub-flash');
  requestAnimationFrame(() => {
    det.classList.add('sub-flash');
    setTimeout(() => det.classList.remove('sub-flash'), 2200);
  });
}
