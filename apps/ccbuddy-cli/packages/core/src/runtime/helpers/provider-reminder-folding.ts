import type { ModelMessageContent, ModelMessageContentBlock } from "@ccbuddy/contracts";
import {
  cloneModelMessageContent,
  isRuntimeAttachmentEntry,
  type ModelInputMessage,
} from "../../agent/message-history.js";
import { isPresentedInput, isReminderMessage } from "./provider-entry-origins.js";
import {
  isToolResultUserMessage,
  type ProjectedRuntimeMessageEntry,
} from "./provider-mid-conversation-system.js";

interface MessageMergeResult {
  messages: ModelInputMessage[];
  indexMap: number[];
}

// 紧跟 tool result 的 user 侧提醒并入这组最后一个 tool result 的内容。
// MCS 只决定哪些提醒留在 user 侧，不改变这条规则。遇到第一条不折叠的消息即停止。
export function foldRemindersIntoToolResults(
  messages: readonly ModelInputMessage[],
  entries: readonly (ProjectedRuntimeMessageEntry | undefined)[],
): MessageMergeResult {
  const result: ModelInputMessage[] = [];
  const indexMap: number[] = [];
  for (const [index, message] of messages.entries()) {
    const previous = result.at(-1);
    const entry = entries[index];
    const content =
      previous?.role === "tool" && entry && isFoldableReminder(entry, message)
        ? foldIntoToolResultContent(previous.content, message.content)
        : undefined;
    if (previous && content) {
      const cacheControl = message.cacheControl ?? previous.cacheControl;
      result[result.length - 1] = {
        ...previous,
        content,
        ...(cacheControl ? { cacheControl: { ...cacheControl } } : {}),
      };
      indexMap.push(result.length - 1);
      continue;
    }
    indexMap.push(result.length);
    result.push(message);
  }
  return { messages: result, indexMap };
}

// 中途消息按 attachment 处理，同样并入；带媒体的中途消息不并入。
// MCS 降级块不经过折叠；legacy_synthetic 还承载旧后台通知与 compact 摘要，同样不折叠。
function isFoldableReminder(
  entry: ProjectedRuntimeMessageEntry,
  message: ModelInputMessage,
): boolean {
  if (message.role !== "user" || isToolResultUserMessage(message)) return false;
  if (typeof message.content !== "string" && message.content.some((b) => b.type !== "text")) {
    return false;
  }
  if (isRuntimeAttachmentEntry(entry)) return true;
  if (isPresentedInput(entry)) return false;
  return isReminderMessage(entry);
}

function foldIntoToolResultContent(
  toolContent: ModelMessageContent,
  reminder: ModelMessageContent,
): ModelMessageContent | undefined {
  const reminderBlocks = modelContentToMergeBlocks(reminder);
  if (typeof toolContent === "string") {
    return [
      toolContent,
      ...reminderBlocks.map((block) => (block.type === "text" ? block.text : "")),
    ]
      .map((text) => text.trim())
      .filter(Boolean)
      .join("\n\n");
  }
  if (toolContent.some((block) => block.type === "tool_reference")) return undefined;
  return [...appendNewlineToLastTextBlock(toolContent), ...reminderBlocks];
}

function appendNewlineToLastTextBlock(
  content: ModelMessageContentBlock[],
): ModelMessageContentBlock[] {
  const last = content.at(-1);
  if (last?.type !== "text") return content;
  return [...content.slice(0, -1), { ...last, text: `${last.text}\n` }];
}

export function modelContentToMergeBlocks(
  content: ModelMessageContent,
): ModelMessageContentBlock[] {
  if (typeof content === "string") {
    return [{ type: "text", text: content }];
  }
  return cloneModelMessageContent(content) as ModelMessageContentBlock[];
}
