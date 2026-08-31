import { escapeHtml } from '../../core/dom.js';
import { I18n } from '../../core/i18n.js';
import { confirmAction } from './layout.js';

const e = escapeHtml;
let showMissing = false;

function stats(state) {
  const status = state.status || {};
  const metric = (value, fallback) => value == null || !Number.isFinite(Number(value)) ? fallback : Number(value);
  const synced = state.skills.filter((skill) => skill.targets.length > 0).length;
  const values = [
    ['skills.tools.total', '总数', state.tools.length],
    ['skills.tools.detected', '已检测', state.tools.filter((tool) => tool.detected).length],
    ['skills.library.managed', '已管理', metric(status.total, state.skills.length)],
    ['skills.library.status.synced', '已同步', metric(status.synced_count, synced)],
  ];
  return `<div class="skills-tool-stats grid grid-cols-4 gap-3 mb-4">${values.map(([key, label, value]) => `<div class="border border-border-custom rounded-xl p-4"><span class="block text-[10.5px] text-caption" data-i18n="${key}">${label}</span><strong class="block text-[22px] mt-1 tabular-nums">${value}</strong></div>`).join('')}</div>`;
}

function card(tool, state) {
  const synced = state.skills.filter((skill) => skill.targets.some((target) => target.key === tool.key)).length;
  return `<article data-tool="${e(tool.key)}" class="skills-tool-card border border-border-custom rounded-xl p-4 ${tool.detected ? '' : 'opacity-60'}"><header class="flex items-start gap-3"><span class="w-9 h-9 rounded-[9px] bg-brand-soft text-brand flex items-center justify-center font-semibold text-[10px]" aria-hidden="true">${e(tool.label.slice(0, 2).toUpperCase())}</span><div class="min-w-0 flex-1"><h3 class="text-[13px] font-semibold truncate">${e(tool.label)}</h3><p class="mt-0.5 text-[10px] ${tool.detected ? 'text-green' : 'text-caption'}"><span aria-hidden="true">●</span> ${e(I18n.t(tool.detected ? 'skills.tools.detected' : 'skills.tools.missing'))}</p></div><span class="rounded-full bg-chip-bg px-2 py-1 text-[9px] text-caption" translate="no">${e(tool.syncMode)}</span></header><dl class="mt-4 grid grid-cols-[74px_1fr] gap-y-2 text-[10.5px]"><dt class="text-caption" data-i18n="skills.tools.path">目录</dt><dd class="truncate font-mono" title="${e(tool.path)}" translate="no">${e(tool.path || '—')}</dd><dt class="text-caption" data-i18n="skills.tools.shared">已同步</dt><dd class="tabular-nums">${synced} Skills</dd></dl><footer class="mt-4 pt-3 border-t border-border-custom flex justify-end gap-2"><button data-action="tool-unsync" type="button" ${synced ? '' : 'disabled'} class="border border-border-custom rounded-md px-2.5 py-1.5 text-[10px] hover:bg-chip-bg disabled:opacity-35" data-i18n="skills.tools.unsyncAll">全部取消同步</button><button data-action="tool-sync" type="button" ${tool.detected && tool.enabled ? '' : 'disabled'} class="bg-brand text-white rounded-md px-2.5 py-1.5 text-[10px] hover:bg-brand-2 disabled:opacity-35" data-i18n="skills.tools.syncAll">全部同步</button></footer></article>`;
}

export function render(host, ctx) {
  const detected = ctx.state.tools.filter((tool) => tool.detected).sort((a, b) => a.label.localeCompare(b.label));
  const missing = ctx.state.tools.filter((tool) => !tool.detected).sort((a, b) => a.label.localeCompare(b.label));
  host.innerHTML = `<header class="mb-4"><h2 class="text-[17px] font-semibold" data-i18n="skills.tools.title">工具</h2><p class="mt-1 text-[11.5px] text-caption" data-i18n="skills.tools.description">管理 Skills 的同步目标与安装状态。</p></header>${stats(ctx.state)}<section class="skills-tools-panel border border-border-custom rounded-xl overflow-hidden"><header class="px-4 py-3 border-b border-border-custom"><h3 class="text-[13px] font-semibold" data-i18n="skills.tools.configured">已配置工具</h3></header>${detected.length ? `<div class="grid grid-cols-2 gap-3 p-3">${detected.map((tool) => card(tool, ctx.state)).join('')}</div>` : `<div class="py-12 text-center text-caption" role="status" data-i18n="skills.tools.empty">未检测到工具</div>`}${missing.length ? `<div class="border-t border-border-custom"><button data-action="toggle-missing" type="button" aria-expanded="${showMissing}" aria-controls="skillsMissingTools" class="w-full flex items-center justify-between px-4 py-3 text-[11px] text-caption hover:bg-chip-bg"><span><span data-i18n="skills.tools.missing">未检测</span> (${missing.length})</span><span aria-hidden="true">${showMissing ? '▴' : '▾'}</span></button>${showMissing ? `<div id="skillsMissingTools" class="grid grid-cols-2 gap-3 p-3 pt-0">${missing.map((tool) => card(tool, ctx.state)).join('')}</div>` : ''}</div>` : ''}</section>`;
  ctx.localize(host); host.onclick = (event) => onClick(event, ctx);
}

function onClick(event, ctx) {
  const button = event.target.closest('[data-action]'); if (!button) return;
  if (button.dataset.action === 'toggle-missing') {
    showMissing = !showMissing; render(event.currentTarget, ctx);
    return event.currentTarget.querySelector('[data-action="toggle-missing"]')?.focus();
  }
  const key = button.closest('[data-tool]')?.dataset.tool; if (!key) return;
  if (button.dataset.action === 'tool-sync') return ctx.syncSkills(ctx.state.skills.map((skill) => skill.id), [key]);
  if (button.dataset.action === 'tool-unsync') return unsyncTool(key, ctx);
}

async function unsyncTool(key, ctx) {
  const tool = ctx.state.tools.find((item) => item.key === key);
  const ids = ctx.state.skills.filter((skill) => skill.targets.some((target) => target.key === key)).map((skill) => skill.id);
  if (!ids.length) return;
  const ok = await confirmAction(I18n.t('skills.tools.unsyncConfirmTitle'),
    I18n.t('skills.tools.unsyncConfirm', { count: ids.length, tool: tool?.label || key }), I18n.t('skills.tools.unsyncAll'));
  if (ok) return ctx.unsyncSkills(ids, [key]);
}
