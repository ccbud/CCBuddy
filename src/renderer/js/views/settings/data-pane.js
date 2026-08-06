/* 设置 → 数据 pane: history work directories. */
import { $, escapeHtml } from '../../core/dom.js';
import { api } from '../../core/bridge.js';
import { I18n } from '../../core/i18n.js';
import { icons } from '../../core/icons.js';
import { state, persist } from '../../core/state.js';

export const dataPaneTemplate = () => `
            <div data-pane="data" class="hidden">
            <div class="settings-card bg-bg-elev border border-border-custom rounded-xl shadow-card p-7 flex flex-col gap-6 transition-all duration-300">
              <div class="settings-card-header flex justify-between items-center">
                <h3 class="settings-card-title text-[13px] font-semibold text-fg" data-i18n="settings.histDir">工作目录</h3>
                <button class="btn btn-sm btn-primary bg-primary text-white border-none rounded-md px-2.25 py-1.25 font-semibold text-[11px] leading-none cursor-pointer transition-all duration-140 hover:bg-primary-hover active:scale-[0.985]" id="btnPickHistDir" type="button" data-i18n="settings.pickDir">选择目录…</button>
              </div>
              <p class="caption text-[12px] text-caption" data-i18n="settings.histDirDesc">会话与用量统计的数据来源 —— Claude Code 的配置目录（含 projects/）。默认 ~/.claude；若用 CLAUDE_CONFIG_DIR / claude --config 指定了其他目录，在此添加，可在「会话」页切换查看。</p>
              <div id="histDirList" class="hist-dir-list" data-clarity-mask="true"></div>
            </div>
            </div>`;

export async function renderDataPane() {
  const host = $('histDirList');
  if (!host) return;
  let data; try { data = await api.historyDirs(); } catch (_) { data = { dirs: [] }; }
  // The synthetic buckets (导入 store / 回收站) are app-managed, not user work dirs — keep
  // them out of this list.
  const dirs = (data.dirs || []).filter((d) => !d.imported && !d.trash);
  host.innerHTML = dirs.map((d) => {
    const status = d.exists === false
      ? `<span class="hist-dir-warn text-red font-semibold text-[11px] shrink-0 bg-red-soft px-2.5 py-0.75 rounded-full" title="${escapeHtml(I18n.t('settings.dirMissing'))}">${escapeHtml(I18n.t('settings.dirMissing'))}</span>`
      : `<span class="hist-dir-count text-brand font-semibold text-[11px] shrink-0 bg-brand-soft px-2.5 py-0.75 rounded-full">${escapeHtml(I18n.t('settings.sessions', { n: d.sessions }))}</span>`;
    return `<div class="hist-dir-row flex items-center gap-3.5 p-3 px-4 bg-bg-elev border border-border-custom rounded-md text-[13px] shadow-sm transition-all duration-200 ease-out hover:-translate-y-0.5 hover:border-border-strong hover:shadow-card-hover [.missing_&]:opacity-70 [.missing_&_.hist-dir-label]:text-muted [.missing_&_.hist-dir-label]:line-through${d.exists === false ? ' missing' : ''}">
      <span class="hist-dir-label flex-1 font-mono truncate text-fg text-[12.5px]" title="${escapeHtml(d.projectsDir || '')}">${escapeHtml(d.label)}</span>
      ${status}
      <button class="hist-dir-del w-7 h-7 border-0 rounded-full bg-transparent text-muted cursor-pointer flex items-center justify-center shrink-0 transition-colors duration-200 hover:enabled:text-red hover:enabled:bg-red-soft disabled:opacity-25 disabled:cursor-not-allowed" data-del-dir="${escapeHtml(d.id)}" title="${escapeHtml(I18n.t('providers.remove'))}"${d.id === '~/.claude' ? ' disabled' : ''}>${icons.trash || '⌫'}</button>
    </div>`;
  }).join('') || `<div class="caption text-caption text-xs">${escapeHtml(I18n.t('settings.none'))}</div>`;
}

async function addHistDirPath(v) {
  v = (v || '').trim();
  if (!v) return;
  const dirs = (state.config.historyDirs || []).slice();
  if (!dirs.includes(v)) dirs.push(v);
  await persist({ historyDirs: dirs });
}

async function pickHistDir() {
  if (!api.historyPickDir) return;
  let res; try { res = await api.historyPickDir(); } catch (_) { return; }
  if (!res || res.canceled || !res.path) return;
  await addHistDirPath(res.path);
}

export function bindDataPane() {
  // History directories — primary action opens a native picker (hidden dirs shown)
  $('btnPickHistDir').addEventListener('click', pickHistDir);
  $('histDirList').addEventListener('click', async (e) => {
    const btn = e.target.closest('[data-del-dir]');
    if (!btn || btn.disabled) return;
    const id = btn.dataset.delDir;
    if (id === '~/.claude') return;
    const dirs = (state.config.historyDirs || []).filter((d) => d !== id);
    await persist({ historyDirs: dirs.length ? dirs : ['~/.claude'] });
  });
}
