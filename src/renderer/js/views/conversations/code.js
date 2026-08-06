/* Code block rendering: language mapping, gutters, highlight.js application, markdown docs. */
import { esc, md, truncate } from './format.js';
import { L } from './format.js';

// File extension → highlight.js language id (so code blocks get language-specific highlighting).
export const EXT_LANG = {
  js: 'javascript', mjs: 'javascript', cjs: 'javascript', jsx: 'javascript', ts: 'typescript', tsx: 'typescript',
  py: 'python', rb: 'ruby', go: 'go', rs: 'rust', java: 'java', kt: 'kotlin', scala: 'scala', swift: 'swift',
  c: 'c', h: 'c', cpp: 'cpp', cc: 'cpp', cxx: 'cpp', hpp: 'cpp', cs: 'csharp', m: 'objectivec', mm: 'objectivec',
  php: 'php', pl: 'perl', lua: 'lua', r: 'r', dart: 'dart', ex: 'elixir', exs: 'elixir', erl: 'erlang', clj: 'clojure',
  sh: 'bash', bash: 'bash', zsh: 'bash', fish: 'bash', ps1: 'powershell',
  json: 'json', jsonc: 'json', yaml: 'yaml', yml: 'yaml', toml: 'ini', ini: 'ini', conf: 'ini', env: 'ini',
  html: 'xml', htm: 'xml', xml: 'xml', svg: 'xml', vue: 'xml', xhtml: 'xml',
  css: 'css', scss: 'scss', sass: 'scss', less: 'less', styl: 'stylus',
  md: 'markdown', markdown: 'markdown', sql: 'sql', graphql: 'graphql', gql: 'graphql', proto: 'protobuf',
  tf: 'terraform', tsv: 'plaintext', csv: 'plaintext',
};

export function langFromPath(p) {
  if (!p) return '';
  const base = String(p).split(/[\\/]/).pop().toLowerCase();
  if (base === 'dockerfile') return 'dockerfile';
  if (base === 'makefile' || base === 'gnumakefile') return 'makefile';
  const dot = base.lastIndexOf('.');
  return (dot >= 0 ? EXT_LANG[base.slice(dot + 1)] : '') || '';
}

// Strip `cat -n` prefixes ("␠␠␠12\t…", as Claude Code's Read returns) so we render our own gutter.
export function stripCatN(text) {
  return /^\s*\d+\t/.test(text) ? text.replace(/^\s*\d+\t/gm, '') : text;
}

// A styled code block. lang='' → plain (no syntax highlight, no gutter). highlight()+gutter are
// applied after insertion (see highlight()). Shared by tool cards and message rendering.
export function codeBlock(text, lang) {
  const cls = lang ? 'language-' + esc(lang) : 'nohljs';
  return `<pre class="cb${lang ? '' : ' cb-plain'}"><code class="${cls}">${esc(text)}</code></pre>`;
}
export function codePre(text, lang) { return codeBlock(truncate(text, 12000), lang || ''); }

// Markdown file: rendered preview (default) ↔ highlighted source, toggled by tabs. marked renders the
// preview; highlight() lights up code blocks inside both panes (source is highlighted even while hidden).
export function mdDoc(text) {
  return '<div class="md-doc">'
    + `<div class="md-tabs"><button type="button" class="md-tab active" data-md-tab="preview">${esc(L('conv.mdPreview'))}</button><button type="button" class="md-tab" data-md-tab="source">${esc(L('conv.mdSource'))}</button></div>`
    + `<div class="md-pane md-preview blk-text">${md(text)}</div>`
    + `<div class="md-pane md-source hidden">${codeBlock(text, 'markdown')}</div>`
    + '</div>';
}
export const isMdPath = (p) => langFromPath(p) === 'markdown';

// Add a GitHub-style line-number gutter to a code block (after highlighting, so token spans are
// intact). Skipped for plain blocks (terminal/JSON output) and once already applied.
function addGutter(pre) {
  if (!pre || pre.dataset.gutter || pre.classList.contains('cb-plain')) return;
  const code = pre.querySelector('code');
  if (!code) return;
  let n = (code.textContent || '').replace(/\n+$/, '').split('\n').length;
  if (n < 1) n = 1;
  let s = '';
  for (let i = 1; i <= n; i++) s += i + (i < n ? '\n' : '');
  const g = document.createElement('span');
  g.className = 'cb-gutter';
  g.setAttribute('aria-hidden', 'true');
  g.textContent = s;
  pre.insertBefore(g, code);
  pre.classList.add('cb-has-gutter');
  pre.dataset.gutter = '1';
}

export function highlight(root) {
  if (!window.hljs) return;
  root.querySelectorAll('pre code').forEach((code) => {
    if (code.classList.contains('nohljs')) return; // plain output (terminal / JSON) — no highlight, no gutter
    if (!code.dataset.highlighted) { try { window.hljs.highlightElement(code); } catch (_) {} }
    addGutter(code.parentElement); // GitHub-style line-number gutter
  });
}
