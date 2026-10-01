import type {
  HistoryContentBlock,
  HistoryLocale,
  HistoryMessage,
  HistorySessionDetail,
} from "./contract.js";
import { formatHistoryPayload } from "./reader-utils.js";
import { sourceLabel } from "./labels.js";

/** Flattened transcript handed to the CCbuddy agent's `importedHistory`. */
export interface HistoryImportMessage {
  role: "user" | "assistant";
  content: string;
  timestamp?: number;
}

export interface HistoryImportPlan {
  messages: HistoryImportMessage[];
  /** Messages dropped from the start of the transcript to stay within the budget. */
  omitted: number;
  totalChars: number;
}

export interface HistoryImportOptions {
  locale?: HistoryLocale;
  /** Per tool payload cap; tool output is context, not the conversation itself. */
  maxToolChars?: number;
  /** Whole transcript cap; older turns are dropped first, the first user turn is always kept. */
  maxTotalChars?: number;
}

const DEFAULT_MAX_TOOL_CHARS = 1_500;
const DEFAULT_MAX_TOTAL_CHARS = 160_000;

const markers = {
  "zh-CN": {
    toolCall: "工具调用",
    toolResult: "工具结果",
    toolError: "工具失败",
    image: "[图片]",
    truncated: "…（已截断）",
    omitted: (count: number, source: string) =>
      `（导入自 ${source}；较早的 ${count} 条消息因篇幅省略）`,
  },
  "en-US": {
    toolCall: "Tool call",
    toolResult: "Tool result",
    toolError: "Tool failed",
    image: "[image]",
    truncated: "… (truncated)",
    omitted: (count: number, source: string) =>
      `(Imported from ${source}; ${count} earlier messages omitted for length)`,
  },
} as const;

// 与 @ccbuddy/history 的 visibleUserText 同一规则（history 包是 Node-only，UI 侧不能引用）：
// Claude Code 把斜杠命令和 IDE 上下文记成带标签的块，这些不是用户说的话，不进新会话。
const CONTROL_BLOCK =
  /<(command-name|command-message|command-args|local-command-stdout|local-command-stderr|local-command-caveat|ide_opened_file|system-reminder)>[\s\S]*?<\/\1>/g;

function visibleText(text: string): string {
  return text
    .replace(CONTROL_BLOCK, " ")
    .replace(/[ \t]+\n/g, "\n")
    .trim();
}

function truncate(text: string, limit: number, suffix: string): string {
  return text.length <= limit ? text : `${text.slice(0, limit)}${suffix}`;
}

function payloadText(value: unknown, limit: number, suffix: string): string {
  return truncate(formatHistoryPayload(value).trim(), limit, suffix);
}

function blockText(
  block: HistoryContentBlock,
  locale: HistoryLocale,
  maxToolChars: number,
): string | null {
  const text = markers[locale];
  switch (block.type) {
    case "text":
      return visibleText(block.text) || null;
    case "reasoning":
      // 思考过程是模型的内部草稿，不是对话事实；导入后由新模型自己推理。
      return null;
    case "tool_call":
      return `[${text.toolCall}: ${block.toolName}]\n${payloadText(block.input, maxToolChars, text.truncated)}`;
    case "tool_result":
      return `[${block.isError ? text.toolError : text.toolResult}]\n${payloadText(block.output, maxToolChars, text.truncated)}`;
    case "image":
      return text.image;
  }
}

function importRole(message: HistoryMessage): HistoryImportMessage["role"] | null {
  switch (message.role) {
    case "user":
      return "user";
    case "assistant":
    case "tool":
      // 工具结果在部分生产者里是独立的 tool 角色；对新模型而言它属于助手那一轮的事实。
      return "assistant";
    case "system":
      return null;
  }
}

/**
 * Turns a read-only transcript into the user/assistant text the agent import accepts.
 * Consecutive same-role turns merge so the imported history alternates like a normal chat.
 */
export function buildHistoryImportMessages(
  detail: HistorySessionDetail,
  options: HistoryImportOptions = {},
): HistoryImportPlan {
  const locale = options.locale ?? "zh-CN";
  const maxToolChars = options.maxToolChars ?? DEFAULT_MAX_TOOL_CHARS;
  const maxTotalChars = options.maxTotalChars ?? DEFAULT_MAX_TOTAL_CHARS;
  const turns: HistoryImportMessage[] = [];
  for (const message of detail.messages) {
    const role = importRole(message);
    if (!role) continue;
    const content = message.blocks
      .map((block) => blockText(block, locale, maxToolChars))
      .filter((part): part is string => part !== null)
      .join("\n\n");
    if (!content) continue;
    const timestamp = message.timestamp ? Date.parse(message.timestamp) : Number.NaN;
    turns.push({ role, content, ...(Number.isFinite(timestamp) ? { timestamp } : {}) });
  }
  let total = turns.reduce((sum, item) => sum + item.content.length, 0);
  let omitted = 0;
  // 预算超出时从第二条开始丢最早的轮次；首条用户消息是任务陈述，始终保留。
  while (turns.length > 2 && total > maxTotalChars) {
    const [removed] = turns.splice(1, 1);
    if (!removed) break;
    total -= removed.content.length;
    omitted += 1;
  }
  // 丢弃轮次后可能出现连续同角色消息；合并后导入的历史才像一场正常交替的对话。
  const messages: HistoryImportMessage[] = [];
  for (const turn of turns) {
    const previous = messages.at(-1);
    if (previous && previous.role === turn.role) {
      previous.content = `${previous.content}\n\n${turn.content}`;
      continue;
    }
    messages.push({ ...turn });
  }
  const first = messages[0];
  if (omitted > 0 && first) {
    first.content = `${markers[locale].omitted(omitted, sourceLabel(detail.summary.source))}\n\n${first.content}`;
  }
  return {
    messages,
    omitted,
    totalChars: messages.reduce((sum, item) => sum + item.content.length, 0),
  };
}
