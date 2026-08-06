/* 对话 view formatting primitives — text escaping, sizes, times, source labels. */
import { I18n } from '../../core/i18n.js';

export const L = (k, p) => I18n.t(k, p);
export const localeTag = () => I18n.localeTag;

export function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// Middle-ellipsis a long path so the start (/Users…) and meaningful tail (…/work) both stay visible.
export const midEllip = (s, max) => {
  s = String(s == null ? '' : s);
  if (s.length <= max) return s;
  const k = max - 1, h = Math.ceil(k / 2), t = Math.floor(k / 2);
  return s.slice(0, h) + '…' + s.slice(s.length - t);
};

// Non-Claude session sources (meta.source): list-row chip label + assistant display name.
// Claude ('disk') deliberately has no chip — it's the app's home turf.
export const SOURCE_NAMES = { codex: 'Codex', grok: 'Grok', copilot: 'Copilot', antigravity: 'Antigravity', qoder: 'Qoder' };
export const isForeignSource = (s) => !!SOURCE_NAMES[s];

// conv.permissionDenied walks the user through macOS System Settings — that guidance only fits
// macOS (the helper-backed Qoder read path); other platforms show the generic read-failure copy.
const IS_MAC = /mac/i.test(navigator.platform || '');
export const readErrorKey = (kind) => (kind === 'permissionDenied' && IS_MAC
  ? 'conv.permissionDenied'
  : kind === 'notFound' ? 'conv.notFound' : 'conv.readFailed');

export function fmtTok(n) {
  n = n || 0;
  if (n < 1000) return String(n);
  if (n < 1e6) return (n / 1e3).toFixed(n < 1e4 ? 1 : 0).replace(/\.0$/, '') + 'K';
  return (n / 1e6).toFixed(1).replace(/\.0$/, '') + 'M';
}

// Qoder Credits are billing units, not tokens or currency. Keep their fractional precision for
// individual turns, while abbreviating only large conversation totals.
export function fmtCredits(n) {
  n = Number(n);
  if (!Number.isFinite(n)) return '—';
  const trim = (s) => s.replace(/(\.\d*?[1-9])0+$|\.0+$/, '$1');
  if (Math.abs(n) >= 1000) return trim((n / 1000).toFixed(Math.abs(n) < 10000 ? 1 : 0)) + 'K';
  if (Math.abs(n) >= 100) return trim(n.toFixed(1));
  if (Math.abs(n) >= 1) return trim(n.toFixed(2));
  return trim(n.toFixed(3));
}

export function truncate(s, n) {
  s = String(s == null ? '' : s);
  return s.length > n ? s.slice(0, n) + L('conv.charsMore', { n: s.length - n }) : s;
}

// Size shown in KB until it's large enough to read better as MB / GB.
export function fmtSizeKB(kb) {
  kb = kb || 0;
  if (kb < 1024) return kb + ' KB';
  if (kb < 1024 * 1024) return (kb / 1024).toFixed(1).replace(/\.0$/, '') + ' MB';
  return (kb / 1024 / 1024).toFixed(2).replace(/\.0+$/, '') + ' GB';
}

export function md(text) {
  try { return window.marked ? window.marked.parse(String(text || '')) : esc(text); } catch (_) { return esc(text); }
}

export function normContent(c) {
  if (typeof c === 'string') return c ? [{ type: 'text', text: c }] : [];
  return Array.isArray(c) ? c : [];
}

export function projName(cwd) { return cwd ? cwd.split('/').filter(Boolean).pop() : null; }

export function relTime(ts) {
  if (!ts) return '';
  const d = Date.now() - ts;
  if (d < 60000) return L('time.justNow');
  if (d < 3600000) return L('time.minutesAgo', { n: Math.floor(d / 60000) });
  if (d < 86400000) return L('time.hoursAgo', { n: Math.floor(d / 3600000) });
  if (d < 7 * 86400000) return L('time.daysAgo', { n: Math.floor(d / 86400000) });
  return new Date(ts).toLocaleDateString(localeTag());
}

export function escapeRegExp(str) { return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

export function shortPath(p) {
  if (!p) return '';
  const s = String(p).split('/');
  return s.length > 3 ? '…/' + s.slice(-2).join('/') : p;
}

export function resultSummary(txt) {
  const b = txt ? txt.length : 0;
  if (!b) return '';
  return b < 1024 ? b + ' B' : (b / 1024).toFixed(1) + ' KB';
}

export function contentToText(c) {
  if (typeof c === 'string') return c;
  if (Array.isArray(c)) return c.map((x) => (x && (x.text != null ? x.text : (typeof x.content === 'string' ? x.content : ''))) || '').join(' ');
  return '';
}

/** Escape a tool_use id for use inside a [data-sub="…"] attribute selector (ids may contain ':'). */
export function cssAttr(s) { return String(s).replace(/(["\\])/g, '\\$1'); }
