/* Toolbar actions: copy path, Claude/ChatGPT replay, export, import, toast. */
import { $ } from '../../core/dom.js';
import { api } from '../../core/bridge.js';
import { L } from './format.js';
import { cs } from './state.js';

export function toast(msg, ok) {
  let t = document.querySelector('.conv-toast');
  if (!t) { t = document.createElement('div'); t.className = 'conv-toast'; t.setAttribute('data-clarity-mask', 'true'); document.body.appendChild(t); }
  t.textContent = msg;
  t.classList.toggle('err', ok === false);
  t.classList.add('show');
  clearTimeout(t._t); t._t = setTimeout(() => t.classList.remove('show'), 2200);
}

export function hideExportMenu() { const m = $('convExportMenu'); if (m) m.classList.add('hidden'); }

// Absolute .jsonl path for the session currently in the panel — the active subagent's file when
// one is selected, else the main session file. Used by the "copy path" button so a transcript can
// be handed to another Claude Code session for replay / agent debugging.
function currentJsonlPath() {
  if (cs.activeAgent !== 'main' && cs.currentDetail && cs.currentDetail.subagents) {
    const s = cs.currentDetail.subagents[cs.activeAgent];
    if (s && s.file) return s.file;
  }
  return cs.openFile;
}

export function doCopyPath() {
  const p = currentJsonlPath();
  if (!p) return;
  try { api.copy(p); } catch (_) {}
  toast(L('conv.pathCopied'));
}

export async function doReplay(btn) {
  const p = currentJsonlPath();
  if (!p || !api.desktopReplay) return;
  if (btn) btn.disabled = true;
  toast(L('conv.replayOpening'));
  let res;
  const prompt = L('desktop.replayPrompt').slice(0, 13000); // q is truncated ~14k by Claude
  try { res = await api.desktopReplay(p, prompt); } catch (e) { res = { ok: false, reason: 'failed' }; }
  if (btn) btn.disabled = false;
  if (res && res.ok) return; // Claude Desktop now opening with the file + prompt
  const reason = res && res.reason;
  toast(
    reason === 'notInstalled' ? L('conv.replayNoApp')
      : reason === 'unsupported' ? L('conv.replayUnsupported')
      : reason === 'permission' ? L('conv.replayPermission')
      : reason === 'cancelled' ? L('conv.replayOpening')
      : L('conv.replayFail'),
    false
  );
}

// Same shape as doReplay, but for the ChatGPT desktop app: the backend opens a
// codex://new deep link with the review prompt and the transcripts' directory as
// the workspace, so the task can read the JSONL files listed in the prompt.
export async function doChatgpt(btn) {
  const p = currentJsonlPath();
  if (!p || !api.chatgptReplay) return;
  if (btn) btn.disabled = true;
  toast(L('conv.chatgptOpening'));
  let res;
  const prompt = L('desktop.chatgptPrompt').slice(0, 13000);
  try { res = await api.chatgptReplay(p, prompt); } catch (e) { res = { ok: false, reason: 'failed' }; }
  if (btn) btn.disabled = false;
  if (res && res.ok) return; // ChatGPT now opening with the prompt + workspace
  const reason = res && res.reason;
  toast(
    reason === 'notInstalled' ? L('conv.chatgptNoApp')
      : reason === 'unsupported' ? L('conv.replayUnsupported')
      : L('conv.chatgptFail'),
    false
  );
}

// HTML export is built backend-side (exporthtml.rs): it needs fs access to the on-disk subagent
// dialogues and emits a self-contained, Claude-styled viewer app.
export async function doExport(kind) {
  hideExportMenu();
  if (!cs.openFile) return;
  try {
    if (kind === 'jsonl') {
      const r = await api.historyExportRaw(cs.openFile);
      if (r && r.canceled) return;
      // A session with subagents comes back as a .zip bundle (r.bundled) — say so, so the .zip
      // (rather than the expected .jsonl) isn't a surprise.
      if (r && r.path) toast(L(r.bundled ? 'conv.exportOkZip' : 'conv.exportOk'));
      else toast(L('conv.exportFail'), false);
    } else if (kind === 'html') {
      const r = await api.historyExportHtml(cs.openFile);
      if (r && r.canceled) return;
      toast(r && r.path ? L('conv.exportOk') : L('conv.exportFail'), !!(r && r.path));
    }
  } catch (_) { toast(L('conv.exportFail'), false); }
}

/* r = { imported, skipped, failed } | { canceled } from history_import / history_import_paths.
   Toast a summary, jump to the imports dir on success, refresh the list. */
export async function applyImportResult(r, refresh) {
  if (!r || r.canceled) return;
  if (!r.imported) {
    toast(r.skipped ? L('conv.importSkip', { n: r.skipped }) : L('conv.importNone'), r.failed ? false : undefined);
  } else {
    const parts = [L('conv.importDone', { n: r.imported })];
    if (r.skipped) parts.push(L('conv.importSkip', { n: r.skipped }));
    if (r.failed) parts.push(L('conv.importFail', { n: r.failed }));
    toast(parts.join(' · '));
    try { if (api.historySetActive) await api.historySetActive('__imported__'); } catch (_) {}
  }
  await refresh();
}

// Collapse the action buttons into a "⋯" menu when the toolbar is too narrow to fit them
// alongside a 200px-min search box.
export function updateToolbarLayout() {
  const tb = document.querySelector('.conv-detail-toolbar');
  const actions = $('convActions');
  const moreWrap = $('convMoreWrap');
  if (!tb || !actions || !moreWrap) return;
  actions.classList.remove('hidden');
  moreWrap.classList.add('hidden');
  hideExportMenu();
  if (tb.scrollWidth > tb.clientWidth + 1) {
    actions.classList.add('hidden');
    moreWrap.classList.remove('hidden');
  }
}
