import { basename, extname } from "node:path";
import type { HistoryContentBlock, HistoryMessage } from "../contract.js";
import type { SourceAdapter, SourceInput, ParsedSource } from "../app/source-adapter.js";
import {
  array,
  contentBlocks,
  firstUserTitle,
  message,
  object,
  string,
  timestamp,
  textBlock,
} from "../domain/value.js";
import { tokenUsage } from "../domain/usage.js";
import { MessageCollector } from "../domain/message-collector.js";

function joinedText(value: unknown): string {
  if (typeof value === "string") return value;
  return array(value)
    .map((part) => {
      const item = object(part);
      return string(item.text) ?? "";
    })
    .filter(Boolean)
    .join("\n");
}

function argumentsValue(value: unknown): unknown {
  if (typeof value !== "string") return value ?? null;
  try {
    return JSON.parse(value) as unknown;
  } catch {
    return value;
  }
}

function toolName(value: unknown): string {
  const name = string(value) ?? "tool";
  if (["shell", "exec_command", "local_shell_call"].includes(name)) return "Bash";
  if (name === "apply_patch") return "ApplyPatch";
  return name;
}

function responseBlocks(
  payload: Record<string, unknown>,
): { role: HistoryMessage["role"]; blocks: HistoryContentBlock[] } | null {
  switch (payload.type) {
    case "message": {
      const role =
        payload.role === "user" ? "user" : payload.role === "assistant" ? "assistant" : null;
      if (!role) return null;
      const raw = joinedText(payload.content).trim();
      if (
        role === "user" &&
        /^(<environment_context>|<user_instructions>|<permissions|<ide_|<turn_context|<AGENTS|<workspace_)/.test(
          raw,
        )
      )
        return null;
      return { role, blocks: contentBlocks(payload.content) };
    }
    case "reasoning": {
      const text = [joinedText(payload.summary), joinedText(payload.content)]
        .filter(Boolean)
        .join("\n\n");
      return text.trim() ? { role: "assistant", blocks: [{ type: "reasoning", text }] } : null;
    }
    case "function_call":
    case "custom_tool_call":
    case "local_shell_call":
    case "web_search_call": {
      const original =
        payload.type === "local_shell_call"
          ? "shell"
          : payload.type === "web_search_call"
            ? "WebSearch"
            : payload.name;
      const input =
        payload.type === "local_shell_call"
          ? { command: array(object(payload.action).command).join(" ") }
          : payload.type === "custom_tool_call"
            ? payload.input
            : payload.type === "web_search_call"
              ? { query: object(payload.action).query }
              : argumentsValue(payload.arguments);
      return {
        role: "assistant",
        blocks: [
          {
            type: "tool_call",
            toolName: toolName(original),
            toolCallId: string(payload.call_id) ?? string(payload.id),
            input,
          },
        ],
      };
    }
    case "function_call_output":
    case "custom_tool_call_output":
      return {
        role: "tool",
        blocks: [
          {
            type: "tool_result",
            toolCallId: string(payload.call_id),
            output: payload.output ?? null,
          },
        ],
      };
    default:
      return null;
  }
}

export const codexAdapter: SourceAdapter = {
  source: "codex",
  async parse(input: SourceInput): Promise<ParsedSource> {
    const collector = new MessageCollector(input.mode);
    const eventFallback = new MessageCollector(input.mode);
    let hasPrimaryUserText = false;
    let unassignedAssistantCount = 0;
    const addPrimary = (item: HistoryMessage | null): void => {
      if (!item) return;
      if (item.role === "user" && item.blocks.some((block) => block.type === "text")) {
        hasPrimaryUserText = true;
      }
      if (item.role === "assistant" && !item.usage) unassignedAssistantCount += 1;
      collector.add(item);
    };
    let sessionId: string | null = null;
    let parentSessionId: string | null = null;
    let cwd: string | null = null;
    let model: string | null = null;
    let isSubagent = false;
    let firstAt: string | null = null;
    let lastAt: string | null = null;
    for await (const { number, value } of input.records) {
      const kind = string(value.type) ?? (value.id && value.timestamp ? "session_meta" : "");
      const payload = value.payload ? object(value.payload) : value;
      const at = timestamp(value.timestamp);
      firstAt ??= at;
      lastAt = at ?? lastAt;
      if (kind === "session_meta") {
        sessionId = string(payload.id) ?? string(payload.thread_id) ?? sessionId;
        cwd = string(payload.cwd) ?? cwd;
        const source = object(payload.source);
        const threadSource = object(payload.thread_source);
        const subagent = object(
          source.subagent ?? source.sub_agent ?? threadSource.subagent ?? threadSource.sub_agent,
        );
        const detail = object(
          subagent.thread_spawn ?? subagent.review ?? subagent.compact ?? subagent.other,
        );
        parentSessionId =
          string(payload.parent_thread_id) ?? string(detail.parent_thread_id) ?? parentSessionId;
        isSubagent =
          Object.keys(subagent).length > 0 ||
          payload.thread_source === "subagent" ||
          string(payload.agent_path) !== null ||
          parentSessionId !== null;
        continue;
      }
      if (kind === "turn_context") {
        model = string(payload.model) ?? model;
        cwd = string(payload.cwd) ?? cwd;
        continue;
      }
      if (kind === "event_msg") {
        if (payload.type === "user_message") {
          const block = textBlock(payload.message);
          const item = message(number, "user", block ? [block] : [], value.timestamp);
          eventFallback.add(item);
        } else if (payload.type === "turn_aborted") {
          const item = message(
            number,
            "user",
            [{ type: "text", text: "[Request interrupted by user]" }],
            value.timestamp,
          );
          addPrimary(item);
        } else if (payload.type === "token_count") {
          const raw = object(object(payload.info).last_token_usage);
          const usage = tokenUsage(raw);
          if (usage) {
            usage.inputTokens = Math.max(0, usage.inputTokens - usage.cacheReadTokens);
            if (input.mode === "metadata") {
              if (unassignedAssistantCount > 0) {
                unassignedAssistantCount -= 1;
                collector.replaceUsage(null, usage);
              }
            } else {
              for (let index = collector.messages.length - 1; index >= 0; index -= 1) {
                const candidate = collector.messages[index];
                if (candidate?.role !== "assistant" || candidate.usage) continue;
                candidate.usage = usage;
                collector.replaceUsage(null, usage);
                break;
              }
            }
          }
        }
        continue;
      }
      if (kind === "compacted") {
        const block = textBlock(payload.message);
        const item = message(number, "user", block ? [block] : [], value.timestamp);
        addPrimary(item);
        continue;
      }
      const responseTypes = [
        "message",
        "reasoning",
        "function_call",
        "custom_tool_call",
        "local_shell_call",
        "web_search_call",
        "function_call_output",
        "custom_tool_call_output",
      ];
      if (kind !== "response_item" && !responseTypes.includes(kind)) continue;
      const response = responseBlocks(payload);
      if (!response) continue;
      const item = message(number, response.role, response.blocks, value.timestamp, model);
      addPrimary(item);
    }
    if (!hasPrimaryUserText) {
      collector.count += eventFallback.count;
      if (input.mode === "detail") {
        collector.messages.push(...eventFallback.messages);
        collector.messages.sort((a, b) => a.sequence - b.sequence);
      }
    }
    const stem = basename(input.file, extname(input.file));
    const title =
      (input.mode === "detail" ? firstUserTitle(collector.messages) : collector.title) ||
      eventFallback.title;
    return {
      sessionId: sessionId ?? stem,
      title,
      cwd,
      model,
      parentSessionId,
      isSubagent,
      createdAt: firstAt,
      lastActivity: lastAt,
      messages: collector.messages,
      messageCount: collector.count,
      usage: collector.usage,
    };
  },
};
