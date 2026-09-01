import { escapeHtml } from '../../core/dom.js';
import { I18n } from '../../core/i18n.js';
import { allTags, formatDate } from './state.js';
import { confirmAction, formDialog } from './layout.js';

const e = escapeHtml;

function rows(state) {
  return allTags().map((tag) => {
    const skills = state.skills.filter((skill) => skill.tags.includes(tag.name));
    const last = Math.max(0, ...skills.map((skill) => skill.updatedAt));
    return `<tr data-tag="${e(tag.name)}" class="border-t border-border-custom"><td class="px-4 py-3"><button data-action="view-tag" type="button" class="font-semibold text-brand">${e(tag.name)}</button></td><td class="px-4 py-3 text-caption">${tag.count}</td><td class="px-4 py-3 text-caption">${e(formatDate(last))}</td><td class="px-4 py-3"><div class="flex gap-2"><button data-action="rename-tag" type="button" class="text-[10.5px] hover:text-brand" data-i18n="skills.tags.rename">重命名</button><button data-action="delete-tag" type="button" class="text-[10.5px] text-red" data-i18n="skills.tags.delete">删除</button></div></td></tr>`;
  }).join('');
}

function createPanel(state) {
  return `<form id="skillsNewTag" autocomplete="off" class="skills-new-tag border border-border-custom rounded-xl overflow-hidden"><header class="px-4 py-3 border-b border-border-custom"><h3 class="text-[14px] font-semibold" data-i18n="skills.tags.newTitle">新建标签</h3></header><div class="p-4 flex flex-col gap-3"><label><span class="block text-[10.5px] text-caption mb-1" data-i18n="skills.tags.name">标签名称</span><input name="tag" type="text" required autocomplete="off" class="w-full bg-bg-input border border-border-custom rounded-lg px-3 py-2 text-[11.5px] outline-none focus:border-brand" data-i18n-placeholder="skills.tags.newPlaceholder" placeholder="例如：开发…"></label><label><span class="block text-[10.5px] text-caption mb-1" data-i18n="skills.tags.assignTo">立即应用到</span><select name="skillId" required autocomplete="off" class="w-full bg-bg-input border border-border-custom rounded-lg px-3 py-2 text-[11.5px]">${state.skills.map((skill) => `<option value="${e(skill.id)}">${e(skill.name)}</option>`).join('')}</select></label><button type="submit" ${state.skills.length ? '' : 'disabled'} class="self-start bg-brand text-white border-0 rounded-md px-3 py-2 text-[11px] font-semibold disabled:opacity-40"><span data-i18n="skills.tags.create">创建标签</span></button></div></form>`;
}

export function render(host, ctx) {
  const tags = allTags(), untagged = ctx.state.skills.filter((skill) => !skill.tags.length).length;
  host.innerHTML = `<header class="mb-4"><h2 class="text-[17px] font-semibold" data-i18n="skills.tags.title">标签</h2><p class="mt-1 text-[11.5px] text-caption" data-i18n="skills.tags.description">整理、重命名并查看 Skills 标签。</p></header><div class="grid grid-cols-[minmax(0,1fr)_330px] gap-4"><section class="skills-tags-table border border-border-custom rounded-xl overflow-hidden"><header class="flex items-center justify-between px-4 py-3"><h3 class="text-[13px] font-semibold" data-i18n="skills.tags.title">标签</h3><span class="text-[10.5px] text-caption">${tags.length}</span></header><table class="w-full text-left text-[11px]"><thead class="bg-bg-input text-caption"><tr><th class="px-4 py-2" data-i18n="skills.tags.name">标签名称</th><th class="px-4 py-2" data-i18n="skills.tags.skills">Skills</th><th class="px-4 py-2" data-i18n="skills.tags.lastUsed">最近使用</th><th class="px-4 py-2" data-i18n="skills.tags.actions">操作</th></tr></thead><tbody>${rows(ctx.state)}</tbody></table>${tags.length ? '' : `<div class="skills-tags-empty border-t border-dashed border-border-custom px-4 py-8 text-caption" data-i18n="skills.tags.empty">暂无标签</div>`}</section><aside class="flex flex-col gap-4">${createPanel(ctx.state)}<div class="border border-border-custom rounded-xl p-4 flex items-center gap-2 text-[11.5px]"><span data-icon="edit" class="text-caption"></span><strong class="mr-auto"><span>${untagged}</span> <span data-i18n="skills.tags.untaggedCount">个 Skill 尚无标签</span></strong><button data-action="view-untagged" type="button" class="border border-border-custom rounded-md px-3 py-1.5" data-i18n="skills.tags.review">查看</button></div></aside></div>`;
  ctx.localize(host); host.onclick = (event) => onClick(event, ctx);
  host.querySelector('#skillsNewTag').onsubmit = (event) => createTag(event, ctx);
}

async function createTag(event, ctx) {
  event.preventDefault(); const data = new FormData(event.currentTarget);
  const name = String(data.get('tag') || '').trim(), id = String(data.get('skillId') || '');
  const skill = ctx.state.skills.find((item) => item.id === id); if (!name || !skill) return;
  await ctx.run(async () => { await ctx.api.setTags(id, [...new Set([...skill.tags, name])]); await ctx.reload(false); }, 'skills.toast.tagsSaved');
}

async function renameTag(name, ctx) {
  const data = await formDialog({ title: I18n.t('skills.tags.renameTitle'), confirm: I18n.t('skills.action.save'), body: `<label class="block text-[11px] text-caption"><span data-i18n="skills.tags.name">标签名称</span><input name="tag" type="text" required autocomplete="off" value="${e(name)}" class="mt-1.5 w-full bg-bg-input border border-border-custom rounded-lg px-3 py-2 text-fg"></label>` });
  const next = data && String(data.get('tag') || '').trim(); if (!next || next === name) return;
  const affected = ctx.state.skills.filter((skill) => skill.tags.includes(name));
  await ctx.runBatch(affected, (skill) => ctx.api.setTags(skill.id, [...new Set(skill.tags.map((tag) => tag === name ? next : tag))]), 'skills.toast.tagsSaved');
}

async function deleteTag(name, ctx) {
  const ok = await confirmAction(I18n.t('skills.tags.deleteTitle'), I18n.t('skills.tags.deleteConfirm', { name }), I18n.t('skills.tags.delete'));
  if (!ok) return; const affected = ctx.state.skills.filter((skill) => skill.tags.includes(name));
  await ctx.runBatch(affected, (skill) => ctx.api.setTags(skill.id, skill.tags.filter((tag) => tag !== name)), 'skills.toast.tagsSaved');
}

function onClick(event, ctx) {
  const button = event.target.closest('[data-action]'); if (!button) return;
  const tag = button.closest('[data-tag]')?.dataset.tag, action = button.dataset.action;
  if (action === 'view-untagged') { ctx.state.filters.tag = '__untagged__'; return ctx.navigate('library'); }
  if (action === 'view-tag') { ctx.state.filters.tag = tag; return ctx.navigate('library'); }
  if (action === 'rename-tag') return renameTag(tag, ctx);
  if (action === 'delete-tag') return deleteTag(tag, ctx);
}
