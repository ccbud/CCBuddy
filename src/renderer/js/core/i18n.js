/*
 * window.I18n — renderer-side i18n runtime. The dictionary is split per language and
 * domain (src/shared/i18n/*, copied to shared/i18n/ at build time); ONLY the active
 * language (+ the `en` fallback) is loaded at startup — a fifth of the old single-file
 * dictionary on the cold-start path. All supported locales are LTR — there is NO RTL
 * handling here on purpose; adding Arabic/Hebrew later must be a deliberate change.
 */
import { loadScript } from './loader.js';

const P = () => window.ccbudI18nParts || { LANGS: ['en'], LOCALE_TAG: { en: 'en-US' }, PARTS: { en: [] } };
let lang = 'en';
const loaded = new Set();

async function ensureParts() {
  if (!window.ccbudI18nParts) await loadScript('shared/i18n/parts.js');
}
async function ensureLang(l) {
  await ensureParts();
  if (loaded.has(l) || !P().PARTS[l]) return;
  await Promise.all(P().PARTS[l].map((f) => loadScript('shared/i18n/' + f)));
  loaded.add(l);
}

function dict() {
  const langs = window.ccbudI18nLangs || {};
  return langs[lang] || langs.en || {};
}
function enDict() {
  return (window.ccbudI18nLangs || {}).en || {};
}

function fill(s, params) {
  if (!params) return s;
  return s.replace(/\{(\w+)\}/g, (_, k) => (params[k] != null ? params[k] : '{' + k + '}'));
}

function t(key, params) {
  let s = dict()[key];
  if (s == null) s = enDict()[key] != null ? enDict()[key] : key; // fallback: lang → en → key
  return fill(s, params);
}

function apply(root) {
  root = root || document;
  root.querySelectorAll('[data-i18n]').forEach((el) => { el.textContent = t(el.getAttribute('data-i18n')); });
  root.querySelectorAll('[data-i18n-placeholder]').forEach((el) => { el.setAttribute('placeholder', t(el.getAttribute('data-i18n-placeholder'))); });
  root.querySelectorAll('[data-i18n-title]').forEach((el) => {
    const v = t(el.getAttribute('data-i18n-title'));
    el.setAttribute('title', v);
    el.setAttribute('aria-label', v);
  });
}

/** Switch the UI language, loading its dictionary parts on demand. */
async function setLang(l) {
  await ensureParts();
  lang = P().LANGS.indexOf(l) >= 0 ? l : 'en';
  await Promise.all([ensureLang('en'), ensureLang(lang)]);
  try { document.documentElement.setAttribute('lang', I18n.localeTag); } catch (_) {}
  try { localStorage.setItem('ccbud-lang', lang); } catch (_) {}
}

/** The boot language: persisted choice, else the OS locale mapped onto a supported one. */
export function detectLang() {
  let l = '';
  try { l = localStorage.getItem('ccbud-lang') || ''; } catch (_) {}
  if (!l) {
    const nav = (navigator.language || 'en').toLowerCase();
    l = nav.startsWith('zh') ? ((/-(tw|hk|mo)\b/.test(nav) || nav.includes('hant')) ? 'zh-TW' : 'zh')
      : nav.startsWith('ja') ? 'ja' : nav.startsWith('ko') ? 'ko' : 'en';
  }
  return l;
}

export const I18n = {
  t,
  apply,
  setLang,
  has: (key) => dict()[key] != null || enDict()[key] != null,
  get lang() { return lang; },
  get localeTag() { return P().LOCALE_TAG[lang] || 'en-US'; },
};
// Compat global — the Rust self-check and any not-yet-migrated inline consumers read window.I18n.
window.I18n = I18n;
