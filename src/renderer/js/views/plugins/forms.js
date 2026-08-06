/* 插件 — declared-action form modal, built entirely from the plugin's field specs. */
import { escapeHtml } from '../../core/dom.js';
import { api } from '../../core/bridge.js';
import { I18n } from '../../core/i18n.js';
import { showToast } from '../../core/toast.js';

// Build one form control from a field spec. Recognized types: text (default),
// number, password, textarea, select, checkbox.
function pluginFieldControl(f, val) {
  const key = escapeHtml(f.key);
  const cls = 'bg-bg-input border border-border-custom rounded-[7px] px-2.75 py-2 text-fg text-[13px] w-full outline-none transition-colors duration-120 focus:border-primary';
  const v = (val != null ? val : (f.default != null ? f.default : ''));
  if (f.type === 'select') {
    const opts = (Array.isArray(f.options) ? f.options : []).map((o) => {
      const ov = (o && typeof o === 'object') ? o.value : o;
      const ol = (o && typeof o === 'object') ? (o.label != null ? o.label : o.value) : o;
      const sel = String(ov) === String(v) ? ' selected' : '';
      return `<option value="${escapeHtml(String(ov))}"${sel}>${escapeHtml(String(ol))}</option>`;
    }).join('');
    return `<select data-field-key="${key}" class="${cls}">${opts}</select>`;
  }
  if (f.type === 'checkbox') {
    const on = v === true || v === 1 || v === '1' || String(v).toLowerCase() === 'true';
    return `<input type="checkbox" data-field-key="${key}" ${on ? 'checked' : ''} class="w-4 h-4 accent-brand self-start" />`;
  }
  if (f.type === 'textarea') {
    return `<textarea data-field-key="${key}" rows="3" class="${cls}" placeholder="${escapeHtml(f.placeholder || '')}">${escapeHtml(String(v))}</textarea>`;
  }
  const type = (f.type === 'number' || f.type === 'password') ? f.type : 'text';
  const mono = type === 'text' || type === 'number' ? ' font-mono' : '';
  const minmax = f.type === 'number'
    ? `${f.min != null ? ` min="${escapeHtml(String(f.min))}"` : ''}${f.max != null ? ` max="${escapeHtml(String(f.max))}"` : ''}`
    : '';
  return `<input type="${type}" data-field-key="${key}" value="${escapeHtml(String(v))}" placeholder="${escapeHtml(f.placeholder || '')}"${minmax} class="${cls}${mono}" />`;
}

// Read the form back into a values object, coercing/validating by field type.
// Returns null (and focuses the offending control) if a required/number check fails.
function collectPluginFormValues(root, fields) {
  const out = {};
  for (const f of fields) {
    const sel = (window.CSS && CSS.escape) ? CSS.escape(f.key) : f.key;
    const el = root.querySelector(`[data-field-key="${sel}"]`);
    if (!el) continue;
    let v = f.type === 'checkbox' ? !!el.checked : el.value;
    if (f.type === 'number') {
      if (v === '' || v == null) {
        v = null;
      } else {
        const n = Number(v);
        if (Number.isNaN(n)) { el.focus(); return null; }
        v = n;
      }
    }
    if (f.required && f.type !== 'checkbox' && (v === '' || v == null)) { el.focus(); return null; }
    out[f.key] = v;
  }
  return out;
}

// Open a modal built from a plugin action's field specs; prefill from the plugin,
// then POST the collected values back through the host.
export async function openPluginActionForm(pid, action, reload) {
  const fields = Array.isArray(action.fields) ? action.fields : [];
  let values = {};
  if (action.loadOnOpen !== false) {
    try { const r = await api.pluginActionLoad(pid, action.id); if (r && r.values) values = r.values; }
    catch (err) { showToast(I18n.t('plugins.actionLoadFailed', { msg: (err && err.message) || err }), 'err'); }
  }
  const prev = document.getElementById('pluginActionModal'); if (prev) prev.remove();
  const ov = document.createElement('div');
  ov.id = 'pluginActionModal';
  ov.className = 'overlay fixed inset-0 bg-black/28 flex items-center justify-center z-[130] backdrop-blur-md';
  const rows = fields.map((f) => `
        <label class="field flex flex-col gap-1.25">
          <span class="field-label text-[11px] font-semibold text-caption uppercase tracking-[0.03em]">${escapeHtml(f.label || f.key)}</span>
          ${pluginFieldControl(f, values[f.key])}
          ${f.help ? `<span class="text-[11px] text-caption leading-[1.4]">${escapeHtml(f.help)}</span>` : ''}
        </label>`).join('');
  ov.innerHTML = `
    <div class="sheet w-[460px] max-w-[92vw] bg-bg-elev backdrop-blur-[40px] border border-window-border rounded-2xl shadow-[0_24px_64px_rgba(0,0,0,0.18)] flex flex-col">
      <header class="flex items-center gap-2 p-[14px_18px] border-b border-border-custom">
        <h3 class="text-[14px] font-semibold tracking-tight">${escapeHtml(action.label || action.id)}</h3>
      </header>
      <div class="p-[18px_20px] flex flex-col gap-3">
        ${rows}
        <div class="flex justify-end gap-2 mt-1">
          <button data-act="cancel" class="btn bg-bg-elev text-muted border border-border-custom rounded-md px-3 py-2 font-medium text-[12px] leading-none cursor-pointer hover:bg-chip-bg hover:text-fg">${escapeHtml(I18n.t('plugins.cancel'))}</button>
          <button data-act="submit" class="btn bg-brand text-white border-none rounded-md px-3.5 py-2 font-semibold text-[12px] leading-none cursor-pointer hover:opacity-90 active:scale-[0.985]">${escapeHtml(action.submitLabel || I18n.t('plugins.save'))}</button>
        </div>
      </div>
    </div>`;
  document.body.appendChild(ov);
  const close = () => ov.remove();
  ov.addEventListener('click', (e) => { if (e.target === ov) close(); });
  ov.querySelector('[data-act="cancel"]').addEventListener('click', close);
  ov.querySelector('[data-act="submit"]').addEventListener('click', async () => {
    const vals = collectPluginFormValues(ov, fields);
    if (vals == null) return;
    const submitBtn = ov.querySelector('[data-act="submit"]');
    submitBtn.disabled = true;
    try {
      const r = await api.pluginAction(pid, action.id, vals);
      showToast((r && r.message) || I18n.t('plugins.actionDone'), 'ok');
      close();
      await reload();
    } catch (err) {
      submitBtn.disabled = false;
      showToast(I18n.t('plugins.actionFailed', { msg: (err && err.message) || err }), 'err');
    }
  });
}
