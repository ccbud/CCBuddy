/* Drag-to-reorder for the provider list. */
import { $ } from '../../core/dom.js';
import { state, persist } from '../../core/state.js';

let dragId = null;

export function wireDrag() {
  const list = $('providerList');
  list.addEventListener('dragstart', (e) => {
    const card = e.target.closest('.provider'); if (!card) return;
    dragId = card.dataset.id; card.classList.add('dragging');
  });
  list.addEventListener('dragend', (e) => {
    const card = e.target.closest('.provider'); if (card) card.classList.remove('dragging');
    document.querySelectorAll('.provider.drag-over').forEach((c) => c.classList.remove('drag-over'));
  });
  list.addEventListener('dragover', (e) => {
    e.preventDefault();
    const card = e.target.closest('.provider');
    document.querySelectorAll('.provider.drag-over').forEach((c) => c.classList.remove('drag-over'));
    if (card && card.dataset.id !== dragId) card.classList.add('drag-over');
  });
  list.addEventListener('drop', async (e) => {
    e.preventDefault();
    const card = e.target.closest('.provider');
    if (!card || !dragId || card.dataset.id === dragId) return;
    const ids = state.config.providers.map((p) => p.id);
    const from = ids.indexOf(dragId), to = ids.indexOf(card.dataset.id);
    if (from < 0 || to < 0) return;
    const reordered = state.config.providers.slice();
    const [moved] = reordered.splice(from, 1);
    reordered.splice(to, 0, moved);
    await persist({ providers: reordered });
  });
}
