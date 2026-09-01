import { escapeHtml } from '../../core/dom.js';
import { I18n } from '../../core/i18n.js';
import { canUpdate, formatDate, formatSize, normalizeSkill, sourceUnavailable, syncState } from './state.js';
import { pageState } from './layout.js';

const e = escapeHtml;
let requestToken = 0;

function buildTree(files) {
  const root = [];
  (files || []).forEach((entry) => {
    const file = typeof entry === 'string' ? { path: entry, size: 0 } : entry;
    const parts = String(file.path || '').split('/').filter(Boolean); let nodes = root;
    parts.forEach((name, index) => {
      const path = parts.slice(0, index + 1).join('/'), dir = index < parts.length - 1;
      let node = nodes.find((item) => item.name === name && item.dir === dir);
      if (!node) { node = { name, path, dir, size: Number(file.size || 0), children: [] }; nodes.push(node); }
      nodes = node.children;
    });
  });
  const sort = (nodes) => { nodes.sort((a, b) => a.dir !== b.dir ? (a.dir ? -1 : 1) : (a.name.toLowerCase() === 'skill.md' ? -1 : a.name.localeCompare(b.name))); nodes.forEach((node) => sort(node.children)); };
  sort(root); return root;
}

function treeHtml(nodes, active, depth = 0) {
  return nodes.map((node) => node.dir
    ? `<details class="skills-tree-dir" open><summary class="cursor-pointer py-1 text-[11px] text-muted" style="padding-left:${depth * 12}px">▾ <span data-icon="folder" class="inline-flex align-middle"></span> ${e(node.name)}</summary>${treeHtml(node.children, active, depth + 1)}</details>`
    : `<button data-file="${e(node.path)}" type="button" aria-pressed="${active === node.path}" class="skills-tree-file w-full flex items-center gap-1.5 py-1.5 pr-2 rounded text-left text-[10.5px] ${active === node.path ? 'active bg-brand-soft text-brand' : 'text-muted hover:bg-chip-bg'}" style="padding-left:${12 + depth * 12}px"><span class="truncate flex-1">${e(node.name)}</span><small class="text-[8.5px] text-caption">${e(formatSize(node.size))}</small></button>`).join('');
}

function targetPanel(skill, state) {
  const active = new Set(skill.targets.map((target) => target.key));
  const known = new Map(state.tools.map((tool) => [tool.key, tool]));
  skill.targets.forEach((target) => { if (!known.has(target.key)) known.set(target.key, { key: target.key, label: target.key, detected: false, enabled: false }); });
  const tools = [...known.values()].filter((tool) => active.has(tool.key) || (tool.detected && tool.enabled));
  const available = tools.filter((tool) => tool.detected && tool.enabled);
  const canSync = available.length > 0 && !sourceUnavailable(skill);
  const choices = tools.map((tool) => {
    const ready = tool.detected && tool.enabled, checked = active.size ? active.has(tool.key) : ready;
    return `<label class="flex items-center gap-2 border border-border-custom rounded-lg px-2.5 py-2 text-[10.5px] ${ready ? '' : 'opacity-70'}"><input name="detailTargets" type="checkbox" autocomplete="off" data-target-available="${ready}" value="${e(tool.key)}" ${checked ? 'checked' : ''}><span>${e(tool.label)}${ready ? '' : ` <small class="text-caption" data-i18n="skills.tools.missing">未检测</small>`}</span></label>`;
  }).join('');
  return `<section class="skills-detail-sync border border-border-custom rounded-xl p-4"><h3 class="text-[12.5px] font-semibold" data-i18n="skills.detail.syncTitle">同步目标</h3><fieldset class="mt-3"><legend class="text-[10.5px] text-caption mb-2" data-i18n="skills.detail.targets">目标工具</legend><div class="flex flex-wrap gap-2">${choices || `<span class="text-[10.5px] text-caption" data-i18n="skills.library.noTargets">未检测到可用工具</span>`}</div></fieldset><label class="flex items-center gap-2 mt-3 text-[10.5px] text-caption"><span data-i18n="skills.detail.syncMode">同步模式</span><select id="detailSyncMode" name="syncMode" autocomplete="off" ${canSync ? '' : 'disabled'} class="bg-bg-input border border-border-custom rounded-md px-2 py-1.5 text-fg"><option value="auto" data-i18n="skills.detail.mode.auto">自动</option><option value="symlink" data-i18n="skills.detail.mode.symlink">符号链接</option><option value="copy" data-i18n="skills.detail.mode.copy">复制</option></select></label><div class="flex gap-2 mt-3"><button data-action="detail-sync" type="button" ${canSync ? '' : 'disabled'} class="bg-brand text-white rounded-md px-3 py-1.5 text-[10.5px] hover:bg-brand-2 disabled:opacity-40" data-i18n="skills.detail.applySync">应用同步</button><button data-action="detail-unsync" type="button" ${active.size ? '' : 'disabled'} class="border border-border-custom rounded-md px-3 py-1.5 text-[10.5px] hover:bg-chip-bg disabled:opacity-40" data-i18n="skills.detail.removeSync">取消同步</button></div></section>`;
}

function contentPanel(state) {
  const skill = state.detail, files = skill.files || [];
  const loading = Boolean(state.detailFile) && state.detailContent === null;
  const content = !state.detailFile ? I18n.t('skills.detail.selectFile') : loading ? I18n.t('skills.loading') : String(state.detailContent);
  return `<div class="skills-file-browser skills-detail-files mt-4 grid grid-cols-[230px_minmax(0,1fr)] min-h-[390px] border border-border-custom rounded-xl overflow-hidden"><aside class="skills-file-tree border-r border-border-custom bg-bg-input/30"><h3 class="px-3 py-2.5 border-b border-border-custom text-[10.5px] font-semibold text-caption" data-i18n="skills.detail.files">文件</h3><div class="py-1.5 max-h-[520px] overflow-y-auto">${files.length ? treeHtml(buildTree(files), state.detailFile) : `<p class="p-3 text-[10.5px] text-caption" data-i18n="skills.detail.emptyFiles">没有可预览文件</p>`}</div></aside><section class="min-w-0 flex flex-col"><header class="flex items-center gap-2 px-3 py-2.5 border-b border-border-custom"><strong id="skillsFileName" class="truncate text-[10.5px] font-mono" translate="no">${e(state.detailFile || I18n.t('skills.detail.selectFile'))}</strong><button data-action="copy-path" type="button" ${state.detailFile ? '' : 'disabled'} class="ml-auto text-[10px] text-brand hover:underline" data-i18n="skills.detail.copyPath">复制路径</button></header><pre id="skillsFileContent" class="skills-file-content flex-1 m-0 p-4 overflow-auto whitespace-pre-wrap break-words text-[11.5px] leading-[1.65] font-mono bg-bg-input/20" role="status" aria-live="polite" aria-atomic="true" aria-busy="${loading}" translate="no">${e(content)}</pre></section></div>`;
}

function updateFilePanel(host, state) {
  host.querySelectorAll('[data-file]').forEach((button) => {
    const active = button.dataset.file === state.detailFile;
    button.setAttribute('aria-pressed', String(active));
    button.classList.toggle('active', active); button.classList.toggle('bg-brand-soft', active);
    button.classList.toggle('text-brand', active); button.classList.toggle('text-muted', !active);
  });
  const name = host.querySelector('#skillsFileName'), content = host.querySelector('#skillsFileContent');
  const copy = host.querySelector('[data-action="copy-path"]'), loading = Boolean(state.detailFile) && state.detailContent === null;
  if (name) name.textContent = state.detailFile || I18n.t('skills.detail.selectFile');
  if (copy) copy.disabled = !state.detailFile;
  if (content) {
    content.setAttribute('aria-busy', String(loading));
    content.textContent = !state.detailFile ? I18n.t('skills.detail.selectFile') : loading ? I18n.t('skills.loading') : String(state.detailContent);
  }
}

function draw(host, ctx) {
  const skill = ctx.state.detail, status = syncState(skill), source = skill.sourceRef || skill.path;
  const update = canUpdate(skill) ? `<button data-action="update" type="button" class="border border-border-custom rounded-md px-3 py-1.5 text-[11px] hover:bg-chip-bg" data-i18n="skills.library.update">更新</button>` : '';
  host.innerHTML = `<header class="skills-detail-head flex items-start gap-3 mb-4"><button data-action="back" type="button" class="w-8 h-8 shrink-0 rounded-lg border border-border-custom flex items-center justify-center hover:bg-chip-bg" aria-label="${e(I18n.t('skills.detail.back'))}"><span data-icon="chevronLeft"></span></button><span class="w-10 h-10 rounded-xl bg-brand-soft text-brand flex items-center justify-center" data-icon="${skill.sourceType.includes('git') ? 'download' : 'folder'}"></span><div class="min-w-0 flex-1"><h2 class="text-[18px] font-semibold truncate">${e(skill.name)}</h2><p class="text-[11.5px] text-caption mt-0.5">${e(skill.description || I18n.t('skills.library.descriptionEmpty'))}</p></div><button data-action="edit-tags" type="button" class="border border-border-custom rounded-md px-3 py-1.5 text-[11px] hover:bg-chip-bg" data-i18n="skills.library.editTags">编辑标签</button>${update}<button data-action="delete" type="button" class="border border-red/30 text-red rounded-md px-3 py-1.5 text-[11px] hover:bg-red-soft" data-i18n="skills.library.delete">删除</button></header>
  <div class="grid grid-cols-[minmax(0,1fr)_310px] gap-4"><section class="skills-detail-meta border border-border-custom rounded-xl p-4"><dl class="grid grid-cols-[92px_1fr] gap-y-3 text-[11px]"><dt class="text-caption" data-i18n="skills.detail.source">来源</dt><dd class="font-mono truncate" title="${e(source)}" translate="no">${e(source)}</dd><dt class="text-caption" data-i18n="skills.detail.location">位置</dt><dd class="font-mono truncate" title="${e(skill.path)}" translate="no">${e(skill.path)}</dd><dt class="text-caption" data-i18n="skills.detail.status">状态</dt><dd><span class="rounded-full bg-chip-bg px-2 py-1">${e(I18n.t(`skills.library.status.${status}`))}</span></dd><dt class="text-caption" data-i18n="skills.detail.updated">更新时间</dt><dd>${e(formatDate(skill.updatedAt))}</dd><dt class="text-caption" data-i18n="skills.library.tags">标签</dt><dd class="flex flex-wrap gap-1">${skill.tags.length ? skill.tags.map((tag) => `<span class="rounded-full bg-brand-soft text-brand px-2 py-0.5">${e(tag)}</span>`).join('') : `<span class="text-caption" data-i18n="skills.library.noTags">无标签</span>`}</dd></dl></section>${targetPanel(skill, ctx.state)}</div>${contentPanel(ctx.state)}`;
  ctx.localize(host); host.onclick = (event) => onClick(event, host, ctx); ctx.focusHeading();
}

async function loadDetail(host, ctx) {
  const token = ++requestToken, id = ctx.state.detailId, route = ctx.routeStamp();
  host.innerHTML = pageState('loading'); ctx.localize(host);
  try {
    const raw = await ctx.api.detail(id);
    if (token !== requestToken || !ctx.isCurrentDetail(id, route)) return;
    ctx.state.detail = { ...normalizeSkill(raw), files: Array.isArray(raw?.files) ? raw.files : [] };
    const first = ctx.state.detail.files.find((file) => /(^|\/)skill\.md$/i.test(file.path || file)) || ctx.state.detail.files[0];
    ctx.state.detailFile = first ? String(first.path || first) : ''; ctx.state.detailContent = null;
    draw(host, ctx); if (ctx.state.detailFile) loadFile(host, ctx, ctx.state.detailFile);
  } catch (error) {
    if (token !== requestToken || !ctx.isCurrentDetail(id, route)) return;
    host.innerHTML = pageState('error', error && error.message || error); ctx.localize(host);
    host.onclick = (event) => { if (event.target.closest('[data-action="retry"]')) { ctx.state.detail = null; loadDetail(host, ctx); } };
  }
}

async function loadFile(host, ctx, path) {
  const token = ++requestToken, id = ctx.state.detailId, route = ctx.routeStamp();
  ctx.state.detailFile = path; ctx.state.detailContent = null; updateFilePanel(host, ctx.state);
  try {
    const content = await ctx.api.readFile(id, path);
    if (token !== requestToken || !ctx.isCurrentDetail(id, route)) return;
    ctx.state.detailContent = String(content);
  } catch (error) {
    if (token !== requestToken || !ctx.isCurrentDetail(id, route)) return;
    ctx.state.detailContent = I18n.t('skills.detail.readError') + `\n${error && error.message || error}`;
  }
  updateFilePanel(host, ctx.state);
}

export function render(host, ctx) {
  if (!ctx.state.detail || ctx.state.detail.id !== ctx.state.detailId) loadDetail(host, ctx); else draw(host, ctx);
}

function selectedTargets(host, availableOnly = false) {
  const suffix = availableOnly ? '[data-target-available="true"]' : '';
  return [...host.querySelectorAll(`[name="detailTargets"]:checked${suffix}`)].map((box) => box.value);
}

function onClick(event, host, ctx) {
  const file = event.target.closest('[data-file]'); if (file) return loadFile(host, ctx, file.dataset.file);
  const button = event.target.closest('[data-action]'); if (!button) return;
  const id = ctx.state.detailId, action = button.dataset.action;
  if (action === 'back') return ctx.navigate('library');
  if (action === 'retry') { ctx.state.detail = null; return loadDetail(host, ctx); }
  if (action === 'edit-tags') return ctx.editTags(ctx.state.detail);
  if (action === 'update') return ctx.updateSkills([id]);
  if (action === 'delete') return ctx.deleteSkills([id]);
  if (action === 'detail-sync') return ctx.syncSkills([id], selectedTargets(host, true), host.querySelector('#detailSyncMode').value);
  if (action === 'detail-unsync') return ctx.unsyncSkills([id], selectedTargets(host));
  if (action === 'copy-path' && ctx.state.detailFile) navigator.clipboard.writeText(ctx.state.detailFile).then(() => ctx.toast(I18n.t('skills.toast.done'), 'ok')).catch(() => ctx.toast(I18n.t('skills.toast.failed'), 'err'));
}
