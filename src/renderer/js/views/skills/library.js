import { escapeHtml } from '../../core/dom.js';
import { I18n } from '../../core/i18n.js';
import { formDialog } from './layout.js';
import { allTags, canUpdate, formatDate, reconcileSelection, rememberView, sourceUnavailable, syncState, visibleSkills } from './state.js';

const e = escapeHtml;
const option = (value, key, fallback) => `<option value="${value}" data-i18n="${key}">${fallback}</option>`;

function stats(state) {
  const status = state.status || {};
  const metric = (value, fallback) => value == null || !Number.isFinite(Number(value)) ? fallback : Number(value);
  const git = state.skills.filter((skill) => skill.sourceType.includes('git')).length;
  const synced = state.skills.filter((skill) => skill.targets.length > 0).length;
  const cells = [
    ['skills.library.managed', '已管理', metric(status.total, state.skills.length)],
    ['skills.library.source.git', 'Git', metric(status.git_count, git)],
    ['skills.library.source.local', '本地', metric(status.local_count, state.skills.length - git)],
    ['skills.library.status.synced', '已同步', metric(status.synced_count, synced)],
  ];
  return `<div class="skills-stats grid grid-cols-4 gap-3 mb-4">${cells.map(([key, label, value]) => `<div class="skills-stat border border-border-custom rounded-xl p-4 bg-bg-elev"><span class="block text-[11px] text-caption" data-i18n="${key}">${label}</span><strong class="block mt-1.5 text-[23px] text-fg tabular-nums">${value}</strong></div>`).join('')}</div>`;
}

function toolbar(state) {
  const f = state.filters;
  const tags = allTags();
  return `<div class="skills-library-head flex items-center justify-between mb-3"><h2 class="text-[15px] font-semibold"><span data-i18n="skills.library.title">全部 Skills</span> <span class="text-caption font-normal">(${state.skills.length})</span></h2><div class="flex gap-2"><button data-action="refresh" type="button" class="skills-icon-btn border border-border-custom rounded-md px-2.5 py-1.5 text-muted hover:bg-chip-bg" data-i18n-title="skills.updates.check"><span data-icon="refresh" aria-hidden="true"></span></button><button data-action="add" type="button" class="bg-brand text-white border-0 rounded-md px-3 py-1.5 text-[11.5px] font-semibold" data-i18n="skills.nav.add">添加</button></div></div>
  <div class="skills-toolbar flex flex-wrap items-center gap-2 mb-3">
    <label class="skills-search flex flex-1 min-w-[220px] items-center gap-2 border border-border-custom rounded-lg px-3 bg-bg-input"><span data-icon="search" class="text-caption" aria-hidden="true"></span><span class="sr-only" data-i18n="skills.library.search">搜索 Skills</span><input id="skillsSearch" type="search" name="skillsQuery" autocomplete="off" value="${e(f.query)}" class="w-full py-2.5 bg-transparent border-0 text-[12.5px]" data-i18n-placeholder="skills.library.searchPlaceholder" placeholder="搜索 Skills…"></label>
    <label><span class="sr-only" data-i18n="skills.library.status.all">全部状态</span><select id="skillsStatusFilter" name="skillsStatus" autocomplete="off" class="skills-select bg-bg-input border border-border-custom rounded-lg px-2.5 py-2 text-[11.5px]">${option('all', 'skills.library.status.all', '全部状态')}${option('synced', 'skills.library.status.synced', '已同步')}${option('unsynced', 'skills.library.status.unsynced', '未同步')}${option('partial', 'skills.library.status.partial', '部分同步')}${option('issue', 'skills.library.status.issue', '异常')}</select></label>
    <label><span class="sr-only" data-i18n="skills.library.tag.all">全部标签</span><select id="skillsTagFilter" name="skillsTag" autocomplete="off" class="skills-select max-w-[130px] bg-bg-input border border-border-custom rounded-lg px-2.5 py-2 text-[11.5px]">${option('all', 'skills.library.tag.all', '全部标签')}${option('__untagged__', 'skills.library.tag.untagged', '无标签')}${tags.map((tag) => `<option value="${e(tag.name)}">${e(tag.name)} (${tag.count})</option>`).join('')}</select></label>
    <label><span class="sr-only" data-i18n="skills.library.sort.updated">最近更新</span><select id="skillsSort" name="skillsSort" autocomplete="off" class="skills-select bg-bg-input border border-border-custom rounded-lg px-2.5 py-2 text-[11.5px]">${option('updated', 'skills.library.sort.updated', '最近更新')}${option('name', 'skills.library.sort.name', '名称')}${option('source', 'skills.library.sort.source', '来源')}</select></label>
    <button data-action="bulk" type="button" aria-pressed="${Boolean(state.bulk)}" class="skills-bulk-toggle border border-border-custom rounded-lg px-3 py-2 text-[11.5px] hover:bg-chip-bg ${state.bulk ? 'bg-brand-soft text-brand' : ''}" data-i18n="skills.library.bulk">批量</button>
    <div class="skills-view-toggle flex border border-border-custom rounded-lg p-0.5"><button data-view="list" type="button" aria-pressed="${f.view === 'list'}" aria-label="${e(I18n.t('skills.library.view.list'))}" title="${e(I18n.t('skills.library.view.list'))}" class="px-2 py-1.5 rounded ${f.view === 'list' ? 'bg-brand-soft text-brand' : 'text-caption'}">☷</button><button data-view="cards" type="button" aria-pressed="${f.view === 'cards'}" aria-label="${e(I18n.t('skills.library.view.cards'))}" title="${e(I18n.t('skills.library.view.cards'))}" class="px-2 py-1.5 rounded ${f.view === 'cards' ? 'bg-brand-soft text-brand' : 'text-caption'}">▦</button></div>
  </div>`;
}

function bulkBar(state, count) {
  if (!state.bulk) return '';
  const disabled = state.selected.size ? '' : 'disabled';
  return `<div class="skills-bulk-bar flex items-center gap-2 px-3 py-2 mb-3 rounded-lg bg-brand-soft text-[11.5px]"><strong class="mr-auto tabular-nums" aria-live="polite" aria-atomic="true"><span data-i18n="skills.library.selected">已选择</span> ${state.selected.size}</strong><button data-action="select-all" type="button" ${count ? '' : 'disabled'} class="underline disabled:opacity-40" data-i18n="skills.library.selectAll">全选</button><button data-action="bulk-sync" type="button" ${disabled} class="border border-brand/30 rounded px-2 py-1 text-brand disabled:opacity-40" data-i18n="skills.library.bulkSync">批量同步</button><button data-action="bulk-delete" type="button" ${disabled} class="border border-red/30 rounded px-2 py-1 text-red disabled:opacity-40" data-i18n="skills.library.bulkDelete">批量删除</button><span class="text-caption tabular-nums">/${count}</span></div>`;
}

function skillCard(skill, state) {
  const syncing = syncState(skill), selected = state.selected.has(skill.id);
  const isGit = skill.sourceType.includes('git');
  const tools = (skill.targets || []).slice(0, 4).map((target) => `<span class="skills-tool-dot w-6 h-6 rounded-full bg-chip-bg flex items-center justify-center text-[9px]" title="${e(target.key)}" translate="no">${e(target.key.slice(0, 2).toUpperCase())}</span>`).join('');
  const update = canUpdate(skill) ? `<button data-action="update" type="button" class="skills-card-action" aria-label="${e(I18n.t('skills.library.update'))}" title="${e(I18n.t('skills.library.update'))}"><span data-icon="refresh"></span></button>` : '';
  const sync = skill.targets.length
    ? `<button data-action="unsync" type="button" class="skills-card-action text-brand" aria-label="${e(I18n.t('skills.library.unsync'))}">↗</button>`
    : sourceUnavailable(skill) ? '' : `<button data-action="sync" type="button" class="skills-card-action text-brand" aria-label="${e(I18n.t('skills.library.sync'))}">↻</button>`;
  return `<article class="skills-card group ${state.filters.view === 'cards' ? 'min-h-[180px]' : ''} border border-border-custom bg-bg-elev rounded-xl p-3.5 hover:border-border-strong hover:shadow-card" data-skill-id="${e(skill.id)}">
    <div class="flex items-start gap-3">${state.bulk ? `<label class="pt-1"><span class="sr-only">${e(I18n.t('skills.library.selected'))}: ${e(skill.name)}</span><input data-select-skill="${e(skill.id)}" name="selectedSkill" value="${e(skill.id)}" type="checkbox" autocomplete="off" ${selected ? 'checked' : ''}></label>` : ''}<span class="w-9 h-9 rounded-[9px] shrink-0 bg-brand-soft text-brand flex items-center justify-center" data-icon="${isGit ? 'download' : 'folder'}" aria-hidden="true"></span><div class="min-w-0 flex-1"><button data-action="detail" type="button" class="block max-w-full truncate text-left text-[14px] font-semibold hover:text-brand">${e(skill.name)}</button><p class="mt-0.5 text-[11.5px] text-caption line-clamp-2">${e(skill.description || I18n.t('skills.library.descriptionEmpty'))}</p></div><span class="skills-status-pill rounded-full px-2 py-1 text-[9.5px] ${syncing === 'synced' ? 'bg-green-soft text-green' : syncing === 'issue' ? 'bg-red-soft text-red' : 'bg-chip-bg text-caption'}">${e(I18n.t(`skills.library.status.${syncing}`))}</span></div>
    <div class="mt-3 flex flex-wrap gap-1 min-h-5">${skill.tags.length ? skill.tags.map((tag) => `<button data-action="tag-filter" data-tag="${e(tag)}" type="button" class="skills-tag rounded-full bg-chip-bg px-2 py-0.5 text-[9.5px] text-muted">${e(tag)}</button>`).join('') : `<span class="text-[10px] text-caption" data-i18n="skills.library.noTags">无标签</span>`}</div>
    <footer class="mt-3 pt-2.5 border-t border-border-custom flex items-center gap-1.5"><div class="flex -space-x-1 mr-auto">${tools}</div><time class="text-[9.5px] text-caption mr-2">${e(formatDate(skill.updatedAt))}</time><button data-action="edit-tags" type="button" class="skills-card-action" aria-label="${e(I18n.t('skills.library.editTags'))}" title="${e(I18n.t('skills.library.editTags'))}"><span data-icon="edit"></span></button>${update}${sync}<button data-action="delete" type="button" class="skills-card-action text-red" aria-label="${e(I18n.t('skills.library.delete'))}"><span data-icon="trash"></span></button></footer>
  </article>`;
}

function paint(host, ctx) {
  const list = reconcileSelection(visibleSkills());
  const result = host.querySelector('#skillsResults');
  if (!result) return;
  result.innerHTML = `${bulkBar(ctx.state, list.length)}${list.length ? `<div class="skills-results grid ${ctx.state.filters.view === 'cards' ? 'grid-cols-2' : 'grid-cols-1'} gap-2.5">${list.map((skill) => skillCard(skill, ctx.state)).join('')}</div>` : `<div class="skills-empty border border-dashed border-border-custom rounded-xl py-14 text-center text-caption"><span data-icon="empty" class="inline-flex"></span><p class="mt-3 text-[13px]" data-i18n="skills.library.empty">暂无 Skills</p><button data-action="add" type="button" class="mt-3 text-brand text-[12px]" data-i18n="skills.nav.add">添加 Skill</button></div>`}`;
  ctx.localize(result);
}

export function render(host, ctx) {
  host.innerHTML = `${stats(ctx.state)}${toolbar(ctx.state)}<div id="skillsResults"></div>`;
  ['skillsStatusFilter', 'skillsTagFilter', 'skillsSort'].forEach((id) => { const node = host.querySelector(`#${id}`); if (node) node.value = ctx.state.filters[{ skillsStatusFilter: 'status', skillsTagFilter: 'tag', skillsSort: 'sort' }[id]]; });
  paint(host, ctx); ctx.localize(host);
  host.querySelector('#skillsSearch').addEventListener('input', (event) => { ctx.state.filters.query = event.target.value; paint(host, ctx); });
  host.onchange = (event) => {
    const map = { skillsStatusFilter: 'status', skillsTagFilter: 'tag', skillsSort: 'sort' };
    if (map[event.target.id]) { ctx.state.filters[map[event.target.id]] = event.target.value; paint(host, ctx); }
    if (event.target.dataset.selectSkill) {
      const id = event.target.dataset.selectSkill;
      event.target.checked ? ctx.state.selected.add(id) : ctx.state.selected.delete(id); paint(host, ctx);
      [...host.querySelectorAll('[data-select-skill]')].find((node) => node.dataset.selectSkill === id)?.focus();
    }
  };
  host.onclick = (event) => onClick(event, host, ctx);
}

function onClick(event, host, ctx) {
  const view = event.target.closest('[data-view]');
  if (view) {
    const value = view.dataset.view; rememberView(value); reconcileSelection();
    return Promise.resolve(ctx.render()).then(() => host.querySelector(`[data-view="${value}"]`)?.focus());
  }
  const button = event.target.closest('[data-action]'); if (!button) return;
  const action = button.dataset.action, card = button.closest('[data-skill-id]');
  const skill = card && ctx.state.skills.find((item) => item.id === card.dataset.skillId);
  if (action === 'add') return ctx.navigate('add');
  if (action === 'refresh') return ctx.reload();
  if (action === 'retry') return ctx.reload();
  if (action === 'bulk') {
    ctx.state.bulk = !ctx.state.bulk; ctx.state.selected.clear();
    return Promise.resolve(ctx.render()).then(() => host.querySelector('[data-action="bulk"]')?.focus());
  }
  if (action === 'select-all') {
    reconcileSelection().forEach((item) => ctx.state.selected.add(item.id)); paint(host, ctx);
    return host.querySelector('[data-action="select-all"]')?.focus();
  }
  if (action === 'bulk-sync') return bulkSync(ctx);
  if (action === 'bulk-delete') return ctx.deleteSkills([...ctx.state.selected]);
  if (action === 'tag-filter') {
    ctx.state.filters.tag = button.dataset.tag;
    return Promise.resolve(ctx.render()).then(() => host.querySelector('#skillsTagFilter')?.focus());
  }
  if (!skill) return;
  if (action === 'detail') return ctx.openDetail(skill.id);
  if (action === 'edit-tags') return ctx.editTags(skill);
  if (action === 'update') return ctx.updateSkills([skill.id]);
  if (action === 'sync') return ctx.syncSkills([skill.id]);
  if (action === 'unsync') return ctx.unsyncSkills([skill.id]);
  if (action === 'delete') return ctx.deleteSkills([skill.id]);
}

async function bulkSync(ctx) {
  const ids = [...ctx.state.selected];
  if (!ids.length) return;
  const tools = ctx.state.tools.filter((tool) => tool.detected && tool.enabled);
  if (!tools.length) { ctx.toast(I18n.t('skills.library.noTargets'), 'err'); return; }
  const targets = tools.map((tool) => `<label class="flex items-center gap-2 rounded-lg border border-border-custom px-3 py-2"><input type="checkbox" name="target" value="${e(tool.key)}" autocomplete="off" checked><span class="min-w-0"><strong class="block text-[11.5px] truncate">${e(tool.label)}</strong><small class="block text-[9.5px] text-caption truncate" title="${e(tool.path)}">${e(tool.path || tool.key)}</small></span></label>`).join('');
  const data = await formDialog({ title: I18n.t('skills.library.bulkSync'), confirm: I18n.t('skills.detail.applySync'), body: `
    <p class="text-[11px] text-caption"><span data-i18n="skills.library.selected">已选择</span>: <strong class="tabular-nums">${ids.length}</strong></p>
    <fieldset><legend class="mb-2 text-[11px] font-semibold" data-i18n="skills.detail.targets">目标工具</legend><div class="grid gap-2 max-h-48 overflow-y-auto">${targets}</div></fieldset>
    <label class="text-[11px] text-caption"><span data-i18n="skills.detail.syncMode">同步模式</span><select name="mode" autocomplete="off" class="mt-1.5 w-full bg-bg-input border border-border-custom rounded-lg px-3 py-2 text-fg"><option value="auto" data-i18n="skills.detail.mode.auto">自动</option><option value="symlink" data-i18n="skills.detail.mode.symlink">符号链接</option><option value="copy" data-i18n="skills.detail.mode.copy">复制</option></select></label>`,
  });
  if (!data) return;
  const keys = data.getAll('target').map(String).filter(Boolean);
  if (!keys.length) { ctx.toast(I18n.t('skills.library.noTargets'), 'err'); return; }
  return ctx.syncSkills(ids, keys, String(data.get('mode') || 'auto'));
}
