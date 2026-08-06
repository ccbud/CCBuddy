/* Provider add/edit modal — template, open/close, form collection, preset + protocol controls. */
import { $, escapeHtml, injectIcons } from '../../core/dom.js';
import { I18n } from '../../core/i18n.js';
import { onConfigReplaced } from '../../core/state.js';
import { PRESETS, PRESET_LABELS } from './presets.js';
import { renderProviderIcon } from './icon.js';
import { openIconPicker } from './icon-picker.js';
import { MODAL_HTML } from './modal-template.js';

let editingId = null;
let modalIcon = null; // the icon being edited in the add/edit modal (emoji or image data-URL)
export const getModalIcon = () => modalIcon;
export const setModalIcon = (v) => { modalIcon = v; updateIconPreview(); };

/** Inject the modal DOM on first use (it's not part of the startup HTML). */
function ensureModal() {
  if ($('modal')) return;
  document.body.insertAdjacentHTML('beforeend', MODAL_HTML);
  I18n.apply($('modal'));
  injectIcons($('modal'));
  renderPresetGrid();
  bindModal();
}

function renderPresetGrid() {
  const grid = $('presetGrid');
  grid.innerHTML = '';
  Object.keys(PRESET_LABELS).forEach((key) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'preset-chip bg-bg-input border border-border-custom rounded-full px-3 py-[4.5px] text-[12px] font-medium text-fg cursor-pointer transition-all duration-140 hover:border-brand hover:text-brand active:scale-[0.97]';
    b.dataset.preset = key;
    b.textContent = key === 'custom' ? I18n.t('preset.custom') : PRESET_LABELS[key];
    grid.appendChild(b);
  });
}

function selectPreset(key) {
  document.querySelectorAll('.preset-chip').forEach((c) => c.classList.toggle('selected', c.dataset.preset === key));
  const p = PRESETS[key] || PRESETS.custom;
  $('fName').value = p.name; $('fBaseUrl').value = p.baseUrl; $('fDefaultModel').value = p.defaultModel; $('fSmallModel').value = p.smallFastModel;
  setProtocol(p.protocol || 'anthropic'); // preset declares its wire protocol up front
  modalIcon = null; // a preset uses its brand logo
  updateIconPreview();
  if (key !== 'custom') $('fToken').focus();
}

// Segmented protocol control: get/set the selected wire protocol.
function getProtocol() {
  const g = $('fProtocol'); if (!g) return 'anthropic';
  const b = g.querySelector('.proto-seg-btn.selected');
  return (b && b.dataset.proto) || 'anthropic';
}
function setProtocol(v) {
  const g = $('fProtocol'); if (!g) return;
  v = v || 'anthropic';
  g.querySelectorAll('.proto-seg-btn').forEach((b) => b.classList.toggle('selected', b.dataset.proto === v));
  syncProtocolHint();
}
// Reflect the chosen protocol as a prominent status line so the user always knows whether their
// requests pass through directly (Anthropic) or get auto-translated (OpenAI Chat / Responses).
function syncProtocolHint() {
  const badge = $('protoBadge');
  if (!badge) return;
  const v = getProtocol();
  const map = {
    'anthropic': { k: 'modal.protoBadgeDirect', cls: 'proto-badge-direct' },
    'openai-chat': { k: 'modal.protoBadgeXlate', cls: 'proto-badge-xlate' },
    'openai-responses': { k: 'modal.protoBadgeXlate', cls: 'proto-badge-xlate' },
  };
  const m = map[v] || map['anthropic'];
  badge.className = 'proto-badge ' + m.cls;
  badge.textContent = I18n.t(m.k);
}

function updateIconPreview() {
  const el = $('fIconPreview');
  const iconData = renderProviderIcon($('fName').value || '?', modalIcon);
  el.setAttribute('style', iconData.style);
  el.innerHTML = iconData.html;
}

function addMapRow(alias = '', upstream = '') {
  const row = document.createElement('div');
  row.className = 'map-row flex items-center gap-1.75';
  const mapInputCls = 'flex-1 min-w-0 bg-bg-input border border-border-custom rounded-md px-2 py-1.5 text-fg font-mono text-[12px] outline-none transition-colors duration-120 focus:border-primary';
  row.innerHTML = `
    <input class="m-alias ${mapInputCls}" placeholder="${escapeHtml(I18n.t('modal.aliasPlaceholder'))}" />
    <span class="map-arrow text-caption shrink-0">→</span>
    <input class="m-upstream ${mapInputCls}" placeholder="${escapeHtml(I18n.t('modal.upstreamPlaceholder'))}" />
    <button class="icon-btn m-del w-6 h-6 p-0 shrink-0 flex items-center justify-center border-0 rounded-md bg-transparent text-muted cursor-pointer transition-colors duration-140 hover:bg-red-soft hover:text-red" type="button">✕</button>`;
  row.querySelector('.m-alias').value = alias;
  row.querySelector('.m-upstream').value = upstream;
  row.querySelector('.m-del').addEventListener('click', () => row.remove());
  $('mapRows').appendChild(row);
}

export function openModal(provider) {
  ensureModal();
  editingId = provider ? provider.id : null;
  modalIcon = provider ? (provider.icon || null) : null;
  $('modalTitle').textContent = provider ? I18n.t('modal.editTitle') : I18n.t('modal.addTitle');
  document.querySelectorAll('.preset-chip').forEach((c) => c.classList.remove('selected'));
  $('fName').value = provider ? provider.name : '';
  $('fBaseUrl').value = provider ? provider.baseUrl : '';
  $('fToken').value = provider ? provider.authToken : '';
  $('fToken').type = 'password'; $('fTokenToggle').textContent = I18n.t('modal.show');
  $('fDefaultModel').value = provider ? provider.defaultModel : '';
  $('fSmallModel').value = provider ? provider.smallFastModel : '';
  $('fMapDefault').checked = provider ? provider.mapDefaultModels !== false : true;
  setProtocol((provider && provider.protocol) || 'anthropic');
  $('mapRows').innerHTML = '';
  if (provider && provider.models) provider.models.forEach((m) => addMapRow(m.alias, m.upstream));
  if (!$('mapRows').children.length) addMapRow(); // always show one empty row to add into
  const mapDetails = $('mapRows').closest('details');
  if (mapDetails) mapDetails.open = true;
  updateIconPreview();
  $('modal').classList.remove('hidden');
  $('fName').focus();
}
export function closeModal() { if ($('modal')) $('modal').classList.add('hidden'); editingId = null; }

export function collectProvider() {
  const models = [];
  $('mapRows').querySelectorAll('.map-row').forEach((row) => {
    const alias = row.querySelector('.m-alias').value.trim();
    const upstream = row.querySelector('.m-upstream').value.trim();
    if (alias || upstream) models.push({ alias, upstream });
  });
  const p = {
    name: $('fName').value.trim() || I18n.t('providers.unnamed'),
    baseUrl: $('fBaseUrl').value.trim(),
    authToken: $('fToken').value.trim(),
    defaultModel: $('fDefaultModel').value.trim(),
    smallFastModel: $('fSmallModel').value.trim(),
    mapDefaultModels: $('fMapDefault').checked,
    protocol: getProtocol(),
    models,
  };
  if (modalIcon) p.icon = modalIcon;
  if (editingId) p.id = editingId;
  return p;
}

let onSave = null, onTest = null;
/** The providers view injects save/test behavior so the modal stays UI-only. */
export function setModalHandlers(handlers) { onSave = handlers.onSave; onTest = handlers.onTest; }

function bindModal() {
  $('modalClose').addEventListener('click', closeModal);
  $('btnCancel').addEventListener('click', closeModal);
  $('presetGrid').addEventListener('click', (e) => { if (e.target.dataset.preset) selectPreset(e.target.dataset.preset); });
  const fp = $('fProtocol');
  if (fp) fp.addEventListener('click', (e) => { const b = e.target.closest('.proto-seg-btn'); if (b) setProtocol(b.dataset.proto); });
  $('fName').addEventListener('input', updateIconPreview);
  const fIconPreview = $('fIconPreview');
  if (fIconPreview && fIconPreview.parentElement) {
    fIconPreview.parentElement.addEventListener('click', () => openIconPicker(fIconPreview, setModalIcon));
  }
  $('btnAddMap').addEventListener('click', () => addMapRow());
  $('fTokenToggle').addEventListener('click', () => {
    const f = $('fToken'); const show = f.type === 'password';
    f.type = show ? 'text' : 'password'; $('fTokenToggle').textContent = show ? I18n.t('modal.hide') : I18n.t('modal.show');
  });
  $('btnSave').addEventListener('click', () => { if (onSave) onSave(); });
  $('btnTest').addEventListener('click', () => { if (onTest) onTest(); });
}

// A backend config push while the modal edits a provider: if the baseUrl input still shows the
// pre-push value (e.g. the /v1 auto-migration fired during a connection test), sync it in place.
onConfigReplaced((prev, next) => {
  if (!editingId) return;
  const previousProvider = prev.providers && prev.providers.find((p) => p.id === editingId);
  const baseUrlInput = $('fBaseUrl');
  if (!previousProvider || !baseUrlInput) return;
  if (baseUrlInput.value === (previousProvider.baseUrl || '')) {
    const updatedProvider = next.providers.find((p) => p.id === editingId);
    if (updatedProvider) baseUrlInput.value = updatedProvider.baseUrl || '';
  }
});
