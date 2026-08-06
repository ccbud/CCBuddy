/*
 * Live follow + drag-drop import. ~/.claude/projects changes → refresh the list and re-render
 * the open session if it was touched. rerenderDetail rebuilds the whole thread, so during an
 * active session (the file is rewritten on every streamed turn) it is debounced — bursts of
 * writes coalesce into one rebuild instead of one-per-write (the main "under load" jank).
 */
import { api } from '../../core/bridge.js';
import { icons } from '../../core/icons.js';
import { L } from './format.js';
import { cs, openSessionLive } from './state.js';
import { refreshList } from './list.js';
import { rerenderDetail } from './detail.js';
import { toast, applyImportResult } from './actions.js';

// True when a changed file belongs to the OPEN session — its own .jsonl, or one of its
// subagent files (<session>/subagents/agent-*.jsonl) — so nested subagents live-follow too.
function touchesOpenSession(files) {
  if (!cs.openFile || !files) return false;
  const base = cs.openFile.replace(/\.jsonl$/i, '');
  return files.some((f) => f === cs.openFile || f.indexOf(base + '/subagents/') === 0 || f.indexOf(base + '\\subagents\\') === 0);
}

export function bindLiveFollow() {
  let detailTimer;
  if (api.onHistoryChanged) api.onHistoryChanged((p) => {
    clearTimeout(cs.listTimer);
    cs.listTimer = setTimeout(refreshList, 200);
    if (p && p.files && touchesOpenSession(p.files)) {
      clearTimeout(detailTimer);
      detailTimer = setTimeout(() => rerenderDetail(false), 300);
    }
  });

  // Unified safety-net: live sessions still refresh when a file-watch event is missed, while a
  // failed read retries on its own schedule (steady probe for permission errors, backoff for
  // the rest). rerenderDetail coalesces ticks while a helper-backed read is already in flight.
  setInterval(() => {
    if (!cs.openFile) return;
    const retryDue = cs.detailRetry && cs.detailRetry.file === cs.openFile && Date.now() >= cs.detailRetry.nextAt;
    if (retryDue || openSessionLive()) rerenderDetail(false);
  }, 4000);
}

/*
 * Drag a .jsonl transcript or a .zip conversation bundle (main session + subagents) anywhere onto
 * the window → import it directly, same pipeline as the import button. preventDefault on
 * dragover/drop is REQUIRED — otherwise the webview navigates to the dropped file:// URL. Other
 * files are ignored (import validates each is a real transcript/bundle before copying it in).
 */
export function bindDropImport() {
  const dragHasFiles = (e) => { try { return Array.from((e.dataTransfer && e.dataTransfer.types) || []).indexOf('Files') >= 0; } catch (_) { return false; } };
  let dropOverlay = null, dropDepth = 0;
  const showDropOverlay = () => {
    if (!dropOverlay) {
      dropOverlay = document.createElement('div');
      dropOverlay.className = 'conv-drop-overlay';
      dropOverlay.innerHTML = '<div class="conv-drop-card">' + (icons.download || '') + '<span></span></div>';
      document.body.appendChild(dropOverlay);
    }
    dropOverlay.querySelector('span').textContent = L('conv.dropHint');
    dropOverlay.classList.add('show');
  };
  const hideDropOverlay = () => { dropDepth = 0; if (dropOverlay) dropOverlay.classList.remove('show'); };
  document.addEventListener('dragenter', (e) => { if (!dragHasFiles(e)) return; e.preventDefault(); dropDepth++; showDropOverlay(); });
  document.addEventListener('dragover', (e) => { if (!dragHasFiles(e)) return; e.preventDefault(); try { e.dataTransfer.dropEffect = 'copy'; } catch (_) {} });
  document.addEventListener('dragleave', (e) => { if (!dragHasFiles(e)) return; dropDepth = Math.max(0, dropDepth - 1); if (!dropDepth) hideDropOverlay(); });
  document.addEventListener('drop', async (e) => {
    if (!dragHasFiles(e)) return;
    e.preventDefault();
    hideDropOverlay();
    const files = Array.prototype.slice.call(e.dataTransfer.files || []);
    const paths = files.map((f) => { try { return api.pathForFile ? api.pathForFile(f) : (f.path || ''); } catch (_) { return ''; } }).filter(Boolean);
    const importable = paths.filter((p) => /\.(jsonl|zip)$/i.test(p));
    if (!importable.length) { toast(L('conv.dropNotJsonl'), false); return; }
    if (!api.historyImportPaths) return;
    let r; try { r = await api.historyImportPaths(importable); } catch (_) { r = null; }
    await applyImportResult(r, refreshList);
  });
}
