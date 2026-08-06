/*
 * Lazy asset loading — the cold-start backbone. Classic scripts (UMD vendor bundles,
 * dual-mode i18n dictionary parts) are injected on demand and cached by URL, so the
 * startup path parses none of them. marked (~43KB) + highlight.js (~127KB) only load
 * when a conversation/detail actually renders markdown or code.
 */
const cache = new Map(); // src -> Promise<void>

export function loadScript(src) {
  if (cache.has(src)) return cache.get(src);
  const p = new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = src;
    s.async = false; // keep injection order for multi-part dictionaries
    s.onload = () => resolve();
    s.onerror = () => { cache.delete(src); reject(new Error('load failed: ' + src)); };
    document.head.appendChild(s);
  });
  cache.set(src, p);
  return p;
}

let vendorP = null;
/** marked + highlight.js, loaded once, on demand (conversation detail / request inspector). */
export function ensureVendor() {
  if (!vendorP) {
    vendorP = Promise.all([loadScript('vendor/marked.umd.js'), loadScript('vendor/highlight.min.js')])
      .then(() => {
        if (window.marked && window.marked.setOptions) {
          window.marked.setOptions({ gfm: true, breaks: true });
          // Defense-in-depth: never pass raw HTML from model/user text through to the DOM.
          const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
          try {
            window.marked.use({ renderer: { html: (tok) => esc(typeof tok === 'string' ? tok : (tok && tok.text) || '') } });
          } catch (_) {}
        }
      })
      .catch((e) => { vendorP = null; throw e; });
  }
  return vendorP;
}

/** Prefetch during idle time so the first click on 会话/详情 doesn't pay the load. */
export function idlePrefetch(fn, timeout) {
  const run = () => { try { fn(); } catch (_) {} };
  if ('requestIdleCallback' in window) requestIdleCallback(run, { timeout: timeout || 4000 });
  else setTimeout(run, timeout || 4000);
}
