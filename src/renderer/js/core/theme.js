/* Theme switching. The initial data-theme attribute is stamped by theme-boot.js (a tiny
   synchronous head script) before first paint; this module owns every later flip. */
import { icons } from './icons.js';

export function applyTheme(t) {
  document.documentElement.setAttribute('data-theme', t);
  try { localStorage.setItem('ccbud-theme', t); } catch (_) {}
  const dark = t === 'dark';
  const hd = document.getElementById('hljs-dark');
  const hl = document.getElementById('hljs-light');
  // Media-attribute swap instead of .disabled: both sheets stay in document.styleSheets
  // (so Clarity's desktop mode can inline them) and each flip is an attribute mutation
  // the recording captures, keeping highlight colors faithful in replay.
  if (hd) hd.media = dark ? 'all' : 'not all';
  if (hl) hl.media = dark ? 'not all' : 'all';
  // Theme-toggle icon reflects the current mode: sun in light, moon in dark.
  const tbIcon = document.querySelector('#btnTheme [data-icon]');
  if (tbIcon) { const nm = dark ? 'moon' : 'theme'; tbIcon.dataset.icon = nm; if (icons[nm]) tbIcon.innerHTML = icons[nm]; }
}

export function currentTheme() {
  return document.documentElement.getAttribute('data-theme') || 'light';
}

export function toggleTheme() {
  applyTheme(currentTheme() === 'light' ? 'dark' : 'light');
}
