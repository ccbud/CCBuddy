/* 设置 → 常规 pane: app switches, tray usage, language, sessions font size. */
import { $ } from '../../core/dom.js';
import { I18n } from '../../core/i18n.js';
import { state, persist, renderAll } from '../../core/state.js';
import { SWITCH_TRACK } from './gateway-template.js';
import { CONV_FONT_BASE, CONV_FONT_PRESETS, CONV_FONT_MIN, CONV_FONT_MAX, convFontPx, applyConvFont } from './conv-font.js';

export const generalPaneTemplate = () => `
            <div data-pane="general" class="hidden flex flex-col gap-7">
            <div class="settings-card bg-bg-elev border border-border-custom rounded-xl shadow-card p-7 flex flex-col gap-6 transition-all duration-300">
              <h3 class="settings-card-title text-[13px] font-semibold text-fg" data-i18n="settings.app">应用</h3>
              <div class="settings-row no-border flex items-center gap-x-6 gap-y-4 flex-wrap pt-0 border-t-0">
                <label class="switch inline-flex items-center gap-1.75 cursor-pointer text-[12.5px] no-drag">
                  <input id="fOpenAtLogin" type="checkbox" class="hidden peer" />${SWITCH_TRACK}
                  <span class="switch-label" data-i18n="settings.openAtLogin">开机自启动</span>
                </label>
                <label class="switch inline-flex items-center gap-1.75 cursor-pointer text-[12.5px] no-drag">
                  <input id="fRequireToken" type="checkbox" class="hidden peer" />${SWITCH_TRACK}
                  <span class="switch-label" data-i18n="settings.requireToken">本地访问令牌</span>
                </label>
                <span class="input-with-btn token-row hidden flex gap-1.75 items-center w-full max-w-[300px] [&.hidden]:hidden" id="tokenRow">
                  <input id="fGatewayToken" data-clarity-mask="true" class="bg-bg-input border border-border-custom rounded-md px-2 py-1.25 text-fg font-mono text-[12px] outline-none focus:border-primary flex-1" type="text" data-i18n-placeholder="settings.tokenPlaceholder" placeholder="网关令牌" />
                  <button class="btn btn-sm bg-bg-elev text-fg border border-border-custom rounded-md px-2.25 py-1.25 font-medium text-[11px] leading-none cursor-pointer transition-all duration-140 hover:bg-chip-bg hover:border-border-strong active:scale-[0.985]" id="btnGenToken" type="button" data-i18n="settings.generate">生成</button>
                </span>
              </div>
              <div class="settings-row flex items-center gap-x-6 gap-y-4 flex-wrap pt-6 border-t border-border-custom">
                <label class="switch inline-flex items-center gap-1.75 cursor-pointer text-[12.5px] no-drag">
                  <input id="fTrayUsage" type="checkbox" class="hidden peer" />${SWITCH_TRACK}
                  <span class="switch-label" data-i18n="settings.trayUsage">菜单栏显示用量</span>
                </label>
                <span class="token-row inline-flex gap-1.5 items-center max-w-[300px] [&.hidden]:hidden" id="trayRangeRow">
                  <select id="fTrayRange" class="mini-select bg-bg-input border border-border-custom rounded-md px-2 py-1.25 text-fg font-inherit text-[12px] outline-none no-drag">
                    <option value="1d" data-i18n="range.1d">今日</option>
                    <option value="7d" data-i18n="range.7d">近 7 天</option>
                    <option value="30d" data-i18n="range.30d">近 30 天</option>
                    <option value="all" data-i18n="range.all">全部</option>
                  </select>
                </span>
              </div>
              <div class="settings-row flex items-center gap-x-6 gap-y-4 flex-wrap pt-6 border-t border-border-custom">
                <label class="switch-label lang-label text-[12.5px] font-medium mr-2" data-i18n="settings.language">语言</label>
                <select id="fLang" class="mini-select lang-select bg-bg-input border border-border-custom rounded-md px-2 py-1.25 text-fg font-inherit text-[12px] outline-none no-drag">
                  <option value="en">English</option>
                  <option value="zh">简体中文</option>
                  <option value="zh-TW">繁體中文</option>
                  <option value="ja">日本語</option>
                  <option value="ko">한국어</option>
                </select>
              </div>
            </div>
            <div class="settings-card bg-bg-elev border border-border-custom rounded-xl shadow-card p-7 flex flex-col gap-6 transition-all duration-300">
              <h3 class="settings-card-title text-[13px] font-semibold text-fg" data-i18n="settings.sessionsCard">会话</h3>
              <div class="flex items-center justify-between gap-x-6 gap-y-3 flex-wrap">
                <div class="min-w-0">
                  <div class="text-[12.5px] font-medium text-fg" data-i18n="settings.convFont">正文字号</div>
                  <div class="text-[11.5px] text-caption mt-0.5" data-i18n="settings.convFontDesc">「会话」页消息正文的字体大小 — 看长日志觉得密集时可以调大。</div>
                </div>
                <div class="flex items-center gap-2 shrink-0">
                  <div class="inline-flex gap-0.5 p-0.5 bg-chip-bg rounded-[7px]" id="fConvFontSeg">
                    <button type="button" class="seg-btn border-0 bg-transparent text-muted text-[11px] font-medium px-2.5 py-0.75 rounded-[5px] cursor-pointer hover:text-fg [.active]:bg-bg-elev [.active]:text-fg [.active]:shadow-sm transition-all duration-150" data-cfs="default" data-i18n="settings.convFontDefault">默认</button>
                    <button type="button" class="seg-btn border-0 bg-transparent text-muted text-[11px] font-medium px-2.5 py-0.75 rounded-[5px] cursor-pointer hover:text-fg [.active]:bg-bg-elev [.active]:text-fg [.active]:shadow-sm transition-all duration-150" data-cfs="large" data-i18n="settings.convFontLarge">大</button>
                    <button type="button" class="seg-btn border-0 bg-transparent text-muted text-[11px] font-medium px-2.5 py-0.75 rounded-[5px] cursor-pointer hover:text-fg [.active]:bg-bg-elev [.active]:text-fg [.active]:shadow-sm transition-all duration-150" data-cfs="xlarge" data-i18n="settings.convFontXlarge">特大</button>
                    <button type="button" class="seg-btn border-0 bg-transparent text-muted text-[11px] font-medium px-2.5 py-0.75 rounded-[5px] cursor-pointer hover:text-fg [.active]:bg-bg-elev [.active]:text-fg [.active]:shadow-sm transition-all duration-150" data-cfs="custom" data-i18n="settings.convFontCustom">自定义</button>
                  </div>
                  <span id="convFontCustomRow" class="hidden inline-flex items-center gap-1.25 [&.hidden]:hidden">
                    <input id="fConvFontPx" class="port-input w-[56px] px-1.75 py-1.25 bg-bg-input border border-border-custom rounded-md text-fg font-mono text-[12px] outline-none focus:border-primary" type="number" min="10" max="24" step="1" />
                    <span class="text-[11px] text-caption">px</span>
                  </span>
                </div>
              </div>
              <div class="conv-font-preview flex items-center justify-between gap-4 bg-bg-input border border-border-custom rounded-[9px] px-4 py-3">
                <span class="conv-font-preview-text min-w-0" data-i18n="settings.convFontPreview">会话正文将以这个大小显示 — 这是一段用于预览的示例文字。</span>
                <span id="convFontPreviewPx" class="text-[10.5px] font-semibold font-mono text-caption bg-chip-bg rounded-full px-2 py-0.25 shrink-0">13px</span>
              </div>
            </div>
            </div>`;

let convFontCustomOpen = false; // 自定义 clicked but value not (yet) diverging from a preset

function convFontMode(px) {
  if (convFontCustomOpen) return 'custom';
  if (px === CONV_FONT_PRESETS.large) return 'large';
  if (px === CONV_FONT_PRESETS.xlarge) return 'xlarge';
  return px === CONV_FONT_BASE ? 'default' : 'custom';
}

function renderConvFontControl() {
  const seg = $('fConvFontSeg');
  if (!seg) return;
  const px = convFontPx();
  const mode = convFontMode(px);
  seg.querySelectorAll('.seg-btn').forEach((b) => b.classList.toggle('active', b.dataset.cfs === mode));
  const row = $('convFontCustomRow');
  if (row) row.classList.toggle('hidden', mode !== 'custom');
  const input = $('fConvFontPx');
  if (input && document.activeElement !== input) input.value = px;
  const chip = $('convFontPreviewPx');
  if (chip) chip.textContent = px + 'px';
}

function genToken() {
  const a = new Uint8Array(18);
  crypto.getRandomValues(a);
  return 'ccbud_' + Array.from(a).map((b) => b.toString(16).padStart(2, '0')).join('');
}

export function renderGeneralPane() {
  $('fOpenAtLogin').checked = !!state.config.openAtLogin;
  $('fRequireToken').checked = !!state.config.requireToken;
  $('fGatewayToken').value = state.config.gatewayToken || '';
  $('tokenRow').classList.toggle('hidden', !state.config.requireToken);
  const tu = state.config.trayUsage || { enabled: false, range: '7d' };
  $('fTrayUsage').checked = !!tu.enabled;
  $('fTrayRange').value = tu.range || '7d';
  $('trayRangeRow').classList.toggle('hidden', !tu.enabled);
  if ($('fLang')) $('fLang').value = state.config.language || I18n.lang;
  applyConvFont();
  renderConvFontControl();
}

export function bindGeneralPane() {
  $('fOpenAtLogin').addEventListener('change', (e) => persist({ openAtLogin: e.target.checked }));
  $('fRequireToken').addEventListener('change', (e) => {
    const requireToken = e.target.checked;
    const patch = { requireToken };
    if (requireToken && !state.config.gatewayToken) patch.gatewayToken = genToken();
    persist(patch);
  });
  $('fGatewayToken').addEventListener('change', (e) => persist({ gatewayToken: e.target.value.trim() }));
  $('btnGenToken').addEventListener('click', () => persist({ gatewayToken: genToken(), requireToken: true }));
  $('fTrayUsage').addEventListener('change', (e) => persist({ trayUsage: { enabled: e.target.checked, range: $('fTrayRange').value } }));
  $('fTrayRange').addEventListener('change', (e) => persist({ trayUsage: { enabled: $('fTrayUsage').checked, range: e.target.value } }));
  if ($('fLang')) $('fLang').addEventListener('change', async (e) => {
    const language = e.target.value;
    await I18n.setLang(language);       // updates <html lang> + localStorage['ccbud-lang']
    I18n.apply(document);               // static data-i18n nodes
    renderAll();                        // dynamic strings (hero/status/monitor/providers/settings)
    if (window.ccbudConversations && window.ccbudConversations.setLang) window.ccbudConversations.setLang();
    await persist({ language });        // → config:save → main rebuilds tray on next open
  });
  // 会话正文字号: preset segments persist directly; 自定义 opens the px input (which persists
  // on change). The preview + open Sessions view update live through the --conv-fs root var.
  $('fConvFontSeg').addEventListener('click', (e) => {
    const b = e.target.closest('.seg-btn');
    if (!b) return;
    const mode = b.dataset.cfs;
    if (mode === 'custom') {
      convFontCustomOpen = true;
      renderConvFontControl();
      const input = $('fConvFontPx');
      if (input) { input.focus(); input.select(); }
      return;
    }
    convFontCustomOpen = false;
    const px = mode === 'large' ? CONV_FONT_PRESETS.large : mode === 'xlarge' ? CONV_FONT_PRESETS.xlarge : CONV_FONT_BASE;
    persist({ convFontPx: px === CONV_FONT_BASE ? null : px });
  });
  const fConvFontPx = $('fConvFontPx');
  if (fConvFontPx) {
    const commit = () => {
      const n = Math.round(Number(fConvFontPx.value));
      if (!Number.isFinite(n)) { fConvFontPx.value = convFontPx(); return; }
      const px = Math.min(CONV_FONT_MAX, Math.max(CONV_FONT_MIN, n));
      fConvFontPx.value = px;
      persist({ convFontPx: px === CONV_FONT_BASE ? null : px });
    };
    fConvFontPx.addEventListener('change', commit);
    fConvFontPx.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); commit(); } });
  }
}
