/* ccbud export viewer runtime — part 4/4: viewer UI (outline, theme, filters, search,
   chunked highlighting, scroll-spy) and the IIFE close. Continues runtime-messages.js. */
  // ---- sidebar outline (top-level messages only) ----
  var topMsgs = [].slice.call(thread.children).filter(function (el) { return el.classList && el.classList.contains('msg'); });
  var tocHtml = '';
  topMsgs.forEach(function (el, i) {
    el.id = 'm' + i;
    var role = el.getAttribute('data-role');
    var preview = '';
    var p = el.querySelector('.prose'); if (p) preview = p.textContent.trim().slice(0, 60);
    if (!preview) { var tn = el.querySelector('.tool-name'); preview = tn ? tn.textContent : (role === 'user' ? '提问' : '回复'); }
    var tags = '';
    if (role === 'assistant') {
      var ntool = el.querySelectorAll('.tool').length, nsub = el.querySelectorAll(':scope > .body > .subagent, :scope .subagent').length;
      if (el.getAttribute('data-sub') === '1') tags += '<span class="tt sub">🤖 子代理</span>';
      if (ntool) tags += '<span class="tt">' + ntool + ' 工具</span>';
    }
    tocHtml += '<a class="toc-item ' + role + '" data-target="m' + i + '"><span class="toc-role">' + (role === 'user' ? '你' : '✦ ' + esc(AST.toUpperCase())) + '</span><span class="toc-text">' + esc(preview || '…') + '</span>' + (tags ? '<span class="toc-tags">' + tags + '</span>' : '') + '</a>';
  });
  document.getElementById('toc').innerHTML = tocHtml;

  document.getElementById('toc').addEventListener('click', function (e) {
    var it = e.target.closest('.toc-item'); if (!it) return;
    var t = document.getElementById(it.getAttribute('data-target')); if (t) t.scrollIntoView({ behavior: 'smooth', block: 'start' });
  });

  // ---- theme ----
  var THEME_KEY = 'ccbud-export-theme';
  function setTheme(t) { document.documentElement.setAttribute('data-theme', t); document.getElementById('tgTheme').textContent = t === 'dark' ? '☀️' : '🌙'; try { localStorage.setItem(THEME_KEY, t); } catch (e) {} }
  try { var saved = localStorage.getItem(THEME_KEY); if (saved) setTheme(saved); else setTheme(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'); } catch (e) { setTheme('light'); }
  document.getElementById('tgTheme').addEventListener('click', function () { setTheme(document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark'); });

  // ---- sidebar toggle ----
  document.getElementById('tgSidebar').addEventListener('click', function () { app.classList.toggle('nosidebar'); });

  // ---- filters ----
  var filters = app.querySelectorAll('.sidebar-filters button');
  filters.forEach(function (btn) {
    btn.addEventListener('click', function () {
      filters.forEach(function (b) { b.classList.remove('active'); }); btn.classList.add('active');
      var f = btn.getAttribute('data-filter');
      topMsgs.forEach(function (el) {
        var show = f === 'all' || (f === 'user' && el.getAttribute('data-role') === 'user') || (f === 'tool' && el.getAttribute('data-tool') === '1') || (f === 'sub' && el.getAttribute('data-sub') === '1');
        el.classList.toggle('hide', !show);
      });
      document.querySelectorAll('.toc-item').forEach(function (it) {
        var el = document.getElementById(it.getAttribute('data-target'));
        it.style.display = el && el.classList.contains('hide') ? 'none' : '';
      });
    });
  });

  // ---- search (highlight + nav, opens matching <details>) ----
  var hits = [], cur = -1, qTimer;
  function clearHits() {
    content.querySelectorAll('mark.s-hit').forEach(function (m) { var p = m.parentNode; if (p) { p.replaceChild(document.createTextNode(m.textContent), m); p.normalize(); } });
    hits = []; cur = -1; document.getElementById('qc').textContent = '';
  }
  function doSearch(q) {
    clearHits(); if (!q) return;
    var rx = new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi');
    var walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, null), nodes = [], n;
    while ((n = walker.nextNode())) { if (n.nodeValue && n.nodeValue.trim() && n.parentNode && n.parentNode.nodeName !== 'SCRIPT') nodes.push(n); }
    nodes.forEach(function (tn) {
      var txt = tn.nodeValue; rx.lastIndex = 0; if (!rx.test(txt)) return; rx.lastIndex = 0;
      var frag = document.createDocumentFragment(), last = 0, mm;
      while ((mm = rx.exec(txt))) { if (mm.index > last) frag.appendChild(document.createTextNode(txt.slice(last, mm.index))); var mk = document.createElement('mark'); mk.className = 's-hit'; mk.textContent = mm[0]; frag.appendChild(mk); hits.push(mk); last = mm.index + mm[0].length; if (mm.index === rx.lastIndex) rx.lastIndex++; }
      if (last < txt.length) frag.appendChild(document.createTextNode(txt.slice(last)));
      tn.parentNode.replaceChild(frag, tn);
    });
    if (hits.length) go(0);
    document.getElementById('qc').textContent = hits.length ? '1/' + hits.length : '0';
  }
  function go(i) {
    if (!hits.length) return;
    if (cur >= 0 && hits[cur]) hits[cur].classList.remove('cur');
    cur = (i % hits.length + hits.length) % hits.length;
    var el = hits[cur]; el.classList.add('cur');
    var d = el.closest('details'); while (d) { d.open = true; d = d.parentNode && d.parentNode.closest ? d.parentNode.closest('details') : null; }
    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
    document.getElementById('qc').textContent = (cur + 1) + '/' + hits.length;
  }
  var qInput = document.getElementById('q');
  qInput.addEventListener('input', function () { clearTimeout(qTimer); qTimer = setTimeout(function () { doSearch(qInput.value.trim()); }, 160); });
  qInput.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); go(cur + (e.shiftKey ? -1 : 1)); } });
  document.getElementById('qnext').addEventListener('click', function () { go(cur + 1); });
  document.getElementById('qprev').addEventListener('click', function () { go(cur - 1); });

  // ---- code highlighting (chunked, non-blocking) ----
  if (hljs) {
    var codes = [].slice.call(content.querySelectorAll('pre code')), ci = 0;
    (function step() { var end = Math.min(ci + 30, codes.length); for (; ci < end; ci++) { try { hljs.highlightElement(codes[ci]); } catch (e) {} } if (ci < codes.length) (window.requestAnimationFrame || setTimeout)(step); })();
  }

  // ---- scroll-spy (highlight current section in outline) ----
  var spy;
  content.addEventListener('scroll', function () {
    clearTimeout(spy); spy = setTimeout(function () {
      var top = content.scrollTop + 80, active = null;
      for (var i = 0; i < topMsgs.length; i++) { if (topMsgs[i].offsetTop <= top) active = i; else break; }
      document.querySelectorAll('.toc-item').forEach(function (it) { it.classList.toggle('active', it.getAttribute('data-target') === ('m' + active)); });
    }, 90);
  });
})();
