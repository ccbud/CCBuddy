/* 服务 view — provider list + hero. The section itself ships inline in index.html
   (first-paint content); this module binds it and renders from shared state. */
import { $, escapeHtml } from '../../core/dom.js';
import { api } from '../../core/bridge.js';
import { I18n } from '../../core/i18n.js';
import { icons } from '../../core/icons.js';
import { state, onRender, renderAll } from '../../core/state.js';
import { showToast, confirmDialog } from '../../core/toast.js';
import { pushLocalLog } from '../../core/state.js';
import { renderProviderIcon, mask } from './icon.js';
import { renderHero, renderStatus, bindHero } from './hero.js';
import { openModal, closeModal, collectProvider, setModalHandlers } from './modal.js';
import { wireDrag } from './drag.js';

function renderProviders() {
  const list = $('providerList');
  list.innerHTML = '';
  $('emptyProviders').classList.toggle('hidden', state.config.providers.length > 0);
  for (const p of state.config.providers) {
    const isActive = p.id === state.config.activeProviderId;
    const el = document.createElement('div');
    el.className = 'provider group grid grid-cols-[14px_36px_1fr_minmax(72px,auto)_auto] items-center gap-3 p-2.5 pr-3.5 pl-2.5 min-h-[60px] bg-bg-elev border border-border-custom rounded-[13px] shadow-card cursor-pointer relative transition-all duration-150 hover:border-border-strong hover:shadow-card-hover hover:-translate-y-0.25 [&.active]:border-green/38 [&.active]:bg-[color-mix(in_srgb,var(--bg-elev)_90%,var(--green)_10%)] [&.dragging]:opacity-40 [&.dragging]:scale-99 [&.drag-over]:border-brand [&.drag-over]:bg-brand-soft ' + (isActive ? 'active' : '');
    el.draggable = true;
    el.dataset.id = p.id;

    const tags = [];
    if (p.defaultModel) tags.push(`<span class="tag text-[11px] font-mono bg-chip-bg rounded-[4px] px-1.5 py-0.25 text-fg whitespace-nowrap">${escapeHtml(I18n.t('providers.tagMain'))} ${escapeHtml(p.defaultModel)}</span>`);
    if (p.smallFastModel && p.smallFastModel !== p.defaultModel) tags.push(`<span class="tag text-[11px] font-mono bg-chip-bg rounded-[4px] px-1.5 py-0.25 text-fg whitespace-nowrap">${escapeHtml(I18n.t('providers.tagFast'))} ${escapeHtml(p.smallFastModel)}</span>`);
    for (const m of p.models || []) tags.push(`<span class="tag map text-[11px] font-mono bg-brand-soft rounded-[4px] px-1.5 py-0.25 text-brand font-medium whitespace-nowrap" title="${escapeHtml(m.alias)} → ${escapeHtml(m.upstream)}">${escapeHtml(m.alias)} → ${escapeHtml(m.upstream)}</span>`);

    const iconData = renderProviderIcon(p.name, p.icon);
    // Protocol badge so the wire protocol (and whether requests are translated) is visible at a
    // glance on every provider. Anthropic (passthrough) is the quiet default; the translated ones
    // stand out.
    const proto = p.protocol || 'anthropic';
    const protoMeta = proto === 'openai-chat'
      ? { label: 'OpenAI Chat', cls: 'proto-badge-xlate' }
      : proto === 'openai-responses'
        ? { label: 'OpenAI Responses', cls: 'proto-badge-xlate' }
        : { label: 'Anthropic', cls: 'proto-badge-direct' };
    const protoBadge = `<span class="proto-badge ${protoMeta.cls}" title="${escapeHtml(I18n.t('providers.protocolTip'))}">${escapeHtml(protoMeta.label)}</span>`;
    el.innerHTML = `
      <span class="grip text-caption cursor-grab text-[12px] opacity-30 leading-none select-none group-hover:opacity-65 transition-opacity duration-150" title="${escapeHtml(I18n.t('providers.reorder'))}">⠿</span>
      <div class="prov-icon w-9 h-9 rounded-[9px] shrink-0 flex items-center justify-center text-white font-bold text-[13px] tracking-tight shadow-sm" style="${iconData.style}">${iconData.html}</div>
      <div class="pinfo min-w-0">
        <div class="pname flex items-center gap-1.5 font-semibold text-[14.5px] tracking-tight text-fg">${escapeHtml(p.name)} ${protoBadge} ${isActive ? '<span class="badge-active text-[10.5px] font-semibold text-green bg-green-soft rounded-full px-1.75 py-0.25">' + escapeHtml(I18n.t('providers.active')) + '</span>' : ''}</div>
        <div class="pmeta mt-0.5 text-xs font-mono text-caption truncate" data-clarity-mask="true">${escapeHtml(mask(p.authToken))} · ${escapeHtml(p.baseUrl.replace(/^https?:\/\//, ''))}</div>
      </div>
      <div class="pmodels flex gap-1 flex-wrap justify-end max-w-[340px]">${tags.join('') || '<span class="caption text-caption text-xs">—</span>'}</div>
      <div class="pactions flex gap-0.25">
        <button class="w-6.5 h-6.5 border-0 rounded-[6px] bg-transparent text-muted cursor-pointer flex items-center justify-center transition-all duration-100 hover:bg-chip-bg hover:text-fg" title="${escapeHtml(I18n.t('providers.test'))}" data-test="${p.id}">${icons.refresh || '↻'}</button>
        <button class="w-6.5 h-6.5 border-0 rounded-[6px] bg-transparent text-muted cursor-pointer flex items-center justify-center transition-all duration-100 hover:bg-chip-bg hover:text-fg" title="${escapeHtml(I18n.t('providers.edit'))}" data-edit="${p.id}">${icons.edit || '✎'}</button>
        <button class="w-6.5 h-6.5 border-0 rounded-[6px] bg-transparent text-muted cursor-pointer flex items-center justify-center transition-all duration-100 hover:bg-red-soft hover:text-red danger" title="${escapeHtml(I18n.t('providers.delete'))}" data-del="${p.id}">${icons.trash || '⌫'}</button>
      </div>`;
    list.appendChild(el);
  }
}

async function onListClick(e) {
  // Resolve the actual button (the click may land on the inner SVG icon).
  const btn = e.target.closest('button');
  if (btn && btn.dataset.edit) { openModal(state.config.providers.find((p) => p.id === btn.dataset.edit)); return; }
  if (btn && btn.dataset.del) {
    // Not window.confirm: the Tauri webview never shows it (silent no-op on macOS).
    const ok = await confirmDialog({
      title: I18n.t('providers.delete'),
      message: I18n.t('providers.confirmDelete'),
      confirmText: I18n.t('providers.delete'),
      danger: true,
    });
    if (ok) { state.config = await api.deleteProvider(btn.dataset.del); renderAll(); }
    return;
  }
  if (btn && btn.dataset.test) {
    const p = state.config.providers.find((pp) => pp.id === btn.dataset.test);
    const orig = btn.innerHTML; // preserve the SVG icon, restore it after
    btn.innerHTML = '…'; btn.disabled = true;
    const res = await api.testProvider(p);
    btn.disabled = false; btn.innerHTML = res.ok ? '✓' : '✗';
    pushLocalLog({ level: res.ok ? 'info' : 'error', msg: I18n.t('modal.testLog', { name: p.name, msg: res.message }) });
    setTimeout(() => { btn.innerHTML = orig; }, 1800);
    return;
  }
  if (btn) return; // some other button — ignore
  // click anywhere else on the card → set it as the active service
  const card = e.target.closest('.provider');
  if (!card || !card.dataset.id) return;
  if (card.dataset.id === state.config.activeProviderId) return; // already active — nothing to switch
  // While the gateway is running, switching is easy to mis-trigger and would re-point every new
  // Claude Code session — so confirm first.
  if (state.status.running) {
    const p = state.config.providers.find((pp) => pp.id === card.dataset.id);
    const ok = await confirmDialog({
      title: I18n.t('switch.confirmTitle', { name: p ? p.name : '' }),
      message: I18n.t('switch.confirmMsg'),
      confirmText: I18n.t('switch.confirmOk'),
    });
    if (!ok) return;
  }
  try {
    state.config = await api.setActive(card.dataset.id);
  } catch (err) {
    const msg = (err && err.message) || String(err);
    showToast(msg.includes('pluginNotRunning') ? I18n.t('providers.pluginOff') : msg, 'err');
    return;
  }
  renderAll();
}

async function saveFromModal() {
  const p = collectProvider();
  if (!p.baseUrl) {
    showToast(I18n.t('modal.fillUrl'), 'err');
    return;
  }
  state.config = await api.upsertProvider(p);
  closeModal(); renderAll();
}

async function testFromModal() {
  // Surface the result as a floating toast — the in-modal alert sits at the bottom of a
  // scrollable sheet and was easily hidden, leaving users unsure whether the test ran.
  const pending = showToast(I18n.t('modal.testing'), 'pending');
  const testedProvider = collectProvider();
  const res = await api.testProvider(testedProvider);
  if (res.ok && res.baseUrl && $('fBaseUrl').value.trim() === testedProvider.baseUrl) {
    $('fBaseUrl').value = res.baseUrl;
  }
  let msg;
  if (res.reason === 'baseUrlEmpty') msg = I18n.t('err.baseUrlEmpty');
  else if (res.reason === 'baseUrlInvalid') msg = I18n.t('err.baseUrlInvalid');
  else if (res.reason === 'timeout') msg = I18n.t('err.timeout');
  else if (res.ok) msg = I18n.t('err.testOk', { model: res.model || '' });
  else msg = res.message || ('HTTP ' + (res.status || ''));
  if (pending) pending.dismiss();
  showToast((res.ok ? '✓ ' : '✗ ') + msg, res.ok ? 'ok' : 'err');
}

export default {
  id: 'providers',
  mount() {
    bindHero();
    $('btnAdd').addEventListener('click', () => openModal(null));
    const btnAddEmpty = $('btnAddEmpty');
    if (btnAddEmpty) btnAddEmpty.addEventListener('click', () => openModal(null));
    $('providerList').addEventListener('click', onListClick);
    wireDrag();
    setModalHandlers({ onSave: saveFromModal, onTest: testFromModal });
    onRender(() => { renderStatus(); renderHero(); renderProviders(); });
  },
};
