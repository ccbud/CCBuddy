/* Tiny DOM + formatting primitives shared by every view module. */
import { icons } from './icons.js';

export const $ = (id) => document.getElementById(id);

export function escapeHtml(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

export function show(el, on) { if (el) el.classList.toggle('hidden', !on); }

/** Fill every [data-icon] slot under root from the shared SVG icon set. */
export function injectIcons(root) {
  (root || document).querySelectorAll('[data-icon]').forEach((el) => {
    const name = el.dataset.icon;
    if (icons[name]) el.innerHTML = icons[name];
  });
}

// Unified 24-hour clock (HH:MM:SS) everywhere — language-independent, so the monitor stays
// consistent across language switches and the timestamp never wraps with a 12-hour "PM" suffix.
export function fmtTime(d) {
  const t = d == null ? new Date() : (d instanceof Date ? d : new Date(d));
  const p = (n) => String(n).padStart(2, '0');
  return `${p(t.getHours())}:${p(t.getMinutes())}:${p(t.getSeconds())}`;
}

export function fmtNum(n) {
  n = n || 0;
  if (n < 1000) return String(n);
  if (n < 1e6) return (n / 1e3).toFixed(n < 1e4 ? 1 : 0).replace(/\.0$/, '') + 'K';
  if (n < 1e9) return (n / 1e6).toFixed(n < 1e7 ? 1 : 0).replace(/\.0$/, '') + 'M';
  return (n / 1e9).toFixed(1).replace(/\.0$/, '') + 'B';
}

export function fmtBytes(n) {
  n = n || 0;
  if (n < 1024) return n + ' B';
  if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
  return (n / 1048576).toFixed(2) + ' MB';
}

export function hashHue(s) {
  let h = 0;
  for (let i = 0; i < (s || '').length; i++) h = (h * 31 + s.charCodeAt(i)) % 360;
  return h;
}

// Smooth brand-tinted area sparkline; stretches to its container via preserveAspectRatio="none".
export function sparkSVG(vals) {
  const W = 300, H = 46, pad = 4;
  const data = (vals && vals.length) ? vals : [0, 0];
  const n = data.length;
  const max = Math.max(1, ...data);
  const xs = (i) => (n === 1 ? W / 2 : pad + (i / (n - 1)) * (W - 2 * pad));
  const ys = (v) => H - pad - (v / max) * (H - 2 * pad - 2);
  const pts = data.map((v, i) => [xs(i), ys(v)]);
  let line = `M ${pts[0][0].toFixed(1)} ${pts[0][1].toFixed(1)}`;
  for (let i = 0; i < pts.length - 1; i++) {
    const p0 = pts[i - 1] || pts[i], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2] || p2;
    const c1x = p1[0] + (p2[0] - p0[0]) / 6, c1y = p1[1] + (p2[1] - p0[1]) / 6;
    const c2x = p2[0] - (p3[0] - p1[0]) / 6, c2y = p2[1] - (p3[1] - p1[1]) / 6;
    line += ` C ${c1x.toFixed(1)} ${c1y.toFixed(1)}, ${c2x.toFixed(1)} ${c2y.toFixed(1)}, ${p2[0].toFixed(1)} ${p2[1].toFixed(1)}`;
  }
  const area = `${line} L ${pts[n - 1][0].toFixed(1)} ${H - pad} L ${pts[0][0].toFixed(1)} ${H - pad} Z`;
  return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" style="width:100%;height:100%;display:block"><defs><linearGradient id="hsg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="var(--brand)" stop-opacity="0.30"/><stop offset="1" stop-color="var(--brand)" stop-opacity="0"/></linearGradient></defs><path d="${area}" fill="url(#hsg)"/><path d="${line}" fill="none" stroke="var(--brand)" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"/></svg>`;
}

/** Copy-with-feedback for small "复制" buttons (restores the original label after 1.5s). */
export function copyFeedback(btn, text, copiedLabel, copyFn) {
  const orig = btn.dataset.copyOrig || (btn.dataset.copyOrig = btn.textContent);
  copyFn(text);
  btn.textContent = copiedLabel;
  clearTimeout(btn._t);
  btn._t = setTimeout(() => (btn.textContent = orig), 1500);
}
