import { escapeHtml } from '../../core/dom.js';
import { I18n } from '../../core/i18n.js';
import { formatDate } from './state.js';

const e = escapeHtml;
const isGit = (skill) => String(skill && (skill.sourceType || skill.source_type) || '').toLowerCase().includes('git');

function skillRows(skills) {
  return skills.map((skill) => {
    const available = /update|outdated|behind/.test(skill.status);
    const failed = /error|fail|missing|invalid/.test(skill.status);
    const tone = failed ? 'bg-red-soft text-red' : available ? 'bg-amber-soft text-amber' : 'bg-green-soft text-green';
    const key = failed ? 'skills.updates.failed' : available ? 'skills.updates.available' : 'skills.updates.current';
    const label = failed ? '失败' : available ? '有更新' : '已是最新';
    return `<li data-skill-id="${e(skill.id)}" class="flex items-center gap-3 px-4 py-3 border-t border-border-custom"><span class="w-8 h-8 rounded-lg bg-brand-soft text-brand flex items-center justify-center" data-icon="download" aria-hidden="true"></span><div class="min-w-0 flex-1"><strong class="block text-[12px] truncate">${e(skill.name)}</strong><small class="block text-[9.5px] text-caption truncate">${e(skill.sourceRef || skill.path)}</small></div><time class="text-[9.5px] text-caption">${e(formatDate(skill.updatedAt))}</time><span class="rounded-full px-2 py-1 text-[9px] ${tone}" data-i18n="${key}">${label}</span><button data-action="update-one" type="button" class="border border-border-custom rounded-md px-2.5 py-1.5 text-[10px] hover:bg-chip-bg" data-i18n="skills.updates.updateOne">更新</button></li>`;
  }).join('');
}

function runResult(state) {
  const value = state.updates;
  return `<aside class="skills-update-result border border-border-custom rounded-xl p-4 h-fit" aria-live="polite" aria-atomic="true"><div class="flex items-center justify-between"><span class="text-[10.5px] font-semibold text-caption" data-i18n="skills.updates.lastRun">上次运行</span><strong class="text-[10.5px]">${value.lastRun ? e(formatDate(value.lastRun)) : `<span data-i18n="skills.updates.none">尚未运行</span>`}</strong></div><div class="grid grid-cols-3 gap-2 mt-4">${[['checked', 'skills.updates.checked', '已检查'], ['updated', 'skills.updates.updated', '已更新'], ['failed', 'skills.updates.failed', '失败']].map(([field, key, label]) => `<div class="border border-border-custom rounded-lg p-2.5"><span class="block text-[9.5px] text-caption" data-i18n="${key}">${label}</span><strong class="block mt-1 text-[17px] tabular-nums ${field === 'failed' && value[field] ? 'text-red' : ''}">${value[field]}</strong></div>`).join('')}</div>${value.errors.length ? `<div class="mt-4 border-t border-border-custom pt-3"><h4 class="text-[10.5px] font-semibold text-red" data-i18n="skills.updates.issues">问题</h4>${value.errors.map((error) => `<code class="block mt-1 text-[9px] text-caption break-all">${e(error)}</code>`).join('')}</div>` : ''}</aside>`;
}

export function render(host, ctx) {
  const git = ctx.state.skills.filter(isGit);
  host.innerHTML = `<header class="mb-4"><h2 class="text-[17px] font-semibold" data-i18n="skills.updates.title">更新</h2><p class="mt-1 text-[11.5px] text-caption" data-i18n="skills.updates.description">检查 Git 来源的 Skills，并安全应用更新。</p></header><div class="grid grid-cols-[minmax(0,1fr)_300px] gap-4"><section class="skills-update-control border border-border-custom rounded-xl overflow-hidden"><header class="p-4 flex items-center gap-3"><span class="w-9 h-9 rounded-[9px] bg-brand-soft text-brand flex items-center justify-center" data-icon="refresh" aria-hidden="true"></span><div class="flex-1"><span class="block text-[10px] text-caption" data-i18n="skills.updates.gitSkills">Git Skills</span><strong class="text-[16px] tabular-nums">${git.length}</strong></div><button data-action="check" type="button" class="border border-border-custom rounded-md px-3 py-2 text-[10.5px] hover:bg-chip-bg" data-i18n="skills.updates.check">检查更新</button><button data-action="update-all" type="button" ${git.length ? '' : 'disabled'} class="bg-brand text-white rounded-md px-3 py-2 text-[10.5px] font-semibold disabled:opacity-40" data-i18n="skills.updates.updateAll">全部更新</button></header><ul>${git.length ? skillRows(git) : `<li class="border-t border-border-custom py-12 text-center text-caption" role="status" data-i18n="skills.updates.none">没有可更新的 Git Skills</li>`}</ul><footer class="px-4 py-3 border-t border-border-custom text-[10px] text-caption"><span data-i18n="skills.updates.local">本地 Skills 不会从远程更新</span> · <span class="tabular-nums">${ctx.state.skills.length - git.length}</span></footer></section>${runResult(ctx.state)}</div>`;
  ctx.localize(host); host.onclick = (event) => onClick(event, ctx);
}

async function check(ctx) {
  const started = Date.now();
  const completed = await ctx.run(async () => {
    ctx.state.updates.checked = 0; ctx.state.updates.updated = 0;
    try {
      const refreshed = await ctx.api.refresh(null);
      const git = (Array.isArray(refreshed) ? refreshed : []).filter(isGit);
      const failures = git.filter((skill) => /error|fail/.test(String(skill.status || '').toLowerCase()));
      ctx.state.updates.checked = git.length; ctx.state.updates.failed = failures.length;
      ctx.state.updates.errors = failures.map((skill) => `${skill.name || skill.id}: ${skill.status}`);
      return true;
    } catch (error) {
      ctx.state.updates.failed = 1; ctx.state.updates.errors = [String(error && error.message || error)]; throw error;
    } finally {
      ctx.state.updates.lastRun = started; await ctx.reload(false);
    }
  });
  if (completed !== true) return;
  const failed = ctx.state.updates.failed;
  ctx.toast(failed ? `${I18n.t('skills.toast.failed')} ${failed}/${ctx.state.updates.checked}` : I18n.t('skills.toast.done'), failed ? 'err' : 'ok');
}

async function update(ids, ctx) {
  ids = [...new Set(ids)].filter(Boolean); if (!ids.length) return;
  const started = Date.now();
  const completed = await ctx.run(async () => {
    try {
      const outcomes = await Promise.allSettled(ids.map((id) => ctx.api.update(id)));
      ctx.state.updates.checked = outcomes.length;
      ctx.state.updates.updated = outcomes.filter((item) => item.status === 'fulfilled').length;
      ctx.state.updates.failed = outcomes.length - ctx.state.updates.updated;
      ctx.state.updates.errors = outcomes.filter((item) => item.status === 'rejected').map((item) => String(item.reason && item.reason.message || item.reason));
      return true;
    } finally {
      ctx.state.updates.lastRun = started; await ctx.reload(false);
    }
  });
  if (completed !== true) return;
  const failed = ctx.state.updates.failed;
  ctx.toast(failed ? `${I18n.t('skills.toast.failed')} ${failed}/${ids.length}` : I18n.t('skills.toast.updated'), failed ? 'err' : 'ok');
}

function onClick(event, ctx) {
  const button = event.target.closest('[data-action]'); if (!button) return;
  if (button.dataset.action === 'check') return check(ctx);
  if (button.dataset.action === 'update-all') return update(ctx.state.skills.filter(isGit).map((skill) => skill.id), ctx);
  if (button.dataset.action === 'update-one') return update([button.closest('[data-skill-id]').dataset.skillId], ctx);
}
