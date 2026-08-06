/* 设置 → 网关 pane: gateway service, endpoint/port/export, connect targets, advanced. */
import { $, copyFeedback } from '../../core/dom.js';
import { api } from '../../core/bridge.js';
import { I18n } from '../../core/i18n.js';
import { state, persist, refresh, pushLocalLog } from '../../core/state.js';
import { showHeroNote } from '../providers/hero.js';
import { GATEWAY_PANE_HTML } from './gateway-template.js';

export const gatewayPaneTemplate = () => GATEWAY_PANE_HTML;

// Multi-select for which coding CLIs "一键接入" wires to the gateway. Each toggle reflects
// config.connectTargets; each row's chip shows that CLI's live connected state. Codex is disabled
// (with a note) until it's installed.
function renderConnectTargets() {
  // The switch reflects the ACTUAL connection (a live on/off), not just the saved selection.
  const cc = $('fTargetClaude'), cx = $('fTargetCodex');
  if (cc) cc.checked = !!state.status.connectedClaude;
  if (cx) cx.checked = !!state.status.connectedCodex;
  const codexOk = state.status.codexAvailable !== false;
  const row = $('targetCodexRow'), note = $('targetCodexNote');
  if (cx) cx.disabled = !codexOk;
  if (row) row.style.opacity = codexOk ? '1' : '0.55';
  if (note) note.style.display = codexOk ? 'none' : '';
  const chip = (el, on) => { if (!el) return; el.className = 'proto-badge ' + (on ? 'proto-badge-xlate' : 'proto-badge-direct'); el.textContent = I18n.t(on ? 'settings.targetOn' : 'settings.targetOff'); };
  chip($('tgtClaudeChip'), !!state.status.connectedClaude);
  chip($('tgtCodexChip'), !!state.status.connectedCodex);
}

// Live per-CLI switch: flipping a target immediately connects/disconnects that CLI (and starts or
// stops the gateway as needed), so unchecking Claude Code actually turns it off.
async function toggleTarget(target, on) {
  if (!api.setConnectTarget) return;
  let res;
  try { res = await api.setConnectTarget(target, on); } catch (_) { res = null; }
  if (res && res.ok === false) {
    // couldn't turn on (no provider / port) → revert the switch + surface the reason
    const msg = res.reason === 'noProvider' ? I18n.t('err.noProvider') : (res.message || I18n.t('err.opFailed'));
    try { showHeroNote(msg, true); } catch (_) {}
    const el = target === 'codex' ? $('fTargetCodex') : $('fTargetClaude');
    if (el) el.checked = !on;
    return;
  }
  await refresh();
}

export function renderGatewayPane() {
  const port = (state.status.running && state.status.port) || state.config.port;
  $('endpoint').textContent = `http://localhost:${port}`;
  $('portInput').value = state.config.port;
  const token = state.config.requireToken && state.config.gatewayToken ? state.config.gatewayToken : 'ccbud-local';
  $('exportBlock').textContent = [
    `export ANTHROPIC_BASE_URL=http://localhost:${port}`,
    `export ANTHROPIC_AUTH_TOKEN=${token}`,
    '',
    I18n.t('settings.exportHint'),
  ].join('\n');
  $('claudePath').textContent = state.status.claudePath ? I18n.t('settings.claudePath') + state.status.claudePath : '';
  if ($('fGatewayEnabled')) $('fGatewayEnabled').checked = state.status.gatewayEnabled !== false;
  if ($('fRetry429')) $('fRetry429').checked = !(state.config.retry429 && state.config.retry429.enabled === false);
  if ($('fInsecureTls')) $('fInsecureTls').checked = !!state.config.insecureSkipVerify;
  renderConnectTargets();
  const se = $('startError');
  if (state.status.lastStartError) { se.textContent = state.status.lastStartError; se.classList.remove('hidden'); }
  else se.classList.add('hidden');
}

export function bindGatewayPane() {
  $('portInput').addEventListener('change', async (e) => {
    const port = Number(e.target.value);
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      e.target.value = state.config.port;
      pushLocalLog({ level: 'error', msg: I18n.t('err.portInvalid') });
      return;
    }
    await persist({ port });
  });
  $('btnCopyExport').addEventListener('click', (e) => copyFeedback(e.currentTarget, $('exportBlock').textContent, I18n.t('copy.copiedCheck'), api.copy));
  document.querySelectorAll('[data-copy]').forEach((b) => b.addEventListener('click', () => copyFeedback(b, $(b.getAttribute('data-copy')).textContent, I18n.t('copy.copiedCheck'), api.copy)));
  if ($('fTargetClaude')) $('fTargetClaude').addEventListener('change', (e) => toggleTarget('claude', e.target.checked));
  if ($('fTargetCodex')) $('fTargetCodex').addEventListener('change', (e) => toggleTarget('codex', e.target.checked));
  if ($('fGatewayEnabled')) $('fGatewayEnabled').addEventListener('change', async (e) => {
    const on = e.target.checked;
    let res;
    try { res = await api.gatewaySetEnabled(on); } catch (_) { res = null; }
    if (res && res.ok === false) {
      e.target.checked = !on; // couldn't bind the port → revert + surface
      try { showHeroNote(res.message || I18n.t('err.opFailed'), true); } catch (_) {}
    }
    await refresh();
  });
  if ($('fRetry429')) $('fRetry429').addEventListener('change', (e) => persist({ retry429: Object.assign({}, state.config.retry429, { enabled: e.target.checked }) }));
  if ($('fInsecureTls')) $('fInsecureTls').addEventListener('change', (e) => persist({ insecureSkipVerify: e.target.checked }));
}
