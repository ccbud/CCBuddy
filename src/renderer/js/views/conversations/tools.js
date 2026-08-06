/* Tool-call cards: per-tool icon/label/target/body + the result disclosure. */
import { esc, truncate, shortPath, resultSummary, L } from './format.js';
import { codeBlock, langFromPath, stripCatN, mdDoc, isMdPath } from './code.js';
import { inlineSubagentBlock } from './subagents.js';

const PRE = 'pre bg-[#0c0e12] border border-white/7 rounded-[7px] p-2.5 overflow-x-auto font-mono text-[11px] leading-[1.48] text-[#e8edf4] whitespace-pre-wrap break-all';
const TOOL_CLS = { Bash: 'exec', Script: 'exec', Read: 'read', Edit: 'write', MultiEdit: 'write', Write: 'write', ApplyPatch: 'write', Grep: 'search', Glob: 'search', TodoWrite: 'todo', Task: 'task', WebSearch: 'net', WebFetch: 'net' };

export function toolResultText(b) {
  const c = b && b.content;
  if (typeof c === 'string') return c;
  // image blocks render separately (renderToolCard) — stringifying them would dump base64
  if (Array.isArray(c)) return c.filter((x) => !(x && x.type === 'image')).map((x) => (x && x.type === 'text' ? x.text : (x && x.text) || JSON.stringify(x))).join('\n');
  return c == null ? '' : JSON.stringify(c);
}

function diff(oldS, newS) {
  const o = String(oldS || '').split('\n');
  const n = String(newS || '').split('\n');
  return '<div class="diff font-mono text-[10.5px] rounded-[5px] overflow-hidden border border-border-custom mt-0.75">' + o.map((l) => `<div class="d-del bg-red-soft text-red py-0.5 px-1.75 whitespace-pre-wrap">- ${esc(l)}</div>`).join('') + n.map((l) => `<div class="d-add bg-green-soft text-green py-0.5 px-1.75 whitespace-pre-wrap">+ ${esc(l)}</div>`).join('') + '</div>';
}

function todos(list) {
  return '<div class="todos flex flex-col gap-0.5 mt-0.75">' + (list || []).map((t) => {
    const m = t.status === 'completed' ? '☑' : t.status === 'in_progress' ? '◐' : '☐';
    return `<div class="todo text-[11.5px] flex gap-1.75 [&.completed]:text-muted [&.completed]:line-through [&.in_progress]:text-primary [&.in_progress]:font-semibold ${esc(t.status || '')}"><span class="todo-box w-3.25">${m}</span>${esc(t.content || t.activeForm || '')}</div>`;
  }).join('') + '</div>';
}

// Codex apply_patch envelope: "*** Update File: x" headers → the card's target (file, or "N files").
function patchTarget(patch) {
  const files = [];
  String(patch || '').split('\n').forEach((l) => {
    const m = /^\*\*\*\s+(?:Add|Update|Delete)\s+File:\s+(.+)$/.exec(l.trim());
    if (m) files.push(m[1].trim());
  });
  if (!files.length) return '';
  return files.length === 1 ? shortPath(files[0]) : L('conv.patchFiles', { n: files.length });
}

/** Per-tool head/body shaping. Returns { icon, label, target, bodyInput, cls }. */
function shapeTool(name, input) {
  const cls = /^mcp__/.test(name) ? 'mcp' : (TOOL_CLS[name] || 'default');
  let icon = '🔧', label = name, target = '', bodyInput = '';
  if (name === 'Bash') { icon = '⌘'; label = 'Bash'; target = input.description || ''; bodyInput = codeBlock(input.command || '', 'bash'); }
  // Codex code-mode orchestration scripts (multi-call / write_stdin / custom JS) — the plain
  // shell-run shape is already mapped to Bash by the backend (codex map_exec_script).
  else if (name === 'Script') { icon = '📜'; label = 'Script'; bodyInput = codeBlock(truncate(input.code || '', 12000), 'javascript'); }
  else if (name === 'Read') { icon = '📖'; label = 'Read'; target = shortPath(input.file_path); }
  else if (name === 'Edit') { icon = '✏️'; label = 'Edit'; target = shortPath(input.file_path); bodyInput = diff(input.old_string, input.new_string); }
  else if (name === 'MultiEdit') { icon = '✏️'; label = 'MultiEdit'; target = shortPath(input.file_path); bodyInput = Array.isArray(input.edits) && input.edits.length ? input.edits.map((e) => diff(e.old_string, e.new_string)).join('') : `<div class="text-muted text-[11px]">${esc(L('conv.noEdits'))}</div>`; }
  else if (name === 'Write') { icon = '📝'; label = 'Write'; target = shortPath(input.file_path); const c = truncate(input.content || '', 12000); bodyInput = isMdPath(input.file_path) ? mdDoc(c) : codeBlock(c, langFromPath(input.file_path)); }
  else if (name === 'ApplyPatch') { icon = '✏️'; label = 'ApplyPatch'; target = patchTarget(input.patch); bodyInput = codeBlock(truncate(input.patch || '', 12000), 'diff'); }
  else if (name === 'Grep') { icon = '🔎'; label = 'Grep'; target = input.pattern || ''; if (input.path) bodyInput = `<div class="text-muted text-[11px]">in ${esc(input.path)}</div>`; }
  else if (name === 'Glob') { icon = '🔎'; label = 'Glob'; target = input.pattern || ''; }
  else if (name === 'TodoWrite') { icon = '✅'; label = 'Todos'; bodyInput = todos(input.todos); }
  else if (name === 'Task') { icon = '🤖'; label = 'Task'; target = '→ ' + (input.subagent_type || 'agent'); bodyInput = (input.description ? `<div class="text-muted text-[11px] mb-1">${esc(input.description)}</div>` : '') + (input.prompt ? `<pre class="${PRE}">${esc(truncate(input.prompt, 4000))}</pre>` : ''); }
  else if (name === 'WebSearch') { icon = '🌐'; label = 'WebSearch'; target = input.query || ''; }
  else if (name === 'WebFetch') { icon = '🌐'; label = 'WebFetch'; target = input.url || ''; }
  else if (/^mcp__/.test(name)) { icon = '🧩'; label = 'MCP · ' + name.replace(/^mcp__/, ''); bodyInput = Object.keys(input).length ? codeBlock(JSON.stringify(input, null, 2), 'json') : ''; }
  else { bodyInput = Object.keys(input).length ? codeBlock(JSON.stringify(input, null, 2), 'json') : ''; }
  return { icon, label, target, bodyInput, cls };
}

/** The result disclosure under a tool call (or the "no result yet" pending line). */
function resultBlock(name, input, resBlock) {
  if (!resBlock) return `<div class="tool-pending py-1.25 px-2.5 text-[10.5px] text-muted border-t border-border-custom">— ${esc(L('conv.noResult'))}</div>`;
  const isErr = !!resBlock.is_error;
  const txt = toolResultText(resBlock);
  const size = resultSummary(txt);
  // Read shows the file's content → highlight by extension (+ our own gutter, stripping cat -n);
  // other results stay plain text. An empty text renders nothing (no bare empty code box).
  const resBody = !txt ? '' : name === 'Read'
    ? (isMdPath(input.file_path)
      ? mdDoc(stripCatN(truncate(txt, 8000)))
      : codeBlock(stripCatN(truncate(txt, 8000)), langFromPath(input.file_path)))
    : name === 'Bash'
      ? codeBlock(truncate(txt, 8000), 'bash')
      : codeBlock(truncate(txt, 8000), '');
  // Screenshot-carrying results (codex code-mode / grok): image blocks render as images.
  const resImgs = Array.isArray(resBlock.content)
    ? resBlock.content
      .filter((x) => x && x.type === 'image' && x.source && x.source.data)
      .map((x) => `<img class="msg-img max-w-[300px] rounded-lg border border-border-custom my-1" src="data:${esc(x.source.media_type || 'image/png')};base64,${esc(x.source.data)}" />`)
      .join('')
    : '';
  return `<details class="tool-result border-t border-border-custom ${isErr ? 'err' : ''}"${isErr ? ' open' : ''}><summary class="cursor-pointer py-1.25 px-2.5 text-[10.5px] font-semibold ${isErr ? 'text-red' : 'text-green'} outline-none list-none [&::-webkit-details-marker]:hidden flex items-center gap-1.5"><span>${isErr ? '✗ ' + esc(L('conv.errResult')) : '✓ ' + esc(L('conv.result'))}</span>${size ? `<span class="tool-res-size">${esc(size)}</span>` : ''}</summary><div class="tool-result-body mx-2.5 mb-2">${resBody}${resImgs}</div></details>`;
}

export function renderToolCard(tu, resBlock) {
  const name = tu.name || 'tool';
  const input = (tu.input && typeof tu.input === 'object') ? tu.input : {};
  const { icon, label, target, bodyInput, cls } = shapeTool(name, input);
  const resHtml = resultBlock(name, input, resBlock);
  // If this call spawned a subagent (Task / Agent / Workflow / …, matched by tool_use id), nest its
  // transcript right under the call so it's read in the context that produced it.
  const subHtml = inlineSubagentBlock(tu.id);
  return `<div class="tool-card tool-${cls} border border-border-strong rounded-[8px] my-2 overflow-hidden bg-bg-elev shadow-card"><div class="tool-head flex items-center gap-1.75 py-1.75 px-2.5 bg-chip-bg border-b border-border-custom text-[11px] font-semibold text-fg"><span class="tool-icon text-[11px]">${icon}</span><span class="tool-name font-mono font-semibold shrink-0">${esc(label)}</span>${target ? `<span class="tool-target font-mono text-[10.5px] text-muted font-normal truncate min-w-0">${esc(target)}</span>` : ''}</div>${bodyInput ? `<div class="tool-input p-2 px-2.5">${bodyInput}</div>` : ''}${resHtml}${subHtml}</div>`;
}
