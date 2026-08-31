import { escapeHtml } from '../../core/dom.js';
import { I18n } from '../../core/i18n.js';

const e = escapeHtml;

function tabs(state) {
  return `<div class="skills-add-tabs flex gap-6 border-b border-border-custom mb-5" role="tablist">
    <button id="skillsAddTabGit" data-add-tab="git" role="tab" aria-controls="skillsGitForm" aria-selected="${state.add.tab === 'git'}" tabindex="${state.add.tab === 'git' ? '0' : '-1'}" type="button" class="pb-2.5 text-[12.5px] ${state.add.tab === 'git' ? 'text-fg font-semibold border-b-2 border-brand' : 'text-caption'}" data-i18n="skills.add.git">Git 仓库</button>
    <button id="skillsAddTabLocal" data-add-tab="local" role="tab" aria-controls="skillsLocalForm" aria-selected="${state.add.tab === 'local'}" tabindex="${state.add.tab === 'local' ? '0' : '-1'}" type="button" class="pb-2.5 text-[12.5px] ${state.add.tab === 'local' ? 'text-fg font-semibold border-b-2 border-brand' : 'text-caption'}" data-i18n="skills.add.local">本地文件夹</button>
  </div>`;
}

function toolFields(state) {
  const tools = state.tools.filter((tool) => tool.detected && tool.enabled);
  return `<fieldset class="skills-add-tools border-t border-border-custom pt-4"><legend class="text-[11px] font-semibold text-caption mb-2" data-i18n="skills.add.installTools">安装到工具</legend><div class="flex flex-wrap gap-2">${tools.length ? tools.map((tool) => `<label class="flex items-center gap-2 border border-border-custom rounded-lg px-2.5 py-2 text-[11px]"><input name="targetKeys" type="checkbox" value="${e(tool.key)}" checked><span>${e(tool.label)}</span></label>`).join('') : `<span class="text-[11px] text-caption" data-i18n="skills.library.noTargets">未检测到可用工具</span>`}</div><label class="block mt-3 text-[11px] text-caption"><span data-i18n="skills.add.syncMode">同步模式</span><select name="syncMode" autocomplete="off" class="ml-2 bg-bg-input border border-border-custom rounded-md px-2 py-1.5 text-fg"><option value="auto" data-i18n="skills.detail.mode.auto">自动</option><option value="symlink" data-i18n="skills.detail.mode.symlink">符号链接</option><option value="copy" data-i18n="skills.detail.mode.copy">复制</option></select></label></fieldset>`;
}

function commonFields(state) {
  return `<label class="block"><span class="block text-[11px] font-semibold text-caption mb-1.5" data-i18n="skills.add.tags">添加标签</span><input name="tags" type="text" autocomplete="off" class="w-full bg-bg-input border border-border-custom rounded-lg px-3 py-2.5 text-[12px] outline-none focus:border-brand" data-i18n-placeholder="skills.add.tagsPlaceholder" placeholder="例如：开发、效率…"></label>${toolFields(state)}`;
}

function gitPanel(state) {
  return `<form id="skillsGitForm" role="tabpanel" aria-labelledby="skillsAddTabGit" novalidate autocomplete="off" class="skills-add-panel border border-border-custom rounded-xl overflow-hidden">
    <div class="p-5 grid grid-cols-[210px_1fr] gap-5"><div><span class="w-9 h-9 rounded-[9px] bg-brand-soft text-brand flex items-center justify-center mb-3" data-icon="download"></span><h2 class="text-[15px] font-semibold" data-i18n="skills.add.gitTitle">Git 仓库</h2><p class="mt-1 text-[11.5px] text-caption leading-relaxed" data-i18n="skills.add.gitDesc">从仓库读取 SKILL.md，可一次导入一个或多个 Skill。</p></div><div class="flex flex-col gap-4"><label><span class="block text-[11px] font-semibold text-caption mb-1.5" data-i18n="skills.add.url">仓库地址</span><input name="url" type="url" inputmode="url" required autocomplete="url" autocapitalize="off" spellcheck="false" aria-describedby="skillsGitError" class="w-full bg-bg-input border border-border-custom rounded-lg px-3 py-2.5 text-[12px] font-mono outline-none focus:border-brand" data-i18n-placeholder="skills.add.urlPlaceholder" placeholder="https://github.com/owner/repo…"></label><p id="skillsGitError" class="hidden text-[10.5px] text-red" role="alert" aria-live="polite"></p>${commonFields(state)}</div></div>
    <footer class="flex justify-end gap-2 px-5 py-3 border-t border-border-custom"><button data-action="cancel-add" type="button" class="border border-border-custom rounded-md px-3 py-2 text-[11.5px] hover:bg-chip-bg" data-i18n="skills.action.cancel">取消</button><button type="submit" class="bg-brand text-white border-0 rounded-md px-5 py-2 text-[11.5px] font-semibold" data-i18n="skills.add.install">安装</button></footer>
  </form>`;
}

function candidates(state) {
  if (!state.add.localPath) return `<p class="text-[11.5px] text-caption" data-i18n="skills.add.noPath">尚未选择文件夹</p>`;
  if (!state.add.candidates.length) return `<p class="text-[11.5px] text-caption" data-i18n="skills.add.scanEmpty">将在所选文件夹中查找 SKILL.md</p>`;
  return `<fieldset><legend class="text-[11px] font-semibold mb-2"><span data-i18n="skills.add.candidateCount">发现候选 Skills</span> (${state.add.candidates.length})</legend><div class="max-h-[210px] overflow-y-auto flex flex-col gap-1.5">${state.add.candidates.map((item) => `<label class="flex items-start gap-2.5 border border-border-custom rounded-lg px-3 py-2"><input name="localPaths" type="checkbox" value="${e(item.path)}" checked><span class="min-w-0"><strong class="block text-[11.5px] truncate">${e(item.name)}</strong><small class="block text-[10px] text-caption truncate">${e(item.description || item.path)}</small></span></label>`).join('')}</div></fieldset>`;
}

function localPanel(state) {
  return `<form id="skillsLocalForm" role="tabpanel" aria-labelledby="skillsAddTabLocal" autocomplete="off" class="skills-add-panel border border-border-custom rounded-xl overflow-hidden"><div class="p-5 grid grid-cols-[210px_1fr] gap-5"><div><span class="w-9 h-9 rounded-[9px] bg-brand-soft text-brand flex items-center justify-center mb-3" data-icon="folder"></span><h2 class="text-[15px] font-semibold" data-i18n="skills.add.localTitle">本地文件夹</h2><p class="mt-1 text-[11.5px] text-caption leading-relaxed" data-i18n="skills.add.localDesc">选择含 SKILL.md 的目录，自动发现其中的 Skills。</p></div><div class="flex flex-col gap-4"><div><span class="block text-[11px] font-semibold text-caption mb-1.5" data-i18n="skills.add.selectedPath">所选路径</span><div class="flex gap-2"><code class="flex-1 min-w-0 truncate bg-bg-input border border-border-custom rounded-lg px-3 py-2.5 text-[11px]">${e(state.add.localPath || '—')}</code><button data-action="pick-local" type="button" class="border border-border-custom rounded-lg px-3 text-[11.5px] hover:bg-chip-bg" data-i18n="skills.add.choose">选择…</button></div></div>${candidates(state)}${commonFields(state)}</div></div><footer class="flex items-center justify-end gap-2 px-5 py-3 border-t border-border-custom"><button data-action="select-candidates" type="button" class="mr-auto text-[11px] text-brand" data-i18n="skills.add.selectAll">全选</button><button data-action="cancel-add" type="button" class="border border-border-custom rounded-md px-3 py-2 text-[11.5px] hover:bg-chip-bg" data-i18n="skills.action.cancel">取消</button><button type="submit" ${state.add.localPath ? '' : 'disabled'} class="bg-brand text-white border-0 rounded-md px-5 py-2 text-[11.5px] font-semibold disabled:opacity-40" data-i18n="skills.add.importSelected">导入所选</button></footer></form>`;
}

function values(form) {
  const data = new FormData(form);
  return { tags: String(data.get('tags') || '').split(/[,，]/).map((tag) => tag.trim()).filter(Boolean),
    targets: data.getAll('targetKeys').map(String), mode: String(data.get('syncMode') || 'auto') };
}

async function applyOptions(installed, opts, ctx) {
  const list = Array.isArray(installed) ? installed : installed ? [installed] : [];
  const outcomes = [];
  if (opts.tags.length) outcomes.push(...await ctx.settleBatch(list, (skill) => ctx.api.setTags(skill.id, opts.tags)));
  if (opts.targets.length) outcomes.push(...await ctx.settleBatch(list, (skill) => ctx.api.sync(skill.id, opts.targets, opts.mode)));
  return { list, outcomes };
}

export function render(host, ctx) {
  host.innerHTML = `${tabs(ctx.state)}${ctx.state.add.tab === 'git' ? gitPanel(ctx.state) : localPanel(ctx.state)}`;
  ctx.localize(host); host.onclick = (event) => onClick(event, host, ctx);
  const git = host.querySelector('#skillsGitForm'); if (git) git.onsubmit = (event) => submitGit(event, ctx);
  const local = host.querySelector('#skillsLocalForm'); if (local) local.onsubmit = (event) => submitLocal(event, ctx);
}

async function onClick(event, host, ctx) {
  const tab = event.target.closest('[data-add-tab]');
  if (tab) { ctx.state.add.tab = tab.dataset.addTab; return ctx.render(); }
  const button = event.target.closest('[data-action]'); if (!button) return;
  if (button.dataset.action === 'cancel-add') return ctx.navigate('library');
  if (button.dataset.action === 'select-candidates') { host.querySelectorAll('[name="localPaths"]').forEach((box) => { box.checked = true; }); return; }
  if (button.dataset.action !== 'pick-local') return;
  return ctx.run(async () => {
    const path = await ctx.api.pickLocal(); if (!path) return;
    ctx.state.add.localPath = path; ctx.state.add.candidates = [];
    try { ctx.state.add.candidates = await ctx.api.scanLocal(path) || []; }
    catch (_) { ctx.toast(I18n.t('skills.add.scanFailed'), 'err'); }
    ctx.render();
  });
}

async function submitGit(event, ctx) {
  event.preventDefault(); const form = event.currentTarget, data = new FormData(form);
  const url = String(data.get('url') || '').trim(), input = form.elements.url, error = form.querySelector('#skillsGitError');
  if (!/^(https?:\/\/|ssh:\/\/|git@)[^\s]+/i.test(url)) {
    input.setAttribute('aria-invalid', 'true'); error.textContent = I18n.t('skills.add.invalidUrl'); error.classList.remove('hidden');
    input.focus(); return;
  }
  input.removeAttribute('aria-invalid'); error.textContent = ''; error.classList.add('hidden');
  const opts = values(form);
  await ctx.run(async () => {
    let installed = [];
    try {
      const result = await applyOptions(await ctx.api.importGit(url), opts, ctx);
      installed = result.list; ctx.showBatchResult(result.outcomes, 'skills.toast.imported');
    } finally {
      if (installed.length) { ctx.state.add.localPath = ''; ctx.state.add.candidates = []; }
      await ctx.reload(false);
    }
    if (installed.length) ctx.navigate('library');
  });
}

async function submitLocal(event, ctx) {
  event.preventDefault(); const form = event.currentTarget, data = new FormData(form), opts = values(form);
  const paths = data.getAll('localPaths').map(String);
  if (!paths.length && ctx.state.add.candidates.length) return ctx.toast(I18n.t('skills.add.nothingSelected'), 'err');
  const chosen = paths.length ? paths : [ctx.state.add.localPath].filter(Boolean);
  if (!chosen.length) return;
  await ctx.run(async () => {
    let installed = [];
    try {
      const imported = await ctx.settleBatch(chosen, (path) => ctx.api.importLocal(path));
      installed = imported.filter((item) => item.status === 'fulfilled').map((item) => item.value);
      const post = await applyOptions(installed, opts, ctx);
      ctx.showBatchResult([...imported, ...post.outcomes], 'skills.toast.imported');
    } finally {
      if (installed.length) { ctx.state.add.localPath = ''; ctx.state.add.candidates = []; }
      await ctx.reload(false);
    }
    if (installed.length) ctx.navigate('library');
  });
}
