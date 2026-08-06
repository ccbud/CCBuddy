/* ccbud export viewer runtime — part 2/4: shared helpers, tool cards and subagent blocks.
   The four runtime-*.js parts are concatenated VERBATIM (in name order, see exporthtml.rs)
   into one <script> block, so they share the render IIFE's closure — the cuts sit at
   statement boundaries and the parts are not independently loadable. */
(function () {
  var D = window.__CONV__ || { meta: {}, messages: [], subagents: {} };
  var marked = window.marked, hljs = window.hljs;
  if (marked && marked.setOptions) {
    marked.setOptions({ gfm: true, breaks: true });
    try { marked.use({ renderer: { html: function (t) { return esc(typeof t === 'string' ? t : (t && t.text) || ''); } } }); } catch (e) {}
  }

  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function md(t) { try { return marked ? marked.parse(String(t || '')) : '<p>' + esc(t) + '</p>'; } catch (e) { return '<p>' + esc(t) + '</p>'; } }
  function fmtTok(n) { n = n || 0; if (n < 1000) return '' + n; if (n < 1e6) return (n / 1e3).toFixed(n < 1e4 ? 1 : 0).replace(/\.0$/, '') + 'K'; return (n / 1e6).toFixed(1).replace(/\.0$/, '') + 'M'; }
  function fmtCredits(n) { n = Number(n); if (!isFinite(n)) return '—'; var a = Math.abs(n), s = a >= 1000 ? (n / 1000).toFixed(a < 10000 ? 1 : 0) : a >= 100 ? n.toFixed(1) : a >= 1 ? n.toFixed(2) : n.toFixed(3); s = s.replace(/(\.\d*?[1-9])0+$|\.0+$/, '$1'); return a >= 1000 ? s + 'K' : s; }
  function size(s) { var b = s ? s.length : 0; if (!b) return ''; return b < 1024 ? b + ' B' : (b / 1024).toFixed(1) + ' KB'; }
  function trunc(s, n) { s = String(s == null ? '' : s); return s.length > n ? s.slice(0, n) + '…' : s; }
  function shortPath(p) { if (!p) return ''; var a = String(p).split('/'); return a.length > 3 ? '…/' + a.slice(-2).join('/') : p; }

  // results map: tool_use_id -> tool_result, across main + every subagent
  function collectResults(msgs, map) { (msgs || []).forEach(function (m) { (Array.isArray(m.content) ? m.content : []).forEach(function (b) { if (b && b.type === 'tool_result') map[b.tool_use_id] = b; }); }); }
  var RESULTS = {};
  collectResults(D.messages, RESULTS);
  Object.keys(D.subagents || {}).forEach(function (k) { collectResults(D.subagents[k].messages, RESULTS); });
  var USED = {}; // subagent keys embedded inline under their spawn tool

  var TOOL = {
    Bash: ['⌘', 'exec'], Script: ['📜', 'exec'], Read: ['📖', 'read'], Edit: ['✏️', 'write'], MultiEdit: ['✏️', 'write'], Write: ['📝', 'write'], ApplyPatch: ['✏️', 'write'],
    Grep: ['🔎', 'search'], Glob: ['🔎', 'search'], TodoWrite: ['✅', 'todo'], TaskCreate: ['✅', 'todo'], TaskUpdate: ['✅', 'todo'], TaskList: ['✅', 'todo'],
    Agent: ['🤖', 'agent'], Task: ['🤖', 'agent'], Workflow: ['🛠️', 'agent'], WebSearch: ['🌐', 'net'], WebFetch: ['🌐', 'net'], AskUserQuestion: ['❓', 'ask']
  };
  function toolMeta(n) { if (TOOL[n]) return TOOL[n]; if (/^mcp__/.test(n)) return ['🧩', 'mcp']; return ['🔧', 'default']; }
  // Codex apply_patch envelope: "*** Update File: x" headers → the card's target (file, or "N files").
  function patchTarget(patch) {
    var files = [];
    String(patch || '').split('\n').forEach(function (l) { var m = /^\*\*\*\s+(?:Add|Update|Delete)\s+File:\s+(.+)$/.exec(l.trim()); if (m) files.push(m[1].trim()); });
    if (!files.length) return '';
    return files.length === 1 ? shortPath(files[0]) : files.length + ' files';
  }
  function toolTarget(n, i) {
    if (n === 'Bash') return i.description || '';
    if (n === 'Read' || n === 'Edit' || n === 'MultiEdit' || n === 'Write') return shortPath(i.file_path);
    if (n === 'ApplyPatch') return patchTarget(i.patch);
    if (n === 'Grep' || n === 'Glob') return i.pattern || '';
    if (n === 'Agent' || n === 'Task') return i.subagent_type || 'agent';
    if (n === 'WebSearch') return i.query || ''; if (n === 'WebFetch') return i.url || ''; if (n === 'Workflow') return i.name || '';
    return '';
  }
  function resultText(b) { if (!b) return ''; var c = b.content; if (typeof c === 'string') return c; if (Array.isArray(c)) return c.map(function (x) { return x && x.type === 'text' ? x.text : (x && x.text) || ''; }).join('\n'); return c == null ? '' : JSON.stringify(c); }
  function codePre(t, lang) { return '<pre class="code"><code' + (lang ? ' class="language-' + esc(lang) + '"' : '') + '>' + esc(trunc(t, 16000)) + '</code></pre>'; }
  function diff(o, n) { o = String(o || '').split('\n'); n = String(n || '').split('\n'); return '<div class="diff">' + o.map(function (l) { return '<div class="d-del">- ' + esc(l) + '</div>'; }).join('') + n.map(function (l) { return '<div class="d-add">+ ' + esc(l) + '</div>'; }).join('') + '</div>'; }
  function todos(list) { return '<div class="todos">' + (list || []).map(function (t) { var m = t.status === 'completed' ? '☑' : t.status === 'in_progress' ? '◐' : '☐'; return '<div class="todo ' + esc(t.status || '') + '"><span class="box">' + m + '</span>' + esc(t.content || t.activeForm || '') + '</div>'; }).join('') + '</div>'; }

  function renderSkillLoad(b) {
    var name = b.name || 'Skill';
    var path = b.path || '';
    var snapshot = typeof b.snapshot === 'string' ? b.snapshot : '';
    var detail = '';
    if (b.snapshot != null) {
      detail = '<details class="skill-snapshot"><summary><span class="skill-caret">›</span><span>查看加载时快照</span>' + (snapshot ? '<span class="skill-size">' + esc(size(snapshot)) + '</span>' : '') + '</summary>' +
        '<div class="skill-snapshot-body"><div class="lbl">来源路径</div><div class="skill-source" title="' + esc(path) + '">' + esc(path || '未记录') + '</div>' +
        '<div class="lbl">Markdown 源码</div><pre class="code skill-snapshot-code"><code class="language-markdown">' + esc(snapshot) + '</code></pre></div></details>';
    }
    return '<div class="tool tool-skill skill-load-card"><div class="skill-load-head"><span class="tool-ico">🧩</span><span class="skill-loaded-label">Skill 已加载</span><span class="skill-load-name">' + esc(name) + '</span><span class="tool-target" title="' + esc(path) + '">' + esc(shortPath(path)) + '</span></div>' + detail + '</div>';
  }

  function renderTool(b) {
    var name = b.name || 'tool', inp = (b.input && typeof b.input === 'object') ? b.input : {};
    var tm = toolMeta(name), ico = tm[0], cls = tm[1];
    var label = /^mcp__/.test(name) ? ('MCP · ' + name.replace(/^mcp__/, '')) : name;
    var target = toolTarget(name, inp), body = '';
    if (name === 'Bash') body += '<pre class="code"><code>$ ' + esc(inp.command || '') + '</code></pre>';
    else if (name === 'Script') body += codePre(inp.code || '', 'javascript');
    else if (name === 'ApplyPatch') body += codePre(inp.patch || '', 'diff');
    else if (name === 'Edit') body += diff(inp.old_string, inp.new_string);
    else if (name === 'MultiEdit') body += (Array.isArray(inp.edits) ? inp.edits : []).map(function (e) { return diff(e.old_string, e.new_string); }).join('');
    else if (name === 'Write') body += codePre(inp.content || '');
    else if (name === 'Grep') { if (inp.path) body += '<div class="tool-desc">in ' + esc(inp.path) + '</div>'; }
    else if (name === 'TodoWrite') body += todos(inp.todos);
    else if (name === 'Agent' || name === 'Task') { if (inp.description) body += '<div class="tool-desc">' + esc(inp.description) + '</div>'; if (inp.prompt) body += '<div class="lbl">prompt</div>' + codePre(inp.prompt); }
    else if (Object.keys(inp).length) body += codePre(JSON.stringify(inp, null, 2));

    var res = RESULTS[b.id], badge, resHtml = '';
    if (res) { var err = !!res.is_error, txt = resultText(res); badge = '<span class="tool-badge ' + (err ? 'err' : 'ok') + '">' + (err ? '✗' : '✓') + (size(txt) ? ' ' + size(txt) : '') + '</span>'; if (txt) resHtml = '<div class="lbl">' + (err ? 'error' : 'result') + '</div><pre class="code tool-result-pre"><code>' + esc(trunc(txt, 16000)) + '</code></pre>'; }
    else badge = '<span class="tool-badge">—</span>';

    var sub = (D.subagents || {})[b.id];
    if (sub) USED[b.id] = true;
    var inner = (body || resHtml) ? ('<div class="tool-body">' + body + resHtml + '</div>') : '';
    var open = (name === 'Agent' || name === 'Task' || (res && res.is_error)) ? ' open' : '';
    return '<details class="tool tool-' + cls + '"' + open + '><summary class="tool-head"><span class="tool-ico">' + ico + '</span><span class="tool-name">' + esc(label) + '</span><span class="tool-target">' + esc(target) + '</span>' + badge + '</summary>' + inner + '</details>' + (sub ? renderSubagent(sub) : '');
  }
  function renderSubagent(sub) {
    var subName = (sub.type || 'agent') + (sub.skill ? ':' + sub.skill : ''); // skill-spawned agents carry the invoking skill
    var totals = sub.totals || {}, usage = [];
    if (totals.tokenUsageAvailable !== false) usage.push(fmtTok(totals.out || 0) + '↓');
    if (totals.credits != null) usage.push(fmtCredits(totals.credits) + ' Credits');
    return '<div class="subagent"><details class="subagent-d"><summary><span class="subagent-ico">🤖</span><span class="subagent-title">子代理 · ' + esc(subName) + '</span><span class="subagent-desc">' + esc(sub.description || '') + '</span><span class="subagent-count">' + (sub.count || 0) + ' 条 · ' + esc(usage.join(' · ') || '—') + '</span></summary><div class="subagent-body"><div class="thread">' + renderThread(sub.messages || []) + '</div></div></details></div>';
  }

