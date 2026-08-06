/*
 * Inline subagents — a subagent dialogue is keyed by the tool_use id that spawned it and rendered
 * as a lazily-filled disclosure directly under that call, at any nesting depth (a subagent's own
 * tool cards run through this same path). Bodies stay empty until opened, to bound the DOM.
 */
import { $ } from '../../core/dom.js';
import { esc, fmtTok, fmtCredits, normContent, cssAttr, L } from './format.js';
import { cs } from './state.js';
import { highlight } from './code.js';

/** Display name: agent type, suffixed with the invoking skill (`type:skill`) when attributed. */
export function subName(s) { return (s.type || 'agent') + (s.skill ? ':' + s.skill : ''); }

export function subUsageSummary(s) {
  const totals = (s && s.totals) || {};
  const bits = [];
  if (totals.tokenUsageAvailable !== false) bits.push(`${fmtTok(totals.out || 0)}↓`);
  if (totals.credits != null) bits.push(`${fmtCredits(totals.credits)} ${L('conv.credits')}`);
  return bits.join(' · ') || '—';
}

export function inlineSubagentBlock(id) {
  const subs = (cs.currentDetail && cs.currentDetail.subagents) || {};
  const s = id && subs[id];
  if (!s) return '';
  const cnt = s.count != null ? s.count : ((s.messages || []).length);
  const meta = `${esc(L('conv.subagentMsgs', { n: cnt }))} · ${esc(subUsageSummary(s))}`;
  const desc = s.description ? ` · <span class="font-normal text-muted">${esc(s.description)}</span>` : '';
  return `<details class="subagent-inline" data-sub="${esc(id)}"><summary class="cursor-pointer py-2 px-2.5 text-[11px] font-semibold text-brand outline-none list-none [&::-webkit-details-marker]:hidden flex items-center gap-1.5 bg-brand-soft hover:brightness-105"><span class="sub-caret shrink-0 transition-transform">▸</span><span class="shrink-0">🤖 ${esc(L('conv.subagent'))} · ${esc(subName(s))}</span><span class="truncate min-w-0 flex-1">${desc}</span><span class="text-caption font-mono font-normal shrink-0">${meta}</span></summary><div class="subagent-inline-body bg-brand-soft/10" data-sub-body="${esc(id)}"></div></details>`;
}

// Render one subagent's whole thread (recursively wiring its own inline subagents via renderMessage →
// renderToolCard). idx=null so nested turns carry no data-mi (they're outside main-window navigation).
async function renderSubThread(key) {
  const { renderMessage, buildResults } = await import('./message.js');
  const s = cs.currentDetail && cs.currentDetail.subagents && cs.currentDetail.subagents[key];
  if (!s) return '';
  const msgs = s.messages || [];
  if (!msgs.length) return `<div class="conv-empty text-[11px] text-muted py-1">${esc(L('conv.emptyConv'))}</div>`;
  const results = buildResults(msgs);
  return msgs.map((m) => renderMessage(m, results, null, true)).join('') || `<div class="conv-empty text-[11px] text-muted py-1">${esc(L('conv.emptyConv'))}</div>`;
}

/** Fill a subagent disclosure's body on first open (no-op afterwards). Returns the body element. */
export function fillSubBody(det) {
  const body = det && det.querySelector(':scope > [data-sub-body]');
  if (!body) return null;
  if (!body.dataset.filled) {
    body.dataset.filled = '1';
    renderSubThread(body.getAttribute('data-sub-body')).then((html) => {
      body.innerHTML = html;
      highlight(body);
    });
  }
  return body;
}

// Map every subagent to where it was spawned: callSite.get(subKey) = { thread, mi } where thread is
// 'main' or another subagent's key (nested spawns), and mi is the message index in that thread. Built
// lazily per open session and reset when the session changes.
export function buildSubIndex() {
  const subs = (cs.currentDetail && cs.currentDetail.subagents) || {};
  const keys = new Set(Object.keys(subs));
  const callSite = new Map();
  const scan = (msgs, threadKey) => (msgs || []).forEach((m, i) => normContent(m.content).forEach((b) => {
    if (b.type === 'tool_use' && keys.has(b.id) && !callSite.has(b.id)) callSite.set(b.id, { thread: threadKey, mi: i });
  }));
  scan((cs.currentDetail && cs.currentDetail.messages) || [], 'main');
  for (const k of keys) scan(subs[k].messages, k);
  cs.subIndex = { callSite };
}

// Ancestor chain from the outermost (spawned in main) down to `key`, e.g. [topSub, …, key]. Empty if
// the call site can't be resolved (e.g. a subagent whose meta recorded no toolUseId).
export function subChain(key) {
  if (!cs.subIndex) buildSubIndex();
  const chain = []; const seen = new Set(); let cur = key;
  while (cur && cur !== 'main' && !seen.has(cur)) {
    seen.add(cur); chain.unshift(cur);
    const cSite = cs.subIndex.callSite.get(cur);
    if (!cSite) return []; // broken link — can't place it in context
    cur = cSite.thread;
  }
  return chain;
}

/** Expand the disclosure chain down to `key` inside the currently-painted window. */
export function expandChain(chain) {
  const host = $('convDetail');
  let det = null;
  if (host) for (const k of chain) {
    det = host.querySelector(`.subagent-inline[data-sub="${cssAttr(k)}"]`);
    if (!det) break;
    fillSubBody(det); det.open = true; // child level now exists in the DOM for the next iteration
  }
  return det;
}
