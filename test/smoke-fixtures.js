'use strict';

// Backend fixtures for the renderer smoke test — one canned reply per IPC command, shaped like
// the real Tauri responses so every view has something to render.

const CONFIG = {
  port: 8788, activeProviderId: 'p1', requireToken: false, gatewayToken: '', gatewayEnabled: true,
  openAtLogin: false, trayUsage: { enabled: false, range: '7d' }, language: null,
  historyDirs: ['~/.claude'], historyActive: 'all', connectTargets: [],
  retry429: { enabled: true, max: 3, baseMs: 500 }, insecureSkipVerify: false,
  autoUpdate: { check: true, autoDownload: true },
  providers: [{
    id: 'p1', name: 'GLM', baseUrl: 'https://open.bigmodel.cn/api/anthropic/v1',
    authToken: 'sk-testtoken1234', defaultModel: 'glm-5.2', smallFastModel: 'glm-5.2',
    mapDefaultModels: true, protocol: 'anthropic', models: [{ alias: 'a', upstream: 'b' }], backend: 'http',
  }],
};

const STATUS = {
  running: true, port: 8788, connected: true, connectedClaude: true, connectedCodex: false,
  codexAvailable: true, gatewayEnabled: true, lastStartError: null, claudePath: '/home/u/.claude/settings.json',
};

const USAGE = {
  tokens: 12345, requests: 42, activeDays: 7, favoriteModel: 'glm-5.2', favoriteProvider: 'GLM',
  currentStreak: 3, longestStreak: 9, peakHour: 14,
  byModel: [{ model: 'glm-5.2', tokens: 12345, pct: 1 }],
  heatmap: Array.from({ length: 60 }, (_, i) => ({
    date: '2026-01-' + String((i % 28) + 1).padStart(2, '0'), tokens: i * 7, level: i % 5,
  })),
};

// Exercises the transcript renderer end to end: markdown, thinking, a tool card and its result.
const DETAIL = {
  meta: {
    title: 'Test session', model: 'glm-5.2', assistant: 'Claude', messages: 3,
    totals: { turns: 2, in: 100, out: 200 }, sessionId: 'abcdef1234',
  },
  messages: [
    { role: 'user', content: [{ type: 'text', text: 'hello **world**' }] },
    {
      role: 'assistant',
      content: [
        { type: 'thinking', thinking: 'thinking hard' },
        { type: 'text', text: 'hi there' },
        { type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'ls -la', description: 'list' } },
      ],
      usage: { inputTokens: 10, outputTokens: 20 },
    },
    { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'total 0' }] },
  ],
  subagents: {},
};

const REPLIES = {
  config_get: CONFIG,
  server_status: STATUS,
  usage_get: USAGE,
  logs_get: [{ seq: 1, level: 'info', msg: 'gateway up' }],
  plugin_list: [{
    id: 'demo', name: 'Demo', version: '1.0.0', protocol: 'anthropic', running: false,
    actions: [{ id: 'a1', label: 'Do', kind: 'call' }], auth: { state: 'logged_out' },
  }],
  history_projects: [{
    cwd: '/w/proj', name: 'proj',
    sessions: [{ id: 's1', file: '/w/proj/s1.jsonl', title: 'Test session', model: 'glm-5.2', sizeKB: 12, tags: ['x'] }],
  }],
  history_dirs: { active: 'all', dirs: [{ id: '~/.claude', label: '~/.claude', sessions: 1, exists: true, projectsDir: '/h/.claude/projects' }] },
  history_get: DETAIL,
  history_search: [],
  update_state: { runningVersion: '1.3.9', latestVersion: '1.3.9', mode: 'none', ok: true },
  monitor_get: {
    method: 'POST', status: 200, ms: 120, provider: 'GLM', requestedModel: 'a', outgoingModel: 'b',
    reqHeaders: { 'content-type': 'application/json' }, reqBody: { text: '{"model":"a"}', bytes: 14 },
    resHeaders: {}, resBody: { text: '{"ok":true}', bytes: 11 },
  },
};

/** Injected before any page script: the window.__TAURI__ surface core/bridge.js talks to. */
const stubScript = () => `
window.__TAURI__ = {
  core: { invoke: (cmd) => {
    const R = ${JSON.stringify(REPLIES)};
    if (cmd === 'history_projects') { R.history_projects[0].lastActivity = Date.now(); }
    return Promise.resolve(cmd in R ? R[cmd] : null);
  } },
  event: { listen: () => Promise.resolve(() => {}) },
  app: { getVersion: () => Promise.resolve('1.3.9') },
};
`;

module.exports = { REPLIES, stubScript };
