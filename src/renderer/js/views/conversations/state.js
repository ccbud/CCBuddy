/*
 * 对话 view shared state — one mutable `cs` object owned here so the split modules
 * (list / detail / search / subagents / …) share a single source of truth without
 * export-binding gymnastics.
 */

// Render only the most recent N messages of a thread; a "load earlier" control reveals more.
// Huge threads (1000s of turns) otherwise put 1000s of nodes in the DOM, so every window
// resize / live re-render walks the whole tree (~1s) — the measured root cause of the jank.
// Windowed (virtualized) rendering: only a window [vStart, vEnd) of the thread is ever in the DOM.
export const DETAIL_WIN = 160;  // window size when opening / jumping (~115 rendered after skips)
export const LOAD_MORE = 120;   // messages revealed per load-earlier / load-later click
export const MAX_WIN = 240;     // hard cap on rendered messages — load-more trims the far end past this.

export const cs = {
  projects: [],           // [{ cwd, name, sessions:[...], lastActivity }]
  openId: null,
  openFile: null,
  search: '',
  // Big-search content matching (backend scan of session bodies — main, subagents, codex):
  contentHits: null,      // Map<file, hit> for the current query; null = no content results yet
  contentSearching: false, // a backend content scan is in flight (list shows a "searching" hint)
  contentSeq: 0,          // staleness guard: results from a superseded query are dropped
  contentTimer: null,
  pendingLocate: null,    // { query, agent } — auto-locate target consumed after opening a content hit
  activeDir: 'all',       // active history bucket; '__trash__' = recycle bin (deleted sessions)
  tagFilter: null,        // when set, the list shows only conversations carrying this exact tag
  tagClickTimer: null,    // debounces a tag's single-click (filter) so a double-click (edit) can cancel it
  listTimer: null,
  collapsed: new Set(),   // collapsed project cwds
  lastRender: { file: null, count: -1 },
  currentDetail: null,    // last-loaded session detail (for export)
  detailRequestSeq: 0,    // drops a late historyGet result after another session/request took over
  detailRequest: null,    // latest in-flight { seq, file }; also prevents timer requests piling up
  // Failed detail reads retry via the safety-net timer: { file, attempts, nextAt }.
  // permissionDenied probes steadily (granting macOS access emits no event we could watch);
  // other read/IPC failures back off exponentially so a permanently broken transcript isn't
  // re-read — and on macOS re-spawned through the helper — every 4 seconds forever.
  detailRetry: null,
  // Which session occupies the main panel: 'main' (the root thread) or a subagent key (its tool_use
  // id in detail.subagents). Each subagent is an independent session, so it gets the WHOLE panel —
  // switched via the agent list in the right nav, not nested inline. Reset to 'main' on open.
  activeAgent: 'main',
  vStart: 0, vEnd: 0,     // rendered window into the active thread's messages
  // Per-message plain text for data-driven search: Map<threadKey, texts[]> in reading order
  // ('main' first, then subagents by call site). Built lazily on first search and invalidated
  // on change. A Map so transcript-supplied keys can't collide with Object.prototype.
  searchDocs: null,
  // Detail search state (data-driven, spans every thread of the open session).
  searchOcc: [],          // [{ agent, mi }] — messages with ≥1 match, in reading order
  searchIndex: -1,        // position in searchOcc; -1 = matches known but not navigated yet
  searchQuery: '',
  searchTotalOcc: 0,      // total match occurrences across all threads (shown after the count)
  subIndex: null,         // callSite map: subKey -> { thread, mi }; built lazily per open session
  agentMenuOpen: false,
};

try { cs.collapsed = new Set(JSON.parse(localStorage.getItem('ccbud-collapsed-projects') || '[]')); } catch (_) {}
export function persistCollapsed() {
  try { localStorage.setItem('ccbud-collapsed-projects', JSON.stringify([...cs.collapsed])); } catch (_) {}
}

/** Message list of one thread of the open session ('main' or a subagent key). */
export function threadMessages(agent) {
  if (!cs.currentDetail) return [];
  if (agent !== 'main' && cs.currentDetail.subagents && cs.currentDetail.subagents[agent]) {
    return cs.currentDetail.subagents[agent].messages || [];
  }
  return agent === 'main' ? (cs.currentDetail.messages || []) : [];
}
/** The message list currently shown in the main panel (main thread or the active subagent's). */
export function activeMessages() { return threadMessages(cs.activeAgent); }

export function isLive(ts) { return ts && (Date.now() - ts) < 90000; }

// Is the currently-open session still active (recent on-disk activity)? Used to drive the
// safety-net auto-refresh so in-progress conversations live-update even if a watch event is missed.
export function openSessionLive() {
  if (!cs.openId) return false;
  for (const p of cs.projects) for (const s of p.sessions) if (s.id === cs.openId) return isLive(s.lastActivity);
  return false;
}

// Locate a loaded session by file (unique) or id — used by the rename/tag handlers to read its
// current title/tags before writing an updated set back.
export function findSession(id, file) {
  for (const p of cs.projects) for (const s of p.sessions) if ((file && s.file === file) || (id && s.id === id)) return s;
  return null;
}
