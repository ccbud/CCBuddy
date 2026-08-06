/* ccbud export viewer runtime — part 3/4: message/thread rendering (Codex bootstrap folding,
   injected-block stripping, blocks, turn meta, thread + meta line). Continues the render
   IIFE opened in runtime-render.js. */
  function formatCodexBootstrap(text) {
    var source = String(text || '');
    var agents = /^\s*#\s+AGENTS\.md instructions for ([^\r\n]+)[\s\S]*?<INSTRUCTIONS\b[^>]*>([\s\S]*?)<\/INSTRUCTIONS>/i.exec(source);
    if (!agents) return null;

    var env = /<environment_context\b[^>]*>([\s\S]*?)<\/environment_context>/i.exec(source);
    var parts = ['# AGENTS.md instructions for ' + agents[1].trim()];
    var instructions = agents[2].trim();
    if (instructions) {
      var lines = instructions.split(/\r?\n/).filter(function (line) { return line.trim(); });
      parts.push(lines.length === 1
        ? '**INSTRUCTIONS:** ' + lines[0].trim()
        : '**INSTRUCTIONS:**\n\n' + instructions);
    }

    if (env) {
      var block = env[1];
      var tag = function (name) {
        var match = new RegExp('<' + name + '\\b[^>]*>([\\s\\S]*?)<\\/' + name + '>', 'i').exec(block);
        return match ? match[1].trim() : '';
      };
      var attr = function (name, attribute) {
        var match = new RegExp("<" + name + "\\b[^>]*\\b" + attribute + "=[\"']([^\"']+)[\"']", "i").exec(block);
        return match ? match[1].trim() : '';
      };
      var code = function (value) {
        var tick = String.fromCharCode(96);
        return value ? tick + value + tick : '';
      };
      var roots = [];
      var rootRe = /<root\b[^>]*>([\s\S]*?)<\/root>/gi;
      var root;
      while ((root = rootRe.exec(block)) !== null) {
        if (root[1].trim()) roots.push(code(root[1].trim()));
      }
      var fields = [
        ['environment_context', code(tag('cwd'))],
        ['shell', tag('shell')],
        ['current_date', tag('current_date')],
        ['timezone', tag('timezone')],
        ['workspace_roots', roots.join(', ')],
        ['permission_profile', attr('permission_profile', 'type')],
        ['file_system', attr('file_system', 'type')],
      ].filter(function (field) { return field[1]; });
      if (fields.length) {
        parts.push(fields.map(function (field) { return '**' + field[0] + ':** ' + field[1]; }).join('  \n'));
      }
    }

    var rest = source.replace(agents[0], '');
    if (env) rest = rest.replace(env[0], '');
    rest = rest.trim();
    if (rest) parts.push(rest);
    return parts.join('\n\n').trim();
  }
  function stripInjected(text) {
    var source = String(text || '');
    var bootstrap = formatCodexBootstrap(source);
    if (bootstrap != null) source = bootstrap;
    if (/^\s*<skill\b[^>]*>[\s\S]*<\/skill>\s*$/i.test(source)) return '';
    return source
      .replace(/<task-notification\b[^>]*>[\s\S]*?<\/task-notification>/gi, function (block) {
        var result = /<result\b[^>]*>([\s\S]*?)<\/result>/i.exec(block);
        return result ? '\n' + result[1].trim() + '\n' : '';
      })
      .replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '')
      .replace(/<command-[a-z-]+>[\s\S]*?<\/command-[a-z-]+>/g, '')
      .replace(/<local-command-[a-z]+>[\s\S]*?<\/local-command-[a-z]+>/g, '')
      .trim();
  }
  function renderBlocks(content, cleanUserText) {
    var blocks = Array.isArray(content) ? content : (typeof content === 'string' ? [{ type: 'text', text: content }] : []);
    var out = '';
    blocks.forEach(function (b) {
      if (!b) return;
      if (b.type === 'text') { var text = cleanUserText ? stripInjected(b.text) : b.text; if (text && text.trim()) out += '<div class="prose">' + md(text) + '</div>'; }
      else if (b.type === 'thinking') { if (b.thinking && b.thinking.trim()) { var first = b.thinking.split('\n').filter(function (x) { return x.trim(); })[0] || ''; out += '<details class="thinking"><summary>💭 思考 · ' + esc(trunc(first, 64)) + '</summary><div class="prose">' + md(b.thinking) + '</div></details>'; } }
      else if (b.type === 'skill_load') out += renderSkillLoad(b);
      else if (b.type === 'tool_use') out += renderTool(b);
      else if (b.type === 'image') { var s = b.source || {}; out += s.data ? '<img class="msg-img" style="max-width:340px;border-radius:10px;border:1px solid var(--border);margin:6px 0" src="data:' + esc(s.media_type || 'image/png') + ';base64,' + esc(s.data) + '">' : '<div class="tool-desc">🖼 image' + (s.oversized ? ' (large, omitted)' : '') + '</div>'; }
    });
    return out;
  }
  function turnMeta(m) {
    var bits = []; if (m.model) bits.push(esc(m.model));
    if (m.usage) {
      var tokenTotal = (m.usage.in || 0) + (m.usage.out || 0) + (m.usage.cacheRead || 0) + (m.usage.cacheCreation || 0);
      if (m.usage.credits == null || tokenTotal > 0) bits.push(fmtTok(m.usage.in) + '↑ ' + fmtTok(m.usage.out) + '↓');
      if (m.usage.credits != null) bits.push(fmtCredits(m.usage.credits) + ' Credits');
    }
    if (m.usage && m.usage.cacheRead) bits.push(fmtTok(m.usage.cacheRead) + ' cache');
    return bits.length ? '<div style="display:flex;gap:6px;flex-wrap:wrap;margin-top:6px">' + bits.map(function (b) { return '<span style="font-size:9.5px;font-family:ui-monospace,monospace;color:var(--text-faint);background:var(--surface-2);border-radius:4px;padding:1px 6px">' + b + '</span>'; }).join('') + '</div>' : '';
  }
  function msgVisible(m) {
    var bl = Array.isArray(m.content) ? m.content : (typeof m.content === 'string' ? [{ type: 'text', text: m.content }] : []);
    if (m.role === 'user') { var vis = bl.filter(function (b) { return b && (b.type === 'text' || b.type === 'image'); }); if (!vis.length) return false; var hasImage = vis.some(function (b) { return b.type === 'image'; }); var txt = vis.map(function (b) { return b.type === 'text' ? stripInjected(b.text) : ''; }).filter(Boolean).join('\n'); return hasImage || !!txt; }
    return bl.some(function (b) { return b && (b.type === 'text' || b.type === 'thinking' || b.type === 'tool_use' || b.type === 'image'); });
  }
  // tags for sidebar/filtering
  function msgTags(m) {
    var t = { tool: 0, sub: 0 };
    (Array.isArray(m.content) ? m.content : []).forEach(function (b) { if (b && b.type === 'tool_use') { t.tool++; if ((D.subagents || {})[b.id]) t.sub++; } });
    return t;
  }
  function renderThread(msgs) {
    var out = '';
    (msgs || []).forEach(function (m) {
      var blocks = Array.isArray(m.content) ? m.content : (typeof m.content === 'string' ? [{ type: 'text', text: m.content }] : []);
      var skillBlocks = blocks.filter(function (b) { return b && b.type === 'skill_load'; });
      if (skillBlocks.length) out += '<div class="skill-load-event" data-meta="1">' + skillBlocks.map(renderSkillLoad).join('') + '</div>';
      var regularBlocks = blocks.filter(function (b) { return !b || b.type !== 'skill_load'; });
      var regular = Object.assign({}, m, { content: regularBlocks });
      if (!msgVisible(regular)) return;
      var body = renderBlocks(regularBlocks, m.role === 'user'); if (!body) return;
      if (m.role === 'user') out += '<div class="msg user" data-role="user"><div class="msg-name">👤 你</div><div class="bubble">' + body + '</div></div>';
      else { var tg = msgTags(m); out += '<div class="msg assistant" data-role="assistant" data-tool="' + (tg.tool ? 1 : 0) + '" data-sub="' + (tg.sub ? 1 : 0) + '"><div class="msg-name"><span class="dot">✦</span>' + esc(AST) + '</div><div class="body">' + body + turnMeta(m) + '</div></div>'; }
    });
    return out;
  }

  // ===== build shell =====
  var meta = D.meta || {};
  var AST = meta.assistant || 'Claude'; // assistant display name (Codex rollouts export with "Codex")
  function metaLine() {
    var p = [];
    if (meta.model) p.push('<b>' + esc(meta.model) + '</b>');
    if (meta.project) p.push(esc(meta.project));
    if (meta.turns) p.push(meta.turns + ' 轮');
    if (meta.inTok != null && meta.tokenUsageAvailable !== false) p.push(fmtTok(meta.inTok) + '↑ ' + fmtTok(meta.outTok) + '↓');
    if (meta.credits != null) p.push(fmtCredits(meta.credits) + ' Credits');
    if (meta.cacheTok) p.push(fmtTok(meta.cacheTok) + ' 缓存');
    if (meta.subagentCount) p.push(meta.subagentCount + ' 子代理');
    return p.join(' · ');
  }
  var threadHtml = renderThread(D.messages) || '<div class="empty">空对话</div>';
  var orphanKeys = Object.keys(D.subagents || {}).filter(function (k) { return !USED[k]; });
  var orphanHtml = orphanKeys.length
    ? '<div class="msg assistant" data-role="assistant" data-sub="1"><div class="msg-name"><span class="dot">🤖</span>其他子代理 (' + orphanKeys.length + ')</div><div class="body"><div class="tool-desc">下列子代理未在主时间线中找到明确的调用点（可能由工作流派生或调用记录已省略），单独列出以便查看：</div>' + orphanKeys.map(function (k) { return renderSubagent(D.subagents[k]); }).join('') + '</div></div>'
    : '';
  var app = document.getElementById('app');
  app.innerHTML =
    '<header class="topbar">' +
      '<button class="icon-btn" id="tgSidebar" title="侧边栏">☰</button>' +
      '<div class="topbar-title"><h1>' + esc(meta.title || '对话') + '</h1><div class="topbar-meta">' + metaLine() + '</div></div>' +
      '<div class="topbar-actions">' +
        '<div class="search"><span style="color:var(--text-faint);font-size:12px">🔎</span><input id="q" placeholder="搜索对话…" spellcheck="false"><span class="search-count" id="qc"></span><button class="icon-btn" id="qprev" title="上一个">↑</button><button class="icon-btn" id="qnext" title="下一个">↓</button></div>' +
        '<button class="icon-btn" id="tgTheme" title="切换主题">🌙</button>' +
      '</div>' +
    '</header>' +
    '<div class="workspace">' +
      '<aside class="sidebar">' +
        '<div class="sidebar-filters">' +
          '<button data-filter="all" class="active">全部</button>' +
          '<button data-filter="user">提问</button>' +
          '<button data-filter="tool">工具</button>' +
          '<button data-filter="sub">子代理</button>' +
        '</div><nav class="toc" id="toc"></nav>' +
      '</aside>' +
      '<main class="content"><div class="thread" id="thread">' + threadHtml + orphanHtml + '</div>' +
      '<div class="footer">由 <a class="footer-link" href="https://ccbud.github.io/" target="_blank" rel="noopener">CC Buddy</a> 导出 · ' + (meta.count || 0) + ' 条消息' + (meta.subagentCount ? ' · ' + meta.subagentCount + ' 个子代理' : '') + '<div class="footer-site"><a class="footer-link" href="https://ccbud.github.io/" target="_blank" rel="noopener">https://ccbud.github.io/</a></div></div></main>' +
    '</div>';

  var content = app.querySelector('.content');
  var thread = document.getElementById('thread');

