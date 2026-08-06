/* Emoji / image icon picker popover for the provider modal. */
import { escapeHtml } from '../../core/dom.js';
import { I18n } from '../../core/i18n.js';
import { ICON_EMOJIS } from './icon.js';

function resizeImage(file, size) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const img = new Image();
      img.onload = () => {
        try {
          const c = document.createElement('canvas'); c.width = size; c.height = size;
          const ctx = c.getContext('2d');
          const s = Math.min(img.width, img.height);
          ctx.drawImage(img, (img.width - s) / 2, (img.height - s) / 2, s, s, 0, 0, size, size);
          resolve(c.toDataURL('image/png'));
        } catch (e) { reject(e); }
      };
      img.onerror = reject;
      img.src = reader.result;
    };
    reader.onerror = reject;
    reader.readAsDataURL(file);
  });
}

/** Open the picker anchored to `anchor`; `setIcon(value|null)` receives the choice. */
export function openIconPicker(anchor, setIcon) {
  const existing = document.querySelector('.icon-picker');
  if (existing) { existing.remove(); return; }
  const pop = document.createElement('div');
  pop.className = 'icon-picker';
  pop.innerHTML =
    `<div class="ip-grid">${ICON_EMOJIS.map((e) => `<button type="button" class="ip-emoji" data-emoji="${escapeHtml(e)}">${escapeHtml(e)}</button>`).join('')}</div>` +
    `<div class="ip-actions"><button type="button" class="ip-act" data-act="upload">${escapeHtml(I18n.t('modal.iconUpload'))}</button><button type="button" class="ip-act" data-act="random">${escapeHtml(I18n.t('modal.iconRandom'))}</button><button type="button" class="ip-act" data-act="reset">${escapeHtml(I18n.t('modal.iconReset'))}</button></div>` +
    `<input type="file" accept="image/*" class="ip-file" hidden />`;
  document.body.appendChild(pop);
  const r = anchor.getBoundingClientRect();
  let x = Math.max(10, Math.min(Math.round(r.left + r.width / 2 - pop.offsetWidth / 2), window.innerWidth - pop.offsetWidth - 10));
  let y = Math.round(r.bottom + 8);
  if (y + pop.offsetHeight > window.innerHeight - 10) y = Math.max(10, Math.round(r.top - pop.offsetHeight - 8));
  pop.style.left = x + 'px'; pop.style.top = y + 'px';
  const close = () => { pop.remove(); document.removeEventListener('mousedown', onDoc); document.removeEventListener('keydown', onKey); };
  const onDoc = (e) => { if (!pop.contains(e.target) && !anchor.contains(e.target)) close(); };
  const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); close(); } };
  setTimeout(() => { document.addEventListener('mousedown', onDoc); document.addEventListener('keydown', onKey); }, 0);
  pop.addEventListener('click', (e) => {
    const em = e.target.closest('.ip-emoji');
    if (em) { setIcon(em.dataset.emoji); close(); return; }
    const act = e.target.closest('.ip-act');
    if (!act) return;
    if (act.dataset.act === 'random') { setIcon(ICON_EMOJIS[Math.floor(Math.random() * ICON_EMOJIS.length)]); close(); }
    else if (act.dataset.act === 'reset') { setIcon(null); close(); }
    else if (act.dataset.act === 'upload') { pop.querySelector('.ip-file').click(); }
  });
  pop.querySelector('.ip-file').addEventListener('change', (e) => {
    const f = e.target.files && e.target.files[0];
    if (!f) return;
    resizeImage(f, 72).then((d) => { setIcon(d); close(); }).catch(() => close());
  });
}
