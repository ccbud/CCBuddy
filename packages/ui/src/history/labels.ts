import type { HistoryLocale, HistorySource } from "./contract.js";

const translations = {
  "zh-CN": {
    review: "会话回顾",
    list: "会话列表",
    timeline: "时间线",
    refresh: "刷新",
    refreshing: "正在刷新…",
    incomplete: "扫描未完成，部分会话可能不可用",
    diagnostics: "读取提示",
    noSessions: "尚无可查看的会话",
    chooseSession: "选择一个会话以查看内容",
    loading: "正在读取原始会话…",
    failed: "会话读取失败",
    emptyDetail: "此会话没有可显示的消息",
    filterSessions: "按标题、项目或路径筛选",
    searchInSession: "搜索当前会话正文",
    previousMatch: "上一个匹配消息",
    nextMatch: "下一个匹配消息",
    matchingMessages: "条匹配消息",
    noSearchResults: "无匹配消息",
    matchExcerpt: "匹配位置附近",
    tokenUsage: "Token 用量",
    inputTokens: "输入",
    outputTokens: "输出",
    cacheReadTokens: "缓存读",
    cacheWriteTokens: "缓存写",
    allAgents: "所有 Agent",
    noMatches: "没有匹配的会话",
    messages: "条消息",
    unknownTitle: "无标题会话",
    unknownProject: "未知目录",
    unknownDate: "时间未知",
    groupDirectory: "按目录",
    groupAgent: "按 Agent",
    week: "周",
    month: "月",
    quarter: "季",
    year: "年",
    previous: "向前移动",
    next: "向后移动",
    today: "今天",
    emptyWindow: "此时间范围没有会话",
    keyboardHint: "左右方向键选择会话，Home 和 End 跳到首尾，回车打开",
    user: "你",
    assistant: "助手",
    tool: "工具",
    system: "上下文",
    reasoning: "思考过程",
    toolCall: "工具调用",
    toolResult: "工具结果",
    toolError: "执行失败",
    image: "会话图片",
    unsupportedImage: "无法显示此图片格式",
    showMore: "继续展开",
    remainingChars: "字未显示",
    parent: "父会话",
    childAgents: "子代理",
    readOnly: "只读",
    sessionOf: "个会话",
  },
  "en-US": {
    review: "Session review",
    list: "Sessions",
    timeline: "Timeline",
    refresh: "Refresh",
    refreshing: "Refreshing…",
    incomplete: "Scan incomplete; some sessions may be unavailable",
    diagnostics: "Read diagnostics",
    noSessions: "No sessions to review",
    chooseSession: "Select a session to read it",
    loading: "Reading the source transcript…",
    failed: "Could not read this session",
    emptyDetail: "This session has no displayable messages",
    filterSessions: "Filter by title, project, or path",
    searchInSession: "Search this transcript",
    previousMatch: "Previous matching message",
    nextMatch: "Next matching message",
    matchingMessages: "matching messages",
    noSearchResults: "No matching messages",
    matchExcerpt: "Near the match",
    tokenUsage: "Token usage",
    inputTokens: "Input",
    outputTokens: "Output",
    cacheReadTokens: "Cache read",
    cacheWriteTokens: "Cache write",
    allAgents: "All agents",
    noMatches: "No matching sessions",
    messages: "messages",
    unknownTitle: "Untitled session",
    unknownProject: "Unknown directory",
    unknownDate: "Unknown time",
    groupDirectory: "By directory",
    groupAgent: "By agent",
    week: "Week",
    month: "Month",
    quarter: "Quarter",
    year: "Year",
    previous: "Move earlier",
    next: "Move later",
    today: "Today",
    emptyWindow: "No sessions in this time range",
    keyboardHint:
      "Use Left and Right to select sessions, Home and End for first and last, Enter to open",
    user: "You",
    assistant: "Assistant",
    tool: "Tool",
    system: "Context",
    reasoning: "Reasoning",
    toolCall: "Tool call",
    toolResult: "Tool result",
    toolError: "Failed",
    image: "Session image",
    unsupportedImage: "This image format cannot be shown",
    showMore: "Show more",
    remainingChars: "characters remain",
    parent: "Parent session",
    childAgents: "Subagents",
    readOnly: "Read only",
    sessionOf: "sessions",
  },
} as const;

export type HistoryLabels = (typeof translations)[HistoryLocale];

export function historyLabels(locale: HistoryLocale): HistoryLabels {
  return translations[locale];
}

export function sourceLabel(source: HistorySource): string {
  switch (source) {
    case "claude":
      return "Claude Code";
    case "codex":
      return "Codex";
    case "qoder":
      return "Qoder";
    case "grok":
      return "Grok Build";
    case "copilot":
      return "GitHub Copilot";
    case "antigravity":
      return "Antigravity";
  }
}

export function formatHistoryDate(
  value: string | number | null,
  locale: HistoryLocale,
  fallback = historyLabels(locale).unknownDate,
): string {
  if (value == null) return fallback;
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return fallback;
  return new Intl.DateTimeFormat(locale, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

export function formatHistoryTime(value: string | null, locale: HistoryLocale): string | null {
  if (!value) return null;
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return null;
  return new Intl.DateTimeFormat(locale, { timeStyle: "short" }).format(date);
}
