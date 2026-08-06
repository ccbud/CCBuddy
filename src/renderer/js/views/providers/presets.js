/*
 * Provider presets. Each preset declares its wire `protocol` up front — Anthropic-native
 * endpoints (the `/anthropic` gateways) pass through directly; OpenAI-compatible endpoints
 * are auto-translated. Picking a preset sets the protocol so the user knows immediately how
 * their requests will be handled.
 */
export const PRESETS = {
  glm: { name: 'GLM', baseUrl: 'https://open.bigmodel.cn/api/anthropic/v1', defaultModel: 'glm-5.2', smallFastModel: 'glm-5.2', protocol: 'anthropic' },
  deepseek: { name: 'DeepSeek', baseUrl: 'https://api.deepseek.com/anthropic', defaultModel: 'deepseek-v4-pro', smallFastModel: 'deepseek-v4-flash', protocol: 'anthropic' },
  mimo: { name: 'MiMo', baseUrl: 'https://token-plan-sgp.xiaomimimo.com/anthropic', defaultModel: 'mimo-v2.5-pro', smallFastModel: 'mimo-v2.5', protocol: 'anthropic' },
  kimi: { name: 'Kimi', baseUrl: 'https://api.kimi.com/coding', defaultModel: 'kimi-for-coding', smallFastModel: 'kimi-for-coding', protocol: 'anthropic' },
  minimax: { name: 'MiniMax', baseUrl: 'https://api.minimax.io/anthropic', defaultModel: 'MiniMax-M3', smallFastModel: 'MiniMax-M3', protocol: 'anthropic' },
  nvidia: { name: 'NVIDIA', baseUrl: 'https://integrate.api.nvidia.com/v1', defaultModel: 'z-ai/glm-5.2', smallFastModel: 'z-ai/glm-5.2', protocol: 'openai-chat' },
  google: { name: 'Google AI Studio', baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai', defaultModel: 'gemini-3.5-flash', smallFastModel: 'gemini-3.1-flash-lite', protocol: 'openai-chat' },
  openai: { name: 'OpenAI', baseUrl: 'https://api.openai.com/v1', defaultModel: 'gpt-5.2', smallFastModel: 'gpt-5.2-mini', protocol: 'openai-responses' },
  openrouter: { name: 'OpenRouter', baseUrl: 'https://openrouter.ai/api/v1', defaultModel: '', smallFastModel: '', protocol: 'openai-chat' },
  custom: { name: '', baseUrl: '', defaultModel: '', smallFastModel: '', protocol: 'anthropic' },
};

export const PRESET_LABELS = { glm: 'GLM', deepseek: 'DeepSeek', mimo: 'MiMo', kimi: 'Kimi', minimax: 'MiniMax', nvidia: 'NVIDIA', google: 'Google AI Studio', openai: 'OpenAI', openrouter: 'OpenRouter', custom: '自定义' };
