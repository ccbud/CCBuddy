/*
 * 会话 view — reads Claude Code's on-disk session history (~/.claude/projects) directly and
 * renders it claude-code-history-viewer style: projects → sessions tree, a rich message timeline
 * (text / thinking / per-tool cards + results / diffs / code / images), live-follow for active
 * sessions, per-session stats, and in-conversation search. Also browses the other coding CLIs'
 * stores (Codex / Grok / Copilot / Antigravity / Qoder) through the same pipeline.
 *
 * This is the heaviest view, so it is mounted lazily (registry.js) — its markup, its markdown /
 * highlight vendor bundles, and every module below stay off the cold-start path entirely.
 */
import { $, injectIcons } from '../../core/dom.js';
import { I18n } from '../../core/i18n.js';
import { cs } from './state.js';
import { CONVERSATIONS_HTML } from './template.js';
import { refreshList, renderList, renderDirSwitch } from './list.js';
import { rerenderDetail } from './detail.js';
import { syncConvNav } from './panels.js';
import { initTooltips } from './tooltip.js';
import { initConvResizers, initConvCollapse } from './layout.js';
import { bindListEvents } from './events-list.js';
import { bindDetailEvents } from './events-detail.js';
import { bindLiveFollow, bindDropImport } from './live.js';

export default {
  id: 'conversations',
  mount(host) {
    host.insertAdjacentHTML('beforeend', CONVERSATIONS_HTML);
    const section = $('view-conversations');
    I18n.apply(section);
    injectIcons(section);

    initTooltips();
    bindListEvents();
    bindDetailEvents();
    initConvResizers();
    initConvCollapse();
    syncConvNav(); // nothing selected at startup → no right rail
    bindLiveFollow();
    bindDropImport();

    // Compat surface for the language switch in Settings (and any external caller).
    window.ccbudConversations = {
      onShow() { refreshList(); if (cs.openFile) rerenderDetail(false); },
      // Re-render everything this view owns when the UI language changes.
      setLang() { renderDirSwitch(); renderList(); if (cs.openFile) rerenderDetail(true); },
    };
  },
  onShow() { refreshList(); if (cs.openFile) rerenderDetail(false); },
};
