'use strict';
/* Pre-paint boot stamp — the ONLY synchronous script on the startup path. Sets the theme
   and locale attributes from localStorage before first paint so neither flashes; every
   other script is deferred (analytics) or an ES module (the app), which never block paint. */
(function () {
  var doc = document.documentElement;
  var theme = 'light';
  try { theme = localStorage.getItem('ccbud-theme') || 'light'; } catch (_) {}
  doc.setAttribute('data-theme', theme);
  if (theme === 'dark') {
    // The hljs sheets are toggled via media attrs; stamp the dark one on before paint.
    var hd = document.getElementById('hljs-dark');
    var hl = document.getElementById('hljs-light');
    if (hd) hd.media = 'all';
    if (hl) hl.media = 'not all';
  }
  var lang = '';
  try { lang = localStorage.getItem('ccbud-lang') || ''; } catch (_) {}
  if (!lang) {
    var nav = (navigator.language || 'en').toLowerCase();
    lang = nav.indexOf('zh') === 0 ? ((/-(tw|hk|mo)\b/.test(nav) || nav.indexOf('hant') >= 0) ? 'zh-TW' : 'zh')
      : nav.indexOf('ja') === 0 ? 'ja' : nav.indexOf('ko') === 0 ? 'ko' : 'en';
  }
  var tags = { en: 'en-US', zh: 'zh-CN', 'zh-TW': 'zh-TW', ja: 'ja-JP', ko: 'ko-KR' };
  doc.setAttribute('lang', tags[lang] || 'en-US');
})();
