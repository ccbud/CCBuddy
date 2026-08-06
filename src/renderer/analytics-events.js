'use strict';
/*
 * Usage analytics — DOM event layer. Loaded (deferred) right after analytics.js, which owns the
 * Clarity queue, identity and boot, and publishes window.ccTrack / window.ccTag for this file.
 *
 * Privacy: only element identifiers, i18n keys and enum-ish dataset values ever become event
 * names — free text, input values and content-bearing dataset payloads (paths, session ids,
 * urls) never leave the app.
 */
(function () {
  var track = window.ccTrack, tag = window.ccTag;
  if (!track || !tag) return;

  /* ---------- interaction descriptors ---------- */
  // Enum-ish dataset keys whose VALUES are safe to report (fixed UI vocabulary).
  var ENUM_KEYS = ['view', 'settings', 'tab', 'range', 'hrange', 'preset', 'copy', 'export', 'icon'];
  // Content-bearing dataset keys: report the bare key name, never the value.
  var NAME_KEYS = ['proj', 'file', 'id', 'target', 'act', 'tip'];

  function classToken(n) {
    return typeof n.className === 'string' ? n.className.trim().split(/\s+/)[0] : '';
  }
  function descriptor(start) {
    for (var n = start, depth = 0; n && n.nodeType === 1 && depth < 15; n = n.parentElement, depth++) {
      if (n.id) return '#' + n.id;
      var d = n.dataset;
      if (d) {
        for (var i = 0; i < ENUM_KEYS.length; i++) if (d[ENUM_KEYS[i]]) return ENUM_KEYS[i] + '=' + d[ENUM_KEYS[i]];
        if (d.i18n) return 'i18n:' + d.i18n;
        if (d.i18nTitle) return 'i18n:' + d.i18nTitle;
        // Dynamic list items (provider cards, sessions, stream rows): label them by
        // their semantic class token, never by the id/path payload they carry.
        for (var j = 0; j < NAME_KEYS.length; j++) if (d[NAME_KEYS[j]] != null) return classToken(n) || 'data-' + NAME_KEYS[j];
      }
    }
    var el = start && start.closest ? start.closest('button, a, summary, label, [role="button"], input, select') : null;
    var probe = el || start;
    if (probe && probe.nodeType === 1) {
      var cls = classToken(probe);
      return probe.tagName.toLowerCase() + (cls ? '.' + cls : '');
    }
    return 'unknown';
  }

  // Semantic funnel layer: element id → business event (fires alongside the raw click).
  var FUNNEL = {
    btnConnect: 'connect-toggle',
    popConnect: 'connect-toggle',
    btnAdd: 'provider-add',
    btnAddEmpty: 'provider-add',
    btnSave: 'provider-save',
    btnTest: 'provider-test',
    btnUpdateCheck: 'update-check',
    btnUpdateDownload: 'update-download',
    btnUpdateApply: 'update-apply',
    btnUpdateOpen: 'update-open',
    btnUpdateBrew: 'update-brew',
    convImportBtn: 'conv-import',
    convExportBtn: 'conv-export',
    convReplayBtn: 'conv-replay',
    convChatgptBtn: 'conv-chatgpt',
    convCopyPathBtn: 'conv-copy-path',
    btnCopyExport: 'copy-export',
    btnGenToken: 'token-generate',
    btnPickHistDir: 'histdir-pick',
    popOpen: 'popover-open-main',
    popQuit: 'app-quit'
  };

  /* ---------- listeners (capture phase, so no UI code can swallow them) ---------- */
  document.addEventListener('click', function (e) {
    var t = e.target && e.target.nodeType === 1 ? e.target : null;
    if (!t) return;
    track('click:' + descriptor(t));

    var host = t.closest ? t.closest('[id]') : null;
    if (host && FUNNEL[host.id]) track('goal:' + FUNNEL[host.id]);
    // Theme flips after the app handler runs — re-read it on the next tick.
    if (host && host.id === 'btnTheme') {
      setTimeout(function () { try { tag('theme', localStorage.getItem('ccbud-theme') || ''); } catch (_) {} }, 0);
    }

    // Virtual page views: sidebar views, settings panes, popover tabs.
    var nav = t.closest ? t.closest('[data-view],[data-settings],[data-tab]') : null;
    if (nav) {
      var d = nav.dataset;
      var view = d.view || (d.settings ? 'settings/' + d.settings : 'popover/' + d.tab);
      track('view:' + view);
      tag('view', view);
    }
    var fmt = t.closest ? t.closest('[data-export]') : null;
    if (fmt) track('goal:conv-export:' + fmt.dataset.export);
  }, true);

  document.addEventListener('contextmenu', function (e) {
    if (e.target && e.target.nodeType === 1) track('rclick:' + descriptor(e.target));
  }, true);
  document.addEventListener('dblclick', function (e) {
    if (e.target && e.target.nodeType === 1) track('dblclick:' + descriptor(e.target));
  }, true);
  document.addEventListener('dragend', function (e) {
    if (e.target && e.target.nodeType === 1) track('drag:' + descriptor(e.target));
  }, true);

  // Committed control changes: checkbox/radio state and enum select values are safe;
  // for anything free-form only the field identity is reported.
  document.addEventListener('change', function (e) {
    var t = e.target;
    if (!t || t.nodeType !== 1) return;
    var name = t.id || t.name || descriptor(t);
    var suffix = '';
    if (t.type === 'checkbox' || t.type === 'radio') suffix = t.checked ? ':on' : ':off';
    else if (t.tagName === 'SELECT') suffix = ':' + String(t.value).slice(0, 32);
    track('change:' + name + suffix);
    if (t.id === 'fLang') tag('lang', t.value);
  }, true);

  // First keystroke per field per window life — signals "user typed here", no content.
  var typed = {};
  document.addEventListener('input', function (e) {
    var t = e.target;
    if (!t || t.nodeType !== 1) return;
    var k = t.id || t.name || t.tagName;
    if (typed[k]) return;
    typed[k] = 1;
    track('input:' + k);
  }, true);

  /* ---------- errors ---------- */
  // Error messages can embed user paths or URLs — redact those before tagging.
  function scrubError(s) {
    return String(s == null ? 'unknown' : s)
      .replace(/(?:file|https?):\/\/[^\s'")]+/gi, '<url>')
      .replace(/(^|[\s'"(=:,])(?:~\/|\/)[^\s'")]+/g, '$1<path>')
      .replace(/[A-Za-z]:\\[^\s'")]+/g, '<path>')
      .slice(0, 120);
  }
  window.addEventListener('error', function (e) {
    if (e && e.target && e.target !== window && e.target.nodeType === 1) {
      track('error:resource:' + (e.target.tagName || '').toLowerCase());
      return;
    }
    track('error:js');
    tag('lastError', scrubError(e && e.message));
    try { window.clarity('upgrade', 'js-error'); } catch (_) {}
  }, true);
  window.addEventListener('unhandledrejection', function (e) {
    var r = e && e.reason;
    track('error:unhandled-rejection');
    tag('lastError', scrubError(r && r.message ? r.message : r));
    try { window.clarity('upgrade', 'js-error'); } catch (_) {}
  });

  /* ---------- window foreground/background ---------- */
  document.addEventListener('visibilitychange', function () {
    track(document.hidden ? 'app:hidden' : 'app:visible');
  });
})();
