/* Panel geometry: drag-to-resize the left/right rails and collapse them (persisted). */
import { $ } from '../../core/dom.js';
import { icons } from '../../core/icons.js';

// Drag-to-resize the left/right panels (middle absorbs the rest). Widths persist; collapse wins via CSS.
export function initConvResizers() {
  const layout = document.querySelector('.conv-layout');
  const sidebar = document.querySelector('.conv-sidebar');
  const nav = document.querySelector('.conv-nav');
  if (!layout || !sidebar || !nav) return;
  const MIN_LEFT = 200, MIN_RIGHT = 180, MIN_MAIN = 320; // MIN_MAIN keeps the middle usable, not a fixed width
  const num = (v, d) => { const n = parseInt(v, 10); return isFinite(n) ? n : d; };
  let leftW = num(localStorage.getItem('ccbud-conv-leftw'), 248);
  let rightW = num(localStorage.getItem('ccbud-conv-rightw'), 220);
  const apply = () => { sidebar.style.setProperty('--conv-left-w', leftW + 'px'); nav.style.setProperty('--conv-right-w', rightW + 'px'); };
  apply();
  const startDrag = (side, handle, e) => {
    e.preventDefault();
    const total = layout.getBoundingClientRect().width;
    const startX = e.clientX, sL = leftW, sR = rightW;
    layout.classList.add('resizing'); handle.classList.add('dragging');
    const onMove = (ev) => {
      const dx = ev.clientX - startX;
      if (side === 'left') leftW = Math.max(MIN_LEFT, Math.min(total - rightW - MIN_MAIN, sL + dx));
      else rightW = Math.max(MIN_RIGHT, Math.min(total - leftW - MIN_MAIN, sR - dx));
      apply();
    };
    const onUp = () => {
      document.removeEventListener('mousemove', onMove); document.removeEventListener('mouseup', onUp);
      layout.classList.remove('resizing'); handle.classList.remove('dragging');
      try { localStorage.setItem('ccbud-conv-leftw', String(leftW)); localStorage.setItem('ccbud-conv-rightw', String(rightW)); } catch (_) {}
    };
    document.addEventListener('mousemove', onMove); document.addEventListener('mouseup', onUp);
  };
  layout.querySelectorAll('.conv-resizer').forEach((r) => r.addEventListener('mousedown', (e) => startDrag(r.dataset.resize, r, e)));
}

// Left sidebar: ‹ when expanded (collapse leftward), › when collapsed (expand rightward).
const setChevron = (btn, isCol) => {
  const icon = btn && btn.querySelector('[data-icon]');
  if (icon) icon.innerHTML = isCol ? (icons.chevronRight || '›') : (icons.chevronLeft || '‹');
};
// Right nav is the mirror image: › when expanded (collapse rightward), ‹ when collapsed.
const setChevronNav = (btn, isCol) => {
  const icon = btn && btn.querySelector('[data-icon]');
  if (icon) icon.innerHTML = isCol ? (icons.chevronLeft || '‹') : (icons.chevronRight || '›');
};

/** Collapse toggles for the conversation list sidebar and the right nav panel. */
export function initConvCollapse() {
  const convSidebar = document.querySelector('.conv-sidebar');
  const collapseListBtn = $('btnCollapseConvList');
  if (collapseListBtn && convSidebar) {
    try { if (localStorage.getItem('ccbud-convlist-collapsed') === '1') { convSidebar.classList.add('collapsed'); setChevron(collapseListBtn, true); } } catch (_) {}
    collapseListBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      const isCol = convSidebar.classList.toggle('collapsed');
      setChevron(collapseListBtn, isCol);
      try { localStorage.setItem('ccbud-convlist-collapsed', isCol ? '1' : '0'); } catch (_) {}
    });
  }

  const convNav = document.querySelector('.conv-nav');
  const collapseNavBtn = $('btnCollapseConvNav');
  if (collapseNavBtn && convNav) {
    setChevronNav(collapseNavBtn, false); // default expanded → › (collapse rightward)
    try { if (localStorage.getItem('ccbud-convnav-collapsed') === '1') { convNav.classList.add('collapsed'); setChevronNav(collapseNavBtn, true); } } catch (_) {}
    collapseNavBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      const isCol = convNav.classList.toggle('collapsed');
      setChevronNav(collapseNavBtn, isCol);
      try { localStorage.setItem('ccbud-convnav-collapsed', isCol ? '1' : '0'); } catch (_) {}
    });
  }
}
