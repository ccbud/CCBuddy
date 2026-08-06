/* Right rail: session overview stats + the user-turn table of contents. */
import { $ } from '../../core/dom.js';
import { esc, fmtTok, fmtCredits, normContent, projName, L } from './format.js';
import { stripInjected } from './codex-format.js';
import { cs, activeMessages } from './state.js';
import { subName, subUsageSummary } from './subagents.js';

// The right rail (overview + navigation) only means something for an open conversation — hide
// it (and its resizer) entirely when nothing is selected.
export function syncConvNav() {
  const nav = document.querySelector('.conv-nav');
  const rs = document.querySelector('.conv-resizer-right');
  if (nav) nav.classList.toggle('hidden', !cs.openFile);
  if (rs) rs.classList.toggle('hidden', !cs.openFile);
  if (!cs.openFile) cs.detailRetry = null;
}

/** Overview rows for the session in the panel (the active subagent's when one is selected). */
function statRows(detail) {
  const m = detail.meta || {};
  // Invoking skill of the session in the panel: the active subagent's when one is selected,
  // else the session's own (a standalone subagent transcript). Absent → row filtered out.
  const panelSub = cs.activeAgent !== 'main' && detail.subagents ? detail.subagents[cs.activeAgent] : null;
  const t = (panelSub && panelSub.totals) || m.totals || {};
  const messageCount = panelSub
    ? (panelSub.count != null ? panelSub.count : (panelSub.messages || []).length)
    : m.messages;
  const skill = panelSub ? panelSub.skill : m.skill;
  return [
    [L('conv.stat.title'), m.title],
    [L('conv.stat.model'), m.model],
    [L('conv.stat.skill'), skill || null],
    ...(m.isSubagent ? [[L('conv.stat.type'), L('conv.subagentSession')]] : []),
    ...(m.imported ? [[L('conv.imported'), m.importedFrom || '✓']] : []),
    [L('conv.stat.project'), m.cwd ? projName(m.cwd) : m.project],
    [L('conv.stat.branch'), m.gitBranch],
    [L('conv.stat.session'), m.sessionId ? String(m.sessionId).slice(0, 8) : null],
    [L('conv.stat.rootSession'), m.rootSessionId && m.rootSessionId !== m.sessionId ? String(m.rootSessionId).slice(0, 8) : null],
    [L('conv.stat.parentThread'), m.parentThreadId ? String(m.parentThreadId).slice(0, 8) : null],
    [L('conv.stat.agent'), m.agentNickname],
    [L('conv.stat.agentPath'), m.agentPath],
    [L('conv.stat.messages'), messageCount],
    [L('conv.stat.turns'), t.turns],
    [L('conv.stat.input'), t.tokenUsageAvailable === false ? '—' : (t.in != null ? fmtTok(t.in) : null)],
    [L('conv.stat.output'), t.tokenUsageAvailable === false ? '—' : (t.out != null ? fmtTok(t.out) : null)],
    [L('conv.stat.credits'), t.credits != null ? fmtCredits(t.credits) : null],
    [L('conv.stat.cacheRead'), t.cacheRead ? fmtTok(t.cacheRead) : null],
    [L('conv.stat.tool'), m.assistant || 'Claude Code'],
    [L('conv.stat.version'), m.version],
  ].filter((r) => r[1] != null && r[1] !== '');
}

export function renderSidePanels(detail) {
  $('convStats').innerHTML = statRows(detail).map((r) => `<div class="stat-row flex justify-between gap-2 text-xs py-1.25 border-b border-border-custom last:border-b-0"><span class="k text-caption">${esc(r[0])}</span><span class="v font-mono text-[11.5px] text-fg truncate max-w-[120px]" data-tip="${esc(r[1])}">${esc(r[1])}</span></div>`).join('');

  // TOC is built from the message DATA (global indices) so it spans the WHOLE thread even though only
  // a window is rendered; clicking jumps the window to that message. Keyed on user turns — the natural
  // navigation points — which also keeps the sidebar light on huge threads.
  const messages = activeMessages(); // TOC follows the session shown in the main panel
  const toc = [];
  messages.forEach((m, i) => {
    if (m.role !== 'user' || m._meta || m.meta) return;
    const vis = normContent(m.content).filter((b) => b.type === 'text');
    const tv = vis.map((b) => stripInjected(b.text)).filter(Boolean).join(' ').replace(/\s+/g, ' ').trim();
    if (!tv) return;
    toc.push(`<div class="toc-item text-xs text-caption py-1 px-1.75 rounded-[5px] cursor-pointer truncate transition-all duration-100 hover:bg-chip-bg hover:text-fg" data-go="${i}" data-tip="${esc(tv.slice(0, 200))}">👤 ${esc(tv.slice(0, 32) || '…')}</div>`);
  });
  $('convToc').innerHTML = toc.join('');
}

/*
 * Session tabs (top of the main panel). When a conversation spawned subagents, the panel header
 * shows peer tabs: [主会话] [子代理 (N) ▾]. 主会话 and each subagent are equals — picking one
 * moves the WHOLE panel to that session.
 */
export function renderAgentTabs(detail) {
  const host = $('convAgentTabs');
  if (!host) return;
  const subs = (detail && detail.subagents) || {};
  const keys = Object.keys(subs);
  if (!keys.length) { host.innerHTML = ''; host.classList.add('hidden'); host.classList.remove('flex'); cs.agentMenuOpen = false; return; }
  host.classList.remove('hidden'); host.classList.add('flex');
  const mainActive = cs.activeAgent === 'main';
  const activeSub = !mainActive && subs[cs.activeAgent] ? subs[cs.activeAgent] : null;
  const seg = (active) => `inline-flex items-center gap-1.5 h-[28px] px-3 rounded-[8px] text-[12px] font-semibold cursor-pointer border transition-colors whitespace-nowrap ${active ? 'bg-brand-soft text-brand border-brand/25' : 'bg-bg-elev text-muted border-border-custom hover:text-fg hover:bg-chip-bg'}`;
  const mainTab = `<button type="button" data-agent="main" class="${seg(mainActive)}">👤 ${esc(L('conv.mainSession'))}</button>`;
  const ddLabel = activeSub ? `🤖 ${esc(subName(activeSub))}` : `🤖 ${esc(L('conv.stat.subagents'))} (${keys.length})`;
  const items = keys.map((k) => {
    const s = subs[k] || {};
    const cnt = s.count != null ? s.count : ((s.messages || []).length);
    const active = cs.activeAgent === k;
    const desc = s.description ? `<div class="text-[10.5px] text-muted truncate pl-[18px]">${esc(s.description)}</div>` : '';
    return `<button type="button" data-agent="${esc(k)}" class="conv-agent-menu-item w-full flex flex-col gap-0.25 text-left px-2 py-1.5 rounded-[6px] cursor-pointer border border-transparent transition-colors ${active ? 'bg-brand-soft text-brand' : 'hover:bg-chip-bg text-fg'}">
        <div class="flex items-center gap-1.25 min-w-0"><span class="shrink-0 text-[11px]">🤖</span><span class="font-mono text-[11.5px] font-semibold truncate">${esc(subName(s))}</span></div>
        ${desc}
        <div class="text-[10px] text-caption font-mono pl-[18px]">${esc(L('conv.subagentMsgs', { n: cnt }))} · ${esc(subUsageSummary(s))}</div>
      </button>`;
  }).join('');
  const menu = `<div class="conv-agent-menu ${cs.agentMenuOpen ? '' : 'hidden'} absolute left-0 top-[34px] z-30 min-w-[240px] max-w-[320px] max-h-[60vh] overflow-y-auto bg-bg-elev border border-border-custom rounded-[9px] shadow-[0_10px_30px_rgba(0,0,0,0.24)] p-1 flex flex-col gap-0.5">${items}</div>`;
  const dd = `<div class="conv-agent-dd relative"><button type="button" data-agent-dd class="${seg(!!activeSub)}">${ddLabel}<span class="text-[8px] opacity-70 ml-0.5">▾</span></button>${menu}</div>`;
  host.innerHTML = mainTab + dd;
}
