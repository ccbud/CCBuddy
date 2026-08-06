/* Open a conversation, (re)load its transcript, and drive the windowed repaint + live follow. */
import { $ } from '../../core/dom.js';
import { api } from '../../core/bridge.js';
import { ensureVendor } from '../../core/loader.js';
import { esc, readErrorKey, L } from './format.js';
import { cs, activeMessages, openSessionLive, DETAIL_WIN } from './state.js';
import { renderList } from './list.js';
import { paintWindow, isNearBottom } from './window.js';
import { performDetailSearch, clearDetailSearchHighlights, updateSearchCount } from './search.js';
import { renderSidePanels, renderAgentTabs, syncConvNav } from './panels.js';

/** Drop all transcript-derived UI while a different session loads or the current read fails.
    openFile/openId deliberately stay untouched, so the selected row and navigation rail remain
    present and a later retry can recover in place without showing data from the previous session. */
export function clearLoadedDetail() {
  cs.currentDetail = null;
  cs.searchDocs = null;
  cs.subIndex = null;
  renderAgentTabs(null);
  const stats = $('convStats'); if (stats) stats.innerHTML = '';
  const toc = $('convToc'); if (toc) toc.innerHTML = '';
}

export async function openConversation(id, file) {
  const ds = $('convDetailSearch');
  if (ds) ds.value = '';
  clearDetailSearchHighlights();
  cs.openId = id; cs.openFile = file || null;
  syncConvNav();
  cs.activeAgent = 'main'; // new conversation always opens on its main thread
  cs.detailRetry = null;
  clearLoadedDetail();
  cs.vStart = 0; cs.vEnd = 0; // reset the render window for the new conversation
  cs.lastRender = { file: null, count: -1 };
  ['convExportBtn', 'convCopyPathBtn', 'convReplayBtn', 'convChatgptBtn', 'convMoreBtn'].forEach((btnId) => {
    const b = $(btnId); if (b) b.disabled = !cs.openFile;
  });
  renderList();
  // Big sessions take a beat to read+parse off disk — show a loading hint during the async fetch
  // (this wait is genuinely async/IPC, so the hint paints; the later render is what's kept bounded).
  const host = $('convDetail');
  if (host && cs.openFile) host.innerHTML = `<div class="conv-empty">${esc(L('conv.loading'))}</div>`;
  await rerenderDetail(true);
  // Opened from a big-search content hit: restore the query in the message search box, move the
  // panel to the matched thread (subagent hits switch automatically), and land on the match.
  // The openFile identity check drops the jump when another session was opened mid-load.
  if (cs.pendingLocate && cs.openFile && cs.openFile === (file || null) && cs.currentDetail) {
    const pl = cs.pendingLocate; cs.pendingLocate = null;
    if (ds) ds.value = pl.query;
    performDetailSearch(pl.query, { agent: pl.agent || 'main' });
  }
}

/** Total rendered-content length across main + subagent threads — the change key for re-render skipping. */
function contentShape(detail) {
  const messages = detail.messages || [];
  const msgLen = (m) => {
    if (!m || !m.content) return 0;
    if (typeof m.content === 'string') return m.content.length;
    if (Array.isArray(m.content)) return m.content.reduce((sum, b) => sum + (b.text ? b.text.length : 0) + (b.thinking ? b.thinking.length : 0), 0);
    return 0;
  };
  let contentLen = messages.reduce((acc, m) => acc + msgLen(m), 0);
  // Fold subagent growth into the change key too: while a subagent streams, the main thread can
  // sit idle, and the skip-guard would otherwise freeze the nested subagent view mid-run.
  const subs = detail.subagents || {};
  let subCount = 0;
  for (const k of Object.keys(subs)) {
    const sm = (subs[k] && subs[k].messages) || [];
    subCount += sm.length;
    contentLen += sm.reduce((acc, m) => acc + msgLen(m), 0);
  }
  return { count: messages.length, contentLen, subCount };
}

/** Show a read failure and schedule the right retry cadence. */
function showLoadError(host, loadError) {
  const kind = loadError && loadError.kind;
  const key = !loadError ? 'conv.notFound' : readErrorKey(kind);
  host.innerHTML = `<div class="conv-empty">${esc(L(key))}</div>`;
  clearLoadedDetail();
  // A missing/moved path is not expected to recover in place. Permission failures re-probe at
  // the timer's steady 4s; other read/IPC failures back off (4s → 60s cap) per attempt.
  if (key === 'conv.notFound') {
    cs.detailRetry = null;
  } else {
    const file = cs.openFile;
    const attempts = (cs.detailRetry && cs.detailRetry.file === file ? cs.detailRetry.attempts : 0) + 1;
    const delay = kind === 'permissionDenied' ? 0 : Math.min(4000 * 2 ** (attempts - 1), 60000);
    cs.detailRetry = { file, attempts, nextAt: Date.now() + delay };
  }
  cs.lastRender = { file: null, count: -1 };
}

export async function rerenderDetail(force) {
  if (!cs.openFile) return;
  const requestedFile = cs.openFile;
  // The live/error retry timer can fire while a slower helper-backed Qoder read is still running.
  // One request for the currently-selected file is enough; a genuinely different selection may
  // start immediately and its newer sequence invalidates this result.
  if (cs.detailRequest && cs.detailRequest.file === requestedFile) {
    if (force) cs.detailRequest.force = true; // preserve a language-change/re-open forced paint
    return;
  }
  const request = { seq: ++cs.detailRequestSeq, file: requestedFile, force: !!force };
  cs.detailRequest = request;
  let detail = null;
  let ipcReadFailed = false;
  // Markdown + syntax highlighting are only needed once a transcript actually renders.
  const vendor = ensureVendor().catch(() => {});
  try { detail = await api.historyGet(requestedFile); } catch (_) { ipcReadFailed = true; }
  await vendor;
  if (cs.detailRequest === request) cs.detailRequest = null;
  // A→B (or A→B→A) can leave older IPC calls in flight. Never let their success/error overwrite
  // the latest selection, even when the path happens to match again after an intervening click.
  if (cs.openFile !== requestedFile || request.seq !== cs.detailRequestSeq) return;
  force = request.force;
  const host = $('convDetail');
  if (!host) return;
  // A failed read is distinct from a missing/moved transcript. Keep openFile intact so the
  // selected row + navigation rail remain open and a later retry (for example after granting
  // macOS access to Qoder's data) can recover in place.
  const loadError = ipcReadFailed ? { kind: 'readFailed' } : (detail && detail.error);
  if (loadError || !detail) { showLoadError(host, loadError); return; }
  cs.detailRetry = null;
  cs.currentDetail = detail;
  cs.subIndex = null; // call-site map is rebuilt lazily against the freshly-loaded subagents

  const shape = contentShape(detail);
  // Skip needless re-renders: on-disk turns are written whole, so a stable message count
  // and content length means nothing changed — preserves scroll + expanded thinking/result panels.
  if (!force && cs.lastRender.file === cs.openFile && cs.lastRender.count === shape.count
    && cs.lastRender.contentLen === shape.contentLen && cs.lastRender.subCount === shape.subCount
    && host.querySelector('.msg')) return;

  const total = activeMessages().length; // window/paint follow the ACTIVE session (main or subagent)
  const wasBottom = isNearBottom(host);
  cs.searchDocs = null; // content changed (or fresh open) — search docs rebuild lazily on next use
  if (force) {
    clearDetailSearchHighlights();
    // A still-running session opens at the newest turns (trailing window, pinned to the bottom) so
    // it live-follows. A finished history conversation opens at the START — leading window scrolled
    // to the top — so the first human message is what you see, not the tail. (Subagent threads, which
    // have no live-follow semantics, also read top-down.)
    if (cs.activeAgent === 'main' && openSessionLive()) {
      cs.vEnd = total; cs.vStart = Math.max(0, total - DETAIL_WIN);
      paintWindow();
      host.scrollTop = host.scrollHeight;
    } else {
      cs.vStart = 0; cs.vEnd = Math.min(total, DETAIL_WIN);
      paintWindow();
      host.scrollTop = 0;
    }
  } else if (wasBottom) {
    // live-follow at the bottom: extend the window to the newest and stay pinned to the bottom
    cs.vEnd = total; cs.vStart = Math.max(0, total - DETAIL_WIN);
    paintWindow();
    host.scrollTop = host.scrollHeight;
  } else {
    // scrolled up reading history: don't repaint (preserves scroll + expanded panels); new turns are
    // appended past the window and surface via the "load later" affordance / next jump.
    cs.vEnd = Math.min(cs.vEnd, total);
  }
  // A live-updating session with an active search: refresh counts/highlights against the new
  // content without moving the view, keeping the current position when it still exists.
  // (force paths cleared the search above.)
  if (cs.searchQuery) {
    const cur = cs.searchIndex >= 0 ? cs.searchOcc[cs.searchIndex] : null;
    performDetailSearch(cs.searchQuery, { silent: true });
    if (cur) {
      const i = cs.searchOcc.findIndex((o) => o.agent === cur.agent && o.mi === cur.mi);
      if (i >= 0) { cs.searchIndex = i; updateSearchCount(); }
    }
  }
  renderSidePanels(detail);
  renderAgentTabs(detail);
  cs.lastRender = { file: cs.openFile, ...shape };
}
