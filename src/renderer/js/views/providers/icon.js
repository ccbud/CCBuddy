/* Provider icon rendering: user image/emoji → brand logo → deterministic emoji fallback. */
import { escapeHtml, hashHue } from '../../core/dom.js';
import { I18n } from '../../core/i18n.js';

// Deterministic "random" emoji set — a custom provider with no brand logo gets a stable one.
export const ICON_EMOJIS = ['🤖', '🧠', '⚡', '🚀', '🦊', '🐳', '🌟', '💎', '🔮', '🎯', '🛰️', '🧩', '🔆', '🌀', '🦁', '🐲', '🦄', '🍀', '🔥', '❄️', '🌈', '🎨', '🧪', '📡', '🛡️', '🎲', '🌶️', '🦉', '🐙', '🪐', '✨', '🌊'];

export function emojiIcon(emoji, name) {
  const h = hashHue(name || '?');
  return { style: `background: linear-gradient(135deg, hsl(${h},62%,56%), hsl(${(h + 45) % 360},68%,46%))`, html: `<span class="prov-emoji">${escapeHtml(emoji)}</span>` };
}

// icon (optional): a user-set image (data:/http) or emoji; otherwise brand logo, else a default emoji.
export function renderProviderIcon(name, icon) {
  if (icon && typeof icon === 'string') {
    if (/^(data:|https?:|assets\/)/.test(icon)) return { style: 'background: transparent; box-shadow: none;', html: `<img src="${escapeHtml(icon)}" class="prov-svg" alt="" style="width:100%;height:100%;object-fit:cover;display:block" />` };
    return emojiIcon(icon, name); // a chosen emoji
  }
  const n = (name || '').trim().toLowerCase();
  const brand = { google: ['google ai studio', 'gemini', 'generativelanguage'], kimi: ['kimi', 'moonshot', '月之'], deepseek: ['deepseek'], zhipu: ['glm', '智谱', 'bigmodel'], xiaomi: ['mimo', '小米', 'xiaomi'], zenmux: ['zenmux'], minimax: ['minimax', 'mini max', '海螺'], nvidia: ['nvidia'] };
  for (const file in brand) {
    // object-fit:contain keeps non-square logos from being stretched into the square icon slot.
    const asset = file === 'google' ? 'google-ai-studio.png' : `${file}.svg`;
    if (brand[file].some((k) => n.includes(k))) return { style: 'background: transparent; box-shadow: none;', html: `<img src="assets/${asset}" class="prov-svg" alt="" style="width:100%;height:100%;display:block;object-fit:contain" />` };
  }
  if (n.includes('claude') || n.includes('anthropic')) {
    const h = hashHue(name || '?');
    return { style: `background: linear-gradient(135deg, hsl(28,70%,48%), hsl(${(h + 40) % 360},75%,45%))`, html: `<svg class="prov-svg" aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2L3 7v10l9 5 9-5V7l-9-5z" stroke-linecap="round"/><path d="M12 2v20 M3 12h18" stroke-linecap="round"/></svg>` };
  }
  return emojiIcon(ICON_EMOJIS[hashHue(name || '?') % ICON_EMOJIS.length], name); // default: deterministic emoji
}

export function mask(t) {
  return !t ? I18n.t('providers.noKey') : t.length <= 10 ? '••••' : t.slice(0, 4) + '••••' + t.slice(-4);
}
