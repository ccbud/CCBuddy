/* Floating toasts + the styled confirm dialog (window.confirm never shows in a Tauri webview). */
import { escapeHtml } from './dom.js';
import { I18n } from './i18n.js';

// Floating toast — sits above modals/drawers (z above everything) so a result is never
// hidden by a scrolled-out container. type: 'ok' | 'err' | 'pending'. Click to dismiss.
// Uses inline styles (not Tailwind utilities) so it renders correctly regardless of the
// compiled CSS state.
function ensureToastHost() {
  let host = document.getElementById('toastHost');
  if (!host) {
    host = document.createElement('div');
    host.id = 'toastHost';
    host.setAttribute('role', 'status');
    host.setAttribute('aria-live', 'polite');
    host.setAttribute('aria-atomic', 'false');
    host.setAttribute('aria-relevant', 'additions text');
    // Toast text can carry backend error strings (paths, upstream URLs) — keep it out of Clarity replays.
    host.setAttribute('data-clarity-mask', 'true');
    host.style.cssText = 'position:fixed;top:20px;left:50%;transform:translateX(-50%);z-index:9999;display:flex;flex-direction:column;align-items:center;gap:8px;pointer-events:none;';
    document.body.appendChild(host);
  }
  return host;
}

export function showToast(text, type, opts) {
  opts = opts || {};
  const host = ensureToastHost();
  const bg = type === 'ok' ? 'var(--green)' : type === 'err' ? 'var(--red)' : 'var(--primary)';
  const el = document.createElement('button');
  el.type = 'button';
  el.style.cssText = `pointer-events:auto;max-width:min(520px,90vw);padding:10px 16px;border:0;border-radius:10px;background:${bg};color:#fff;font-family:inherit;font-size:13px;font-weight:600;line-height:1.5;text-align:left;word-break:break-word;cursor:pointer;box-shadow:0 8px 28px rgba(17,24,39,0.22);animation:panelIn 0.18s cubic-bezier(0.23,1,0.32,1);`;
  el.textContent = text;
  const dismiss = () => {
    if (el._gone) return;
    el._gone = true;
    clearTimeout(el._t);
    el.style.transition = 'opacity 0.18s ease, transform 0.18s ease';
    el.style.opacity = '0';
    el.style.transform = 'translateY(-6px)';
    setTimeout(() => el.remove(), 180);
  };
  el.addEventListener('click', dismiss);
  el.dismiss = dismiss;
  host.appendChild(el);
  // pending toasts stay until explicitly replaced; results auto-dismiss (errors linger longer).
  const ttl = opts.ttl != null ? opts.ttl : (type === 'pending' ? 0 : type === 'err' ? 6000 : 3500);
  if (ttl) el._t = setTimeout(dismiss, ttl);
  return el;
}

// Lightweight styled confirm dialog → Promise<boolean>. For actions that are easy to mis-trigger.
export function confirmDialog({ title, message, confirmText, cancelText, danger }) {
  return new Promise((resolve) => {
    const ov = document.createElement('div');
    ov.className = 'overlay fixed inset-0 bg-black/35 flex items-center justify-center z-[200] backdrop-blur-md';
    ov.innerHTML = `<div class="bg-bg-elev border border-border-custom rounded-[14px] shadow-card-hover w-[348px] max-w-[88vw] p-5 flex flex-col gap-2.5" style="animation:panelIn 0.18s cubic-bezier(0.23,1,0.32,1)">
      <h3 class="text-[14px] font-semibold text-fg tracking-tight">${escapeHtml(title || '')}</h3>
      <p class="text-[12.5px] text-caption leading-[1.55]">${escapeHtml(message || '')}</p>
      <div class="flex justify-end gap-2 mt-2">
        <button class="cd-cancel bg-bg-elev text-fg border border-border-custom rounded-md px-3.5 py-1.5 text-[12px] font-medium cursor-pointer transition-all duration-140 hover:bg-chip-bg hover:border-border-strong active:scale-[0.97]">${escapeHtml(cancelText || I18n.t('modal.cancel'))}</button>
        <button class="cd-ok border-none rounded-md px-3.5 py-1.5 text-[12px] font-semibold text-white cursor-pointer transition-all duration-140 active:scale-[0.97] ${danger ? 'bg-red' : 'bg-primary hover:bg-primary-hover'}">${escapeHtml(confirmText || I18n.t('modal.cancel'))}</button>
      </div>
    </div>`;
    document.body.appendChild(ov);
    const done = (v) => { document.removeEventListener('keydown', onKey); ov.remove(); resolve(v); };
    const onKey = (e) => { if (e.key === 'Escape') { e.preventDefault(); done(false); } else if (e.key === 'Enter') { e.preventDefault(); done(true); } };
    ov.querySelector('.cd-ok').addEventListener('click', () => done(true));
    ov.querySelector('.cd-cancel').addEventListener('click', () => done(false));
    ov.addEventListener('mousedown', (e) => { if (e.target === ov) done(false); });
    document.addEventListener('keydown', onKey);
    setTimeout(() => { const b = ov.querySelector('.cd-ok'); if (b) b.focus(); }, 0);
  });
}
// Compat global (the conversations view historically reached it via window.confirmDialog).
window.confirmDialog = confirmDialog;
