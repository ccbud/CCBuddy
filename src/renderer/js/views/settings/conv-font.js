/*
 * 会话正文字号 (Sessions message text size). The 对话 message timeline scales through one
 * root CSS var (--conv-fs, a factor of the 13px base — see input.css). Persisted as
 * config.convFontPx: absent/13 = default, 15 = 大, 17 = 特大, anything else = custom.
 * Applied at boot (main.js) so the sessions view is right even before settings mounts.
 */
import { state } from '../../core/state.js';

export const CONV_FONT_BASE = 13;
export const CONV_FONT_PRESETS = { large: 15, xlarge: 17 };
export const CONV_FONT_MIN = 10;
export const CONV_FONT_MAX = 24;

export function convFontPx() {
  const v = state.config.convFontPx;
  const n = Number(v);
  if (v == null || v === '' || !Number.isFinite(n) || n <= 0) return CONV_FONT_BASE;
  return Math.min(CONV_FONT_MAX, Math.max(CONV_FONT_MIN, Math.round(n)));
}

export function applyConvFont() {
  const px = convFontPx();
  if (px === CONV_FONT_BASE) document.documentElement.style.removeProperty('--conv-fs');
  else document.documentElement.style.setProperty('--conv-fs', String(px / CONV_FONT_BASE));
}
