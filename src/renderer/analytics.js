'use strict';
/*
 * Usage analytics — Microsoft Clarity (https://clarity.microsoft.com).
 *
 * Loaded (deferred) in both windows (index.html + popover.html) so the `clarity` command
 * queue exists before any UI code runs; the real tag is then loaded async through the
 * vendored @microsoft/clarity npm package (vendor/clarity, synced from node_modules
 * by `npm run sync:clarity`). This file owns the queue, identity, baseline tags and boot;
 * the DOM event layer lives in analytics-events.js, which loads right after it and reads
 * the window.ccTrack / window.ccTag helpers published here.
 *
 * Coverage: window opens, virtual page views (sidebar views, settings panes, popover
 * tabs), every click / right-click / double-click / drag, control changes, first
 * keystroke per field, JS errors + unhandled rejections, and a semantic funnel layer
 * (connect, provider CRUD, exports, updates). Clarity itself records scrolls, mouse
 * traces and dwell time for replay/heatmaps.
 *
 * Privacy: only element identifiers, i18n keys and enum-ish dataset values are ever
 * used as event names — free text, input values and content-bearing dataset payloads
 * (paths, session ids, urls) never leave the app; Clarity's default masking covers
 * replay content, and password fields are never captured. Secrets and user content
 * rendered as page text (export snippet, conversations view, request inspector, …)
 * additionally carry data-clarity-mask="true" in the markup so they stay masked in
 * every Clarity masking mode.
 */
(function () {
  var PROJECT_ID = 'xij8wflxsj';
  var SURFACE = /popover\.html$/.test(location.pathname) ? 'popover' : 'main';
  var MAX = 250;

  // Command-queue stub (same shape the official tag installs) so calls made before
  // the async script lands are replayed once it arrives — and become no-ops that
  // simply keep queueing if the machine is offline.
  var w = window;
  w.clarity = w.clarity || function () { (w.clarity.q = w.clarity.q || []).push(arguments); };

  function track(name) { try { w.clarity('event', String(name).slice(0, MAX)); } catch (_) {} }
  function tag(key, value) {
    try { if (value != null && value !== '') w.clarity('set', key, String(value).slice(0, MAX)); } catch (_) {}
  }
  // Manual hooks for future call sites.
  w.ccTrack = track;
  w.ccTag = tag;

  /* ---------- identity & baseline attributes ---------- */
  var deviceId = '';
  try {
    deviceId = localStorage.getItem('ccbud-device-id') || '';
    if (!deviceId) {
      var buf = new Uint8Array(12);
      crypto.getRandomValues(buf);
      deviceId = 'ccbud-' + Array.prototype.map.call(buf, function (b) { return b.toString(16).padStart(2, '0'); }).join('');
      localStorage.setItem('ccbud-device-id', deviceId);
    }
  } catch (_) {}
  if (deviceId) { try { w.clarity('identify', deviceId); } catch (_) {} }

  tag('surface', SURFACE);
  tag('platform', navigator.platform);
  tag('locale', navigator.language);
  try { tag('theme', localStorage.getItem('ccbud-theme') || 'light'); } catch (_) {}
  try { tag('lang', localStorage.getItem('ccbud-lang') || ''); } catch (_) {}
  track('open:' + SURFACE);
  track('view:' + (SURFACE === 'popover' ? 'popover/overview' : 'providers'));

  /* ---------- boot the tag ---------- */
  function fallbackInject() {
    try {
      if (document.getElementById('clarity-script')) return;
      var s = document.createElement('script');
      s.async = true;
      s.id = 'clarity-script';
      s.src = 'https://www.clarity.ms/tag/' + PROJECT_ID;
      (document.head || document.documentElement).appendChild(s);
    } catch (_) {}
  }
  // Tauri webviews expose a bare engine UA (WKWebView has no browser token), so Clarity
  // buckets every session under browser "Other/Unknown" — and its player tries to fetch
  // our stylesheets from the app-local origin (tauri://localhost), unreachable from the
  // internet, so replays render as bare unstyled HTML. clarity-js has a desktop mode
  // keyed off an "Electron" token in the UA: it inlines each linked stylesheet's CSS
  // text into the payload (nothing to fetch at replay time) and marks the session as a
  // desktop client. Piggyback on it, carrying the real app version in the same UA so
  // the reported client is versioned instead of anonymous.
  function adoptDesktopUA(version) {
    try {
      var ua = navigator.userAgent;
      if (ua.indexOf('Electron/') !== -1) return;
      ua += ' ccbud/' + version + ' Electron/' + version;
      if (ua.indexOf('Safari/') === -1) ua += ' Safari/605.1.15'; // parseable fallback token
      var read = function () { return ua; };
      // Shadow the instance first; if that slot is unforgeable, patching the
      // prototype accessor still takes effect for reads.
      try {
        Object.defineProperty(navigator, 'userAgent', { get: read, configurable: true });
      } catch (_) {
        Object.defineProperty(Navigator.prototype, 'userAgent', { get: read, configurable: true });
      }
    } catch (_) {}
  }

  var booted = false;
  function boot(version) {
    if (booted) return;
    booted = true;
    if (version) tag('appVersion', version);
    adoptDesktopUA(version || '0.0.0');
    try {
      import('./vendor/clarity/index.js')
        .then(function (m) { (m.default || m).init(PROJECT_ID); })
        .catch(fallbackInject);
    } catch (_) { fallbackInject(); }
  }

  // The UA must be in place before clarity-js loads and reads it, so resolve the app
  // version first — time-boxed, so analytics never stalls on a broken IPC bridge.
  var versionPromise = null;
  try {
    var T = w.__TAURI__;
    if (T && T.app && T.app.getVersion) versionPromise = T.app.getVersion();
  } catch (_) {}
  if (versionPromise && typeof versionPromise.then === 'function') {
    var bootTimer = setTimeout(function () { boot(''); }, 1000);
    var settle = function (v) { clearTimeout(bootTimer); boot(typeof v === 'string' ? v : ''); };
    versionPromise.then(settle, function () { settle(''); });
  } else {
    boot('');
  }
})();
