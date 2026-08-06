/* ccbud export viewer runtime. Renders window.__CONV__ into a Claude-styled, themeable,
   searchable single-file app with a sidebar outline and expandable tools/subagents. */

/* ---- usage analytics (Microsoft Clarity) ----
   Runs first (inside the generator's nonce'd script block) so viewer-runtime errors are
   captured too; the injected tag is allowed by the export CSP's clarity.ms origins (see
   exporthtml.rs / exportHtml.js). Offline viewers just queue into the stub and send
   nothing. Only element identifiers ever become event names — message text, paths and
   titles are never sent. */
(function () {
  try {
    var PROJECT_ID = 'xij8wflxsj';
    window.clarity = window.clarity || function () { (window.clarity.q = window.clarity.q || []).push(arguments); };
    if (!document.getElementById('clarity-script')) {
      var s = document.createElement('script');
      s.async = true; s.id = 'clarity-script';
      s.src = 'https://www.clarity.ms/tag/' + PROJECT_ID;
      (document.head || document.documentElement).appendChild(s);
    }
    var track = function (n) { try { window.clarity('event', String(n).slice(0, 250)); } catch (e) {} };
    var tag = function (k, v) { try { if (v != null && v !== '') window.clarity('set', k, String(v).slice(0, 250)); } catch (e) {} };
    var meta = (window.__CONV__ && window.__CONV__.meta) || {};
    tag('surface', 'export');
    tag('assistant', meta.assistant || 'Claude');
    tag('appVersion', window.__CCBUD_VERSION__); // version of the app that generated this export
    track('export:open');
    var name = function (el) {
      for (var n = el, d = 0; n && n.nodeType === 1 && d < 15; n = n.parentElement, d++) {
        if (n.id) return /^m\d+$/.test(n.id) ? '#msg' : '#' + n.id;
        var cls = typeof n.className === 'string' ? n.className.trim().split(/\s+/)[0] : '';
        if (cls) return n.tagName.toLowerCase() + '.' + cls;
      }
      return el && el.nodeType === 1 ? el.tagName.toLowerCase() : 'unknown';
    };
    document.addEventListener('click', function (e) {
      if (e.target && e.target.nodeType === 1) track('click:' + name(e.target));
    }, true);
    var searched = false;
    document.addEventListener('input', function (e) {
      if (!searched && e.target && e.target.id === 'q') { searched = true; track('export:search'); }
    }, true);
    // Error messages can embed local paths or URLs — redact those before tagging.
    var scrubError = function (s) {
      return String(s == null ? 'unknown' : s)
        .replace(/(?:file|https?):\/\/[^\s'")]+/gi, '<url>')
        .replace(/(^|[\s'"(=:,])(?:~\/|\/)[^\s'")]+/g, '$1<path>')
        .replace(/[A-Za-z]:\\[^\s'")]+/g, '<path>')
        .slice(0, 120);
    };
    window.addEventListener('error', function (e) {
      if (e && e.target && e.target !== window && e.target.nodeType === 1) return;
      track('error:js'); tag('lastError', scrubError(e && e.message));
      try { window.clarity('upgrade', 'js-error'); } catch (err) {}
    }, true);
    window.addEventListener('unhandledrejection', function (e) {
      var r = e && e.reason;
      track('error:unhandled-rejection'); tag('lastError', scrubError(r && r.message ? r.message : r));
    });
  } catch (e) {}
})();

