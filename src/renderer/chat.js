'use strict';

/*
 * New Session chat — drive Claude Code / Codex CLI runs from inside the app.
 * Backend contract (src-tauri/src/chat.rs): chatStart/chatSend spawn one CLI turn and stream
 * normalized items over the `chat:event` channel ({id, item}); finalized items are also
 * persisted so chatGet can replay a session after app restarts. Delta items are live-only.
 */
(function () {
  const api = window.ccbud;
  const $ = (id) => document.getElementById(id);
  const L = (k, p) => (window.I18n ? window.I18n.t(k, p) : k);
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const md = (text) => { try { return window.marked ? window.marked.parse(String(text || '')) : esc(text); } catch (_) { return esc(text); } };

  const AGENT_META = {
    claude: { name: 'Claude Code', icon: 'assets/claude.svg' },
    codex: { name: 'Codex', icon: 'assets/chatgpt.svg' },
  };

  let sessions = [];
  let activeId = null;
  let agents = { claude: { available: false }, codex: { available: false } };
  let setupAgent = 'claude';
  let setupPerm = 'edits';
  let liveText = '';     // accumulated assistant text deltas for the in-flight turn
  let liveThink = '';    // accumulated thinking deltas
  let maxSeq = -1;       // highest persisted-item seq already in the transcript (dedupe on open)
  let shown = false;

  function activeSession() { return sessions.find((s) => s.id === activeId) || null; }
  function isRunning(s) { return !!(s && (s.running || s.status === 'running')); }

  function relTime(ts) {
    if (!ts) return '';
    const d = Date.now() - ts;
    if (d < 60000) return L('chat.justNow');
    if (d < 3600000) return `${Math.floor(d / 60000)}m`;
    if (d < 86400000) return `${Math.floor(d / 3600000)}h`;
    return `${Math.floor(d / 86400000)}d`;
  }

  function baseName(p) { return String(p || '').split(/[\\/]/).filter(Boolean).pop() || p || ''; }

  /* ---------- session list ---------- */

  function renderSessionList() {
    const host = $('chatSessionList');
    if (!host) return;
    if (!sessions.length) {
      host.innerHTML = `<div class="text-[11.5px] text-caption text-center px-3 py-6 leading-relaxed">${esc(L('chat.empty'))}</div>`;
      return;
    }
    host.innerHTML = sessions.map((s) => {
      const meta = AGENT_META[s.agent] || AGENT_META.claude;
      const running = isRunning(s);
      const err = s.status === 'error';
      const dot = running
        ? '<span class="chat-run-dot shrink-0"></span>'
        : err ? '<span class="w-[6px] h-[6px] rounded-full bg-red shrink-0"></span>' : '';
      return `<div class="chat-sess group relative flex flex-col gap-0.5 px-2.5 py-2 rounded-[9px] cursor-pointer transition-colors duration-120 hover:bg-chip-bg ${s.id === activeId ? 'bg-brand-soft' : ''}" data-sid="${esc(s.id)}">
        <div class="flex items-center gap-1.5 min-w-0">
          <img src="${meta.icon}" class="w-[14px] h-[14px] rounded-[3px] shrink-0" alt="" />
          <span class="text-[12px] font-medium text-fg truncate flex-1 min-w-0">${esc(s.title || L('chat.untitled'))}</span>
          ${dot}
        </div>
        <div class="flex items-center gap-1.5 pl-[20px] min-w-0">
          <span class="text-[10.5px] text-caption font-mono truncate flex-1 min-w-0">${esc(baseName(s.cwd))}</span>
          <span class="text-[10px] text-caption shrink-0">${esc(relTime(s.updatedMs))}</span>
        </div>
        <button class="chat-sess-del absolute right-1.5 top-1.5 w-[20px] h-[20px] border border-border-custom rounded-[6px] bg-bg-elev text-caption cursor-pointer items-center justify-center text-[11px] leading-none hover:text-red hover:border-red/40" data-del="${esc(s.id)}" title="${esc(L('chat.deleteTitle'))}">✕</button>
      </div>`;
    }).join('');
  }

  async function refreshSessions() {
    try { sessions = (await api.chatList()) || []; } catch (_) { sessions = []; }
    renderSessionList();
  }

  /* ---------- setup form ---------- */

  function renderAgentAvailability() {
    document.querySelectorAll('#chatAgentSeg .chat-agent-btn').forEach((b) => {
      const a = agents[b.dataset.agent] || {};
      const st = b.querySelector('.chat-agent-state');
      if (st) {
        st.textContent = a.available ? L('chat.installed') : L('chat.notInstalled');
        st.classList.toggle('text-green', !!a.available);
      }
      b.classList.toggle('opacity-55', !a.available);
    });
  }

  async function refreshAgents() {
    try { agents = (await api.chatAgents()) || agents; } catch (_) {}
    renderAgentAvailability();
  }

  function showSetup() {
    activeId = null;
    $('chatSetup').classList.remove('hidden');
    const t = $('chatTranscript');
    t.classList.add('hidden'); t.classList.remove('flex');
    $('chatComposer').classList.add('hidden');
    $('chatHeader').classList.add('hidden'); $('chatHeader').classList.remove('flex');
    renderSessionList();
    setTimeout(() => { const p = $('chatSetupPrompt'); if (p) p.focus(); }, 60);
  }

  /* ---------- transcript rendering ---------- */

  function transcriptEl() { return $('chatTranscript'); }

  function nearBottom() {
    const el = $('chatBody');
    return el.scrollHeight - el.scrollTop - el.clientHeight < 140;
  }
  function scrollBottom(force) {
    const el = $('chatBody');
    if (force || nearBottom()) el.scrollTop = el.scrollHeight;
  }

  function highlightIn(root) {
    if (!window.hljs) return;
    root.querySelectorAll('pre code').forEach((el) => { try { window.hljs.highlightElement(el); } catch (_) {} });
  }

  function agentLabel() {
    const s = activeSession();
    return (AGENT_META[s && s.agent] || AGENT_META.claude).name;
  }

  function userNode(text) {
    const div = document.createElement('div');
    div.className = 'msg user flex flex-col gap-1.25 animate-[panelIn_0.18s_cubic-bezier(0.23,1,0.32,1)] w-full';
    div.innerHTML = `<div class="msg-role text-[10px] font-bold uppercase tracking-wider text-caption flex items-center gap-1.25">👤 ${esc(L('conv.you'))}</div>
      <div class="msg-body bg-bg-elev border border-border-custom rounded-[11px] p-3 px-4 shadow-card text-[13px] leading-[1.58] whitespace-pre-wrap break-words"></div>`;
    div.querySelector('.msg-body').textContent = text;
    return div;
  }

  function assistantNode(html) {
    const div = document.createElement('div');
    div.className = 'msg assistant flex flex-col gap-1.25 animate-[panelIn_0.18s_cubic-bezier(0.23,1,0.32,1)] w-full';
    div.innerHTML = `<div class="msg-role text-[10px] font-bold uppercase tracking-wider text-caption flex items-center gap-1.25">✦ ${esc(agentLabel())}</div>
      <div class="msg-body blk-text text-[13px] leading-[1.58] py-0.5 pr-0 pl-3 border-l-2 border-border-strong">${html}</div>`;
    return div;
  }

  function thinkingNode(text) {
    const div = document.createElement('div');
    div.className = 'w-full';
    div.innerHTML = `<details class="chat-think text-[12px] text-muted border-l-2 border-border-custom pl-3">
      <summary class="cursor-pointer text-[10.5px] font-semibold uppercase tracking-wider text-caption select-none list-none [&::-webkit-details-marker]:hidden">◦ ${esc(L('chat.thinking'))}</summary>
      <div class="pt-1 whitespace-pre-wrap break-words opacity-80"></div></details>`;
    div.querySelector('details > div').textContent = text;
    return div;
  }

  function toolNode(it) {
    const div = document.createElement('div');
    div.className = 'chat-tool w-full flex flex-col gap-0.5';
    if (it.toolId) div.dataset.toolid = it.toolId;
    const done = !!it.done;
    div.innerHTML = `<div class="flex items-center gap-2 min-w-0 text-[12px]">
        <span class="chat-tool-state shrink-0 w-[14px] h-[14px] flex items-center justify-center">${done ? '<span class="text-green text-[11px]">✓</span>' : '<span class="chat-spinner"></span>'}</span>
        <span class="font-semibold text-muted shrink-0">${esc(it.name || 'tool')}</span>
        <span class="text-caption font-mono truncate min-w-0 chat-tool-detail">${esc(it.detail || '')}</span>
      </div>
      <div class="chat-tool-out hidden pl-[22px]"></div>`;
    return div;
  }

  function resultNode(it) {
    const div = document.createElement('div');
    div.className = 'w-full flex items-center gap-2 py-0.5';
    let parts = [];
    if (it.stopped) parts.push(`■ ${L('chat.stoppedMark')}`);
    else if (it.ok) parts.push(`✓ ${L('chat.doneMark')}`);
    else parts.push(`✕ ${L('chat.failedMark')}`);
    if (it.durationMs) parts.push((it.durationMs / 1000).toFixed(1) + 's');
    if (it.costUsd) parts.push('$' + Number(it.costUsd).toFixed(4));
    const u = it.usage || {};
    const tok = (u.input_tokens || 0) + (u.output_tokens || 0);
    if (tok) parts.push(tok.toLocaleString() + ' tok');
    const cls = it.ok ? 'text-caption' : 'text-red';
    div.innerHTML = `<span class="flex-1 border-t border-border-custom"></span>
      <span class="text-[10.5px] ${cls} whitespace-nowrap font-medium">${esc(parts.join(' · '))}</span>
      <span class="flex-1 border-t border-border-custom"></span>`;
    return div;
  }

  function errorNode(msg) {
    const div = document.createElement('div');
    div.className = 'w-full';
    div.innerHTML = `<div class="text-[12px] text-red bg-red-soft border border-red/20 rounded-[9px] px-3 py-2 whitespace-pre-wrap break-words"></div>`;
    div.firstElementChild.textContent = msg;
    return div;
  }

  /* live (streaming) bubble管理 */
  function liveNode() {
    let el = transcriptEl().querySelector('.chat-live');
    if (!el) {
      el = assistantNode('');
      el.classList.add('chat-live');
      el.querySelector('.msg-body').classList.add('chat-live-body', 'whitespace-pre-wrap', 'break-words');
      el.querySelector('.msg-body').classList.replace('border-border-strong', 'border-green');
      transcriptEl().appendChild(el);
    }
    return el;
  }
  function liveThinkNode() {
    let el = transcriptEl().querySelector('.chat-live-think');
    if (!el) {
      el = document.createElement('div');
      el.className = 'chat-live-think w-full text-[12px] text-muted border-l-2 border-border-custom pl-3';
      el.innerHTML = `<div class="text-[10.5px] font-semibold uppercase tracking-wider text-caption chat-think-pulse">◦ ${esc(L('chat.thinking'))}…</div>
        <div class="chat-live-think-text pt-1 whitespace-pre-wrap break-words opacity-70"></div>`;
      transcriptEl().appendChild(el);
    }
    return el;
  }
  function clearLive() {
    liveText = '';
    liveThink = '';
    const el = transcriptEl().querySelector('.chat-live');
    if (el) el.remove();
    const t = transcriptEl().querySelector('.chat-live-think');
    if (t) t.remove();
  }

  /* apply one normalized item to the transcript DOM */
  function applyItem(it, replaying) {
    const host = transcriptEl();
    const stick = replaying ? false : nearBottom();
    switch (it.kind) {
      case 'user':
        clearLive();
        host.appendChild(userNode(it.text || ''));
        break;
      case 'delta': {
        if (replaying) return; // deltas are live-only
        if (it.think) {
          liveThink += it.text || '';
          const el = liveThinkNode();
          el.querySelector('.chat-live-think-text').textContent = liveThink.length > 1200 ? '…' + liveThink.slice(-1200) : liveThink;
        } else {
          liveText += it.text || '';
          const el = liveNode();
          el.querySelector('.msg-body').textContent = liveText;
        }
        break;
      }
      case 'thinking': {
        const lt = host.querySelector('.chat-live-think');
        if (lt) lt.remove();
        liveThink = '';
        host.appendChild(thinkingNode(it.text || ''));
        break;
      }
      case 'assistant': {
        const lv = host.querySelector('.chat-live');
        if (lv) lv.remove();
        liveText = '';
        const node = assistantNode(md(it.text || ''));
        host.appendChild(node);
        highlightIn(node);
        break;
      }
      case 'tool': {
        // Codex re-announces tools as done; refresh in place when the row exists.
        const prev = it.toolId ? host.querySelector(`.chat-tool[data-toolid="${CSS.escape(String(it.toolId))}"]`) : null;
        const node = toolNode(it);
        if (prev) prev.replaceWith(node); else host.appendChild(node);
        break;
      }
      case 'tool_result': {
        const row = it.toolId ? host.querySelector(`.chat-tool[data-toolid="${CSS.escape(String(it.toolId))}"]`) : null;
        if (row) {
          const st = row.querySelector('.chat-tool-state');
          if (st) st.innerHTML = it.ok ? '<span class="text-green text-[11px]">✓</span>' : '<span class="text-red text-[11px]">✕</span>';
          if (it.detail && !it.ok) {
            const out = row.querySelector('.chat-tool-out');
            if (out) {
              out.classList.remove('hidden');
              out.innerHTML = `<pre class="text-[11px] text-caption bg-bg-input border border-border-custom rounded-[7px] px-2.5 py-1.5 mt-0.5 overflow-x-auto whitespace-pre-wrap break-words max-h-[160px] overflow-y-auto"></pre>`;
              out.firstElementChild.textContent = it.detail;
            }
          }
        }
        break;
      }
      case 'result':
        clearLive();
        host.appendChild(resultNode(it));
        break;
      case 'error':
        clearLive();
        host.appendChild(errorNode(it.message || 'error'));
        break;
      case 'meta':
      case 'status':
        break; // reflected in header/composer state, not the transcript
      default:
        break;
    }
    if (!replaying && stick) scrollBottom(true);
  }

  /* ---------- header / composer state ---------- */

  function syncHeader() {
    const s = activeSession();
    const head = $('chatHeader');
    if (!s) { head.classList.add('hidden'); head.classList.remove('flex'); return; }
    head.classList.remove('hidden'); head.classList.add('flex');
    const meta = AGENT_META[s.agent] || AGENT_META.claude;
    $('chatHeaderIcon').src = meta.icon;
    $('chatHeaderTitle').textContent = s.title || L('chat.untitled');
    $('chatHeaderCwd').textContent = s.cwd || '';
    const st = $('chatHeaderStatus');
    if (isRunning(s)) { st.innerHTML = `<span class="chat-run-dot inline-block mr-1"></span>${esc(L('chat.running'))}`; }
    else if (s.status === 'error') { st.textContent = L('chat.errorState'); }
    else { st.textContent = ''; }
    syncComposer();
  }

  function syncComposer() {
    const running = isRunning(activeSession());
    const send = $('chatSendBtn');
    const stop = $('chatStopBtn');
    send.classList.toggle('hidden', running);
    send.classList.toggle('flex', !running);
    stop.classList.toggle('hidden', !running);
    stop.classList.toggle('flex', running);
  }

  /* ---------- open / start / send ---------- */

  async function openSession(id) {
    activeId = id;
    clearLive();
    let res = null;
    try { res = await api.chatGet(id); } catch (_) {}
    if (!res || !res.ok) { showSetup(); return; }
    // merge fresh session info (running flag) into our list copy
    const i = sessions.findIndex((s) => s.id === id);
    if (i >= 0) sessions[i] = Object.assign({}, sessions[i], res.session);
    else sessions.unshift(res.session);

    $('chatSetup').classList.add('hidden');
    const t = transcriptEl();
    t.innerHTML = '';
    t.classList.remove('hidden'); t.classList.add('flex');
    $('chatComposer').classList.remove('hidden');
    maxSeq = -1;
    (res.items || []).forEach((it) => { if (it.seq != null && it.seq > maxSeq) maxSeq = it.seq; applyItem(it, true); });
    highlightIn(t);
    renderSessionList();
    syncHeader();
    scrollBottom(true);
    setTimeout(() => { const inp = $('chatInput'); if (inp) inp.focus(); }, 60);
  }

  async function startSession() {
    const cwd = $('chatCwd').value.trim();
    const prompt = $('chatSetupPrompt').value.trim();
    const hint = $('chatSetupHint');
    hint.textContent = '';
    if (!prompt) { hint.textContent = L('chat.needTask'); return; }
    if (!cwd) { hint.textContent = L('chat.needDir'); return; }
    const btn = $('chatStartBtn');
    btn.disabled = true;
    try {
      const res = await api.chatStart(setupAgent, cwd, prompt, setupPerm);
      if (!res || !res.ok) {
        hint.textContent = res && res.reason === 'badDir' ? L('chat.badDir') : L('chat.startFailed');
        return;
      }
      try { localStorage.setItem('ccbud-chat-cwd', cwd); } catch (_) {}
      $('chatSetupPrompt').value = '';
      await refreshSessions();
      await openSession(res.id);
    } finally {
      btn.disabled = false;
    }
  }

  async function sendFollowUp() {
    const s = activeSession();
    if (!s || isRunning(s)) return;
    const inp = $('chatInput');
    const text = inp.value.trim();
    if (!text) return;
    inp.value = '';
    inp.style.height = 'auto';
    const res = await api.chatSend(s.id, text).catch(() => null);
    if (!res || !res.ok) {
      if (res && res.reason === 'busy') showToast(L('chat.busyToast'), 'err');
      else showToast(L('chat.startFailed'), 'err');
      inp.value = text;
      return;
    }
    s.status = 'running'; s.running = true;
    syncHeader();
    renderSessionList();
  }

  async function stopRun() {
    const s = activeSession();
    if (!s) return;
    await api.chatStop(s.id).catch(() => {});
  }

  /* ---------- events from backend ---------- */

  function onChatEvent(payload) {
    if (!payload || !payload.id) return;
    const { id, item } = payload;
    const s = sessions.find((x) => x.id === id);
    if (item.kind === 'status') {
      if (s) {
        s.status = item.state === 'running' ? 'running' : item.state;
        s.running = item.state === 'running';
        s.updatedMs = Date.now();
      }
      if (id === activeId) {
        if (s && item.viaGateway != null) $('chatHeaderGateway').classList.toggle('hidden', !item.viaGateway);
        syncHeader();
      }
      renderSessionList();
      return;
    }
    if (item.kind === 'meta') {
      if (s && item.cliSessionId) s.cliSessionId = item.cliSessionId;
      return;
    }
    if (id !== activeId) {
      if (s && (item.kind === 'user' || item.kind === 'assistant')) { s.updatedMs = Date.now(); renderSessionList(); }
      return;
    }
    // Persisted items carry `seq`; drop any event the chatGet replay already covered.
    if (item.seq != null) {
      if (item.seq <= maxSeq) return;
      maxSeq = item.seq;
    }
    applyItem(item, false);
  }

  /* ---------- wiring ---------- */

  function bind() {
    if (!api || !$('view-chat')) return;

    $('chatNewBtn').addEventListener('click', showSetup);
    $('chatStartBtn').addEventListener('click', startSession);
    $('chatSendBtn').addEventListener('click', sendFollowUp);
    $('chatStopBtn').addEventListener('click', stopRun);

    $('chatAgentSeg').addEventListener('click', (e) => {
      const b = e.target.closest('.chat-agent-btn');
      if (!b) return;
      setupAgent = b.dataset.agent;
      document.querySelectorAll('#chatAgentSeg .chat-agent-btn').forEach((x) => x.classList.toggle('active', x === b));
    });
    $('chatPermSeg').addEventListener('click', (e) => {
      const b = e.target.closest('.chat-perm-btn');
      if (!b) return;
      setupPerm = b.dataset.perm;
      document.querySelectorAll('#chatPermSeg .chat-perm-btn').forEach((x) => x.classList.toggle('active', x === b));
    });

    $('chatPickDir').addEventListener('click', async () => {
      const res = await api.chatPickDir().catch(() => null);
      if (res && res.ok && res.path) $('chatCwd').value = res.path;
    });

    // Setup textarea: Cmd/Ctrl+Enter starts the session.
    $('chatSetupPrompt').addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); startSession(); }
    });

    // Composer: Enter sends, Shift+Enter is a newline; auto-grow up to the CSS max-height.
    const inp = $('chatInput');
    inp.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); sendFollowUp(); }
    });
    inp.addEventListener('input', () => {
      inp.style.height = 'auto';
      inp.style.height = Math.min(inp.scrollHeight, 140) + 'px';
    });

    $('chatSessionList').addEventListener('click', async (e) => {
      const del = e.target.closest('[data-del]');
      if (del) {
        e.stopPropagation();
        const id = del.dataset.del;
        const s = sessions.find((x) => x.id === id);
        const ok = await confirmDialog({
          title: L('chat.deleteTitle'),
          message: L('chat.deleteMsg', { name: (s && s.title) || '' }),
          confirmText: L('chat.delete'),
          cancelText: L('modal.cancel'),
          danger: true,
        });
        if (!ok) return;
        await api.chatRemove(id).catch(() => {});
        if (activeId === id) showSetup();
        await refreshSessions();
        return;
      }
      const row = e.target.closest('[data-sid]');
      if (row) openSession(row.dataset.sid);
    });

    api.onChatEvent(onChatEvent);

    try {
      const last = localStorage.getItem('ccbud-chat-cwd');
      if (last) $('chatCwd').value = last;
    } catch (_) {}
  }

  async function onShow() {
    if (!shown) { shown = true; }
    await refreshSessions();
    refreshAgents();
    if (activeId && sessions.some((s) => s.id === activeId)) {
      syncHeader();
    } else if (!sessions.length || !activeId) {
      showSetup();
    }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', bind);
  else bind();

  window.ccbudChat = { onShow };
})();
