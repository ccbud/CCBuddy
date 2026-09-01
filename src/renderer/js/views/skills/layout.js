import { $, escapeHtml, injectIcons } from '../../core/dom.js';
import { I18n } from '../../core/i18n.js';

const navItems = [
  ['library', 'skills', 'skills.nav.library', '我的 Skills'],
  ['add', 'plus', 'skills.nav.add', '添加'],
  ['tags', 'edit', 'skills.nav.tags', '标签'],
  ['tools', 'plugins', 'skills.nav.tools', '工具'],
  ['updates', 'refresh', 'skills.nav.updates', '更新'],
];

export function template() {
  return `<section id="view-skills" data-clarity-mask="true" class="skills-view panel hidden flex-1 min-h-0 w-full px-6 pt-4 pb-5 animate-[panelIn_0.28s_ease-[cubic-bezier(0.23,1,0.32,1)]]">
    <div class="skills-shell max-w-[1320px] h-full min-h-0 mx-auto flex overflow-hidden bg-bg-elev border border-border-custom rounded-[18px] shadow-card">
      <aside class="skills-subnav w-[188px] shrink-0 border-r border-border-custom p-3 flex flex-col" aria-label="Skills Hub">
        <div class="skills-brand px-2.5 py-3 mb-3">
          <div class="flex items-center gap-2.5"><span class="w-8 h-8 rounded-[9px] bg-brand-soft text-brand flex items-center justify-center" data-icon="skills"></span>
            <div class="min-w-0"><h1 class="text-[15px] font-semibold text-fg" data-i18n="skills.title">Skills Hub</h1><p class="text-[10.5px] text-caption truncate" data-i18n="skills.subtitle">Skill 同步工作区</p></div>
          </div>
        </div>
        <nav id="skillsNav" class="flex flex-col gap-1">
          ${navItems.map(([page, icon, key, label]) => `<button type="button" data-skills-page="${page}" data-i18n-title="${key}" title="${escapeHtml(label)}" aria-label="${escapeHtml(label)}" class="skills-nav-item flex items-center gap-2.5 w-full px-2.5 py-2 rounded-[9px] border-0 bg-transparent text-muted text-[12.5px] text-left cursor-pointer hover:bg-chip-bg hover:text-fg [&.active]:bg-brand-soft [&.active]:text-brand [&.active]:font-semibold"><span class="w-4 h-4 flex items-center justify-center" data-icon="${icon}"></span><span class="flex-1" data-i18n="${key}">${label}</span><em data-skills-count="${page}" class="not-italic text-[10px] min-w-5 text-center rounded-full bg-chip-bg px-1"></em></button>`).join('')}
        </nav>
        <div class="flex-1"></div>
        <div class="skills-root px-2 py-2 border-t border-border-custom">
          <span class="block text-[10px] uppercase tracking-wide text-caption mb-1" data-i18n="skills.root.label">Skills 源目录</span>
          <code id="skillsRoot" class="block truncate text-[10.5px] text-muted" title="~/.ccbud/skills">~/.ccbud/skills</code>
          <button id="skillsOpenRoot" type="button" class="mt-2 w-full border border-border-custom rounded-md bg-bg-elev px-2 py-1.5 text-[11px] text-fg hover:bg-chip-bg" data-i18n="skills.root.open" data-i18n-title="skills.root.open" title="打开目录" aria-label="打开目录">打开目录</button>
        </div>
      </aside>
      <div id="skillsPage" class="skills-page flex-1 min-w-0 min-h-0 overflow-y-auto p-5" tabindex="-1"></div>
    </div>
    <dialog id="skillsDialog" aria-labelledby="skillsDialogTitle" class="skills-dialog m-auto w-[440px] max-w-[90vw] p-0 rounded-[14px] bg-bg-elev text-fg border border-border-custom shadow-card-hover backdrop:bg-black/45 backdrop:backdrop-blur-sm"></dialog>
  </section>`;
}

export function setActiveNav(page, state) {
  const nav = $('skillsNav');
  if (!nav) return;
  nav.querySelectorAll('[data-skills-page]').forEach((button) => {
    const active = button.dataset.skillsPage === page || (page === 'detail' && button.dataset.skillsPage === 'library');
    button.classList.toggle('active', active);
    if (active) button.setAttribute('aria-current', 'page'); else button.removeAttribute('aria-current');
  });
  const values = { library: state.skills.length, tags: new Set(state.skills.flatMap((skill) => skill.tags)).size,
    tools: state.tools.filter((tool) => tool.detected).length,
    updates: state.skills.filter((skill) => skill.sourceType.includes('git')).length };
  Object.entries(values).forEach(([key, value]) => { const el = nav.querySelector(`[data-skills-count="${key}"]`); if (el) el.textContent = value; });
  const root = $('skillsRoot');
  if (root) { root.textContent = state.status.root || '~/.ccbud/skills'; root.title = root.textContent; }
}

export function pageState(kind, message) {
  const icon = kind === 'loading' ? '<span class="skills-spinner inline-block w-5 h-5 rounded-full border-2 border-brand/30 border-t-brand animate-spin"></span>' : '<span data-icon="empty"></span>';
  const key = kind === 'loading' ? 'skills.loading' : kind === 'error' ? 'skills.error' : 'skills.library.empty';
  const fallback = kind === 'loading' ? '正在加载…' : kind === 'error' ? '无法载入 Skills' : '暂无 Skills';
  return `<div class="skills-state min-h-[280px] flex flex-col items-center justify-center gap-3 text-caption" role="${kind === 'error' ? 'alert' : 'status'}" aria-live="${kind === 'error' ? 'assertive' : 'polite'}" aria-atomic="true">${icon}<p data-i18n="${key}">${fallback}</p>${message ? `<code class="max-w-[560px] text-center text-[11px] break-all">${escapeHtml(message)}</code>` : ''}${kind === 'error' ? '<button type="button" data-action="retry" class="border border-border-custom rounded-md px-3 py-1.5 text-[12px] text-fg hover:bg-chip-bg" data-i18n="skills.retry">重试</button>' : ''}</div>`;
}

export function localize(root) {
  I18n.apply(root);
  injectIcons(root);
}

export function formDialog({ title, body, confirm, danger }) {
  const dialog = $('skillsDialog');
  if (!dialog || dialog.open) return Promise.resolve(null);
  dialog.innerHTML = `<form method="dialog" class="skills-dialog-form">
    <header class="px-5 py-4 border-b border-border-custom"><h2 id="skillsDialogTitle" class="text-[15px] font-semibold">${escapeHtml(title)}</h2></header>
    <div class="px-5 py-4 flex flex-col gap-3">${body || ''}</div>
    <footer class="px-5 py-3 border-t border-border-custom flex justify-end gap-2"><button type="button" data-dialog-cancel class="border border-border-custom bg-bg-elev rounded-md px-3 py-1.5 text-[12px] hover:bg-chip-bg" data-i18n="skills.action.cancel">取消</button><button type="submit" value="confirm" data-dialog-confirm class="${danger ? 'bg-red' : 'bg-brand'} text-white border-0 rounded-md px-3 py-1.5 text-[12px] font-semibold">${escapeHtml(confirm || I18n.t('skills.action.confirm'))}</button></footer>
  </form>`;
  localize(dialog);
  return new Promise((resolve) => {
    const form = dialog.querySelector('form'), previous = document.activeElement;
    const done = () => {
      dialog.removeEventListener('close', done);
      const result = dialog.returnValue === 'confirm' ? new FormData(form) : null;
      if (previous?.isConnected) previous.focus({ preventScroll: true });
      resolve(result);
    };
    dialog.addEventListener('close', done); dialog.returnValue = '';
    dialog.querySelector('[data-dialog-cancel]').addEventListener('click', () => dialog.close('cancel'));
    dialog.showModal();
    const focus = dialog.querySelector('input:not([type="hidden"]), select, textarea, [data-dialog-confirm]');
    if (focus) setTimeout(() => focus.focus(), 0);
  });
}

export function confirmAction(title, message, confirm, danger = true) {
  return formDialog({ title, confirm, danger, body: `<p class="text-[12.5px] text-caption leading-relaxed">${escapeHtml(message)}</p>` }).then(Boolean);
}
