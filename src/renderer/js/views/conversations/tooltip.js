/*
 * Lightweight hover tooltip for truncated fields (overview stats, session titles, project names).
 * Shows the FULL value instantly in an app-styled bubble — replaces the slow, system-default native
 * `title` tooltip on these. Any element carrying a [data-tip] attribute gets it; event-delegated on
 * document so it keeps working across the list's frequent re-renders.
 */
let tipEl = null, cur = null;

function place(el) {
  const txt = el.getAttribute('data-tip');
  if (!txt) return;
  // body-level, so outside the Clarity-masked conversations section — mask it
  // explicitly: it renders session titles and project paths.
  if (!tipEl) {
    tipEl = document.createElement('div');
    tipEl.className = 'cc-tip';
    tipEl.setAttribute('data-clarity-mask', 'true');
    document.body.appendChild(tipEl);
  }
  tipEl.textContent = txt;
  tipEl.classList.add('show');
  const r = el.getBoundingClientRect();
  const tw = tipEl.offsetWidth, th = tipEl.offsetHeight;
  const left = Math.max(6, Math.min(r.left + r.width / 2 - tw / 2, window.innerWidth - tw - 6));
  let top = r.top - th - 7;                 // prefer above the field
  if (top < 6) top = r.bottom + 7;          // flip below when there's no room
  tipEl.style.left = left + 'px';
  tipEl.style.top = top + 'px';
}

function hide() { cur = null; if (tipEl) tipEl.classList.remove('show'); }

// Only show the tooltip when the field is actually clipped (has the ellipsis); a fully-visible
// value like "glm-5.2" or "HEAD" needs no bubble.
const clipped = (el) => el.scrollWidth > el.clientWidth + 1;

export function initTooltips() {
  document.addEventListener('mouseover', (e) => {
    const el = e.target.closest && e.target.closest('[data-tip]');
    if (el === cur) return;
    cur = el || null;
    if (el && el.getAttribute('data-tip') && clipped(el)) place(el); else hide();
  });
  document.addEventListener('mouseout', (e) => {
    const el = e.target.closest && e.target.closest('[data-tip]');
    if (el && !el.contains(e.relatedTarget)) hide();
  });
  document.addEventListener('scroll', hide, true);
  window.addEventListener('blur', hide);
}
