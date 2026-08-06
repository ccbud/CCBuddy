/* One message → HTML: user bubbles, assistant blocks, thinking, skill loads, turn meta. */
import { esc, md, normContent, fmtTok, fmtCredits, shortPath, resultSummary, L } from './format.js';
import { stripInjected } from './codex-format.js';
import { codeBlock } from './code.js';
import { renderToolCard } from './tools.js';
import { cs } from './state.js';

/** Assistant display name for the open session — "Codex" for codex rollouts, else Claude. */
export function assistantName() {
  return (cs.currentDetail && cs.currentDetail.meta && cs.currentDetail.meta.assistant) || 'Claude';
}

export function buildResults(messages) {
  const results = {};
  messages.forEach((m) => normContent(m.content).forEach((b) => { if (b.type === 'tool_result') results[b.tool_use_id] = b; }));
  return results;
}

export function renderUserBlock(b) {
  if (b.type === 'image') {
    const s = b.source || {};
    if (s.data) return `<img class="msg-img max-w-[300px] rounded-lg border border-border-custom my-1" src="data:${esc(s.media_type || 'image/png')};base64,${esc(s.data)}" />`;
    return `<div class="img-redacted text-[11px] text-muted p-[7px] px-2.25 bg-chip-bg rounded-[6px] inline-block">🖼 ${esc(L('conv.image'))}</div>`;
  }
  return `<div class="blk-text">${md(b.text)}</div>`;
}

function renderThinking(b) {
  const t = b.thinking || '';
  // Some turns carry a thinking block with only a signature and no visible text (the model/upstream
  // returned encrypted/empty reasoning). Skip it rather than draw an empty collapsible.
  if (!t.trim()) return '';
  const first = t.split('\n').find((x) => x.trim()) || L('conv.thinking');
  return `<details class="thinking bg-[#ff9f0a]/4 border border-[#ff9f0a]/12 rounded-[7px] my-1.5"><summary class="cursor-pointer p-1.75 px-2.5 text-[11px] font-medium text-amber outline-none list-none [&::-webkit-details-marker]:hidden">💭 ${esc(L('conv.thinking'))} · <span class="text-muted/70">${esc(first.slice(0, 60))}</span></summary><div class="thinking-body p-2.5 pt-1.75 pb-2 text-[11.5px] text-muted leading-[1.48] border-t border-[#ff9f0a]/8 mt-0.75">${md(t)}</div></details>`;
}

// A Skill envelope is an automatic Codex context-load event. Its recorded body is the exact
// snapshot used for that turn, so keep it collapsed by default but make the full source available
// for later workflow/debug reviews. It deliberately carries no user/assistant role label.
function renderSkillLoad(b) {
  const name = String(b.name || '').trim() || 'Skill';
  const path = String(b.path || '').trim();
  const snapshot = String(b.snapshot || '');
  const target = path ? shortPath(path) : '';
  const size = resultSummary(snapshot);
  const source = path
    ? `<div class="skill-source"><span>${esc(L('conv.skillSource'))}</span><code title="${esc(path)}">${esc(path)}</code></div>`
    : '';
  const disclosure = snapshot
    ? `<details class="skill-snapshot"><summary><span class="skill-caret">▸</span><span>${esc(L('conv.skillSnapshot'))}</span>${size ? `<span class="tool-res-size">${esc(size)}</span>` : ''}</summary><div class="skill-snapshot-body">${source}${codeBlock(snapshot, 'markdown')}</div></details>`
    : `<div class="skill-no-snapshot">${esc(L('conv.skillNoSnapshot'))}</div>`;
  return `<div class="tool-card tool-mcp skill-load"><div class="tool-head"><span class="tool-icon">🧩</span><span class="tool-name">${esc(L('conv.skillLoaded'))}</span><span class="skill-name">${esc(name)}</span>${target ? `<span class="tool-target" title="${esc(path)}">${esc(target)}</span>` : ''}</div>${disclosure}</div>`;
}

function turnMeta(m) {
  const bits = [];
  if (m.modelActual) bits.push(esc(m.modelActual));
  if (m.usage) {
    const tokenTotal = (m.usage.inputTokens || 0) + (m.usage.outputTokens || 0)
      + (m.usage.cacheRead || 0) + (m.usage.cacheCreation || 0);
    // A credit-bearing, all-zero Qoder usage object means token accounting was not recorded.
    // Do not turn that absence into a misleading "0↑ 0↓" badge.
    if (m.usage.credits == null || tokenTotal > 0) {
      bits.push(`${fmtTok(m.usage.inputTokens)}↑ ${fmtTok(m.usage.outputTokens)}↓`);
    }
    if (m.usage.credits != null) bits.push(`${fmtCredits(m.usage.credits)} ${esc(L('conv.credits'))}`);
  }
  if (m.usage && m.usage.cacheRead) bits.push(`${fmtTok(m.usage.cacheRead)} ${esc(L('conv.cache'))}`);
  if (m.stopReason && m.stopReason !== 'end_turn' && m.stopReason !== 'tool_use') bits.push(esc(m.stopReason));
  return bits.length ? `<div class="turn-meta flex gap-1 flex-wrap mt-1.5">${bits.map((b) => `<span class="text-[9.5px] font-mono text-caption bg-chip-bg rounded-[4px] px-1.25 py-0.25">${b}</span>`).join('')}</div>` : '';
}

// Returns the HTML for one message, or '' for a pure tool_result / hidden meta user turn.
// Structured metadata such as a loaded Skill is rendered before the role branches so it reads
// as an event in the timeline, rather than being mislabeled as either the user or the assistant.
// inSub: rendered inside a nested subagent block — suppress the per-turn "subagent" badge
// (the surrounding block already labels it) so the nested thread stays clean.
export function renderMessage(m, results, idx, inSub) {
  const mid = idx == null ? '' : ` id="m${idx}" data-mi="${idx}"`;
  const blocks = normContent(m.content);
  const skillLoads = blocks.filter((b) => b && b.type === 'skill_load');
  if (skillLoads.length) {
    return `<div class="msg meta animate-[panelIn_0.18s_cubic-bezier(0.23,1,0.32,1)] w-full"${mid}>${skillLoads.map(renderSkillLoad).join('')}</div>`;
  }
  if (m.role === 'user') {
    const vis = blocks.filter((b) => b.type === 'text' || b.type === 'image');
    if (!vis.length) return '';
    // Strip harness-injected noise but keep the human prose — the first user turn carries an
    // appended <system-reminder>, and the old "contains a tag → drop the whole turn" rule made
    // that turn (the one that also seeds the title) disappear from the panel.
    const clean = vis
      .map((b) => (b.type === 'text' ? { type: 'text', text: stripInjected(b.text) } : b))
      .filter((b) => b.type === 'image' || b.text);
    if (!clean.length) return '';
    return `<div class="msg user flex flex-col gap-1.25 animate-[panelIn_0.18s_cubic-bezier(0.23,1,0.32,1)] w-full"${mid}><div class="msg-role text-[10px] font-bold uppercase tracking-wider text-caption flex items-center gap-1.25">👤 ${esc(L('conv.you'))}</div><div class="msg-body bg-bg-elev border border-border-custom rounded-[11px] p-3 shadow-card text-[13px] leading-[1.58]">${clean.map(renderUserBlock).join('')}</div></div>`;
  }
  let body = '';
  blocks.forEach((b) => {
    if (b.type === 'text') body += `<div class="blk-text">${md(b.text)}</div>`;
    else if (b.type === 'thinking') body += renderThinking(b);
    else if (b.type === 'tool_use') body += renderToolCard(b, results[b.id]);
    else if (b.type === 'image') body += renderUserBlock(b);
    else body += `<pre class="pre bg-[#0c0e12] border border-white/7 rounded-[7px] p-2.5 overflow-x-auto font-mono text-[11px] leading-[1.48] text-[#e8edf4] whitespace-pre-wrap break-all">${esc(JSON.stringify(b))}</pre>`;
  });
  if (!body) return '';
  return `<div class="msg assistant group flex flex-col gap-1.25 animate-[panelIn_0.18s_cubic-bezier(0.23,1,0.32,1)] w-full ${m.isSidechain ? 'sidechain' : ''}"${mid}><div class="msg-role text-[10px] font-bold uppercase tracking-wider text-caption flex items-center gap-1.25">✦ ${esc(assistantName())}${m.isSidechain && !inSub ? ` <span class="conv-badge text-[10.5px] px-1.5 py-0.25 rounded-full bg-chip-bg text-fg font-sans">${esc(L('conv.subagent'))}</span>` : ''}</div><div class="msg-body text-[13px] leading-[1.58] py-0.5 pr-0 pl-3 border-l-2 border-border-strong group-[.streaming]:border-green">${body}${turnMeta(m)}</div></div>`;
}
