import { basename, extname } from "node:path";
import type { HistoryMessage, HistoryTokenUsage } from "../contract.js";
import type { SourceAdapter, SourceInput, ParsedSource } from "../app/source-adapter.js";
import { array, contentBlocks, message, object, string, timestamp } from "../domain/value.js";
import { MessageCollector } from "../domain/message-collector.js";
import { tokenUsage } from "../domain/usage.js";

interface AssistantState {
  number: number;
  at: string | null;
  skipped: boolean;
  counted: boolean;
  role: HistoryMessage["role"] | null;
  model: string | null;
  usage: HistoryTokenUsage | null;
  item: HistoryMessage | null;
}

export const qoderAdapter: SourceAdapter = {
  source: "qoder",
  async parse(input: SourceInput): Promise<ParsedSource> {
    const collector = new MessageCollector(input.mode);
    const assistantById = new Map<string, AssistantState>();
    let sessionId: string | null = null;
    let agentId: string | null = null;
    let cwd: string | null = null;
    let model: string | null = null;
    let title: string | null = null;
    let firstAt: string | null = null;
    let lastAt: string | null = null;
    for await (const record of input.records) {
      const raw = record.value;
      const attachment = object(raw.attachment);
      const value =
        raw.type === "attachment" && attachment.type === "queued_command"
          ? {
              type: "user",
              timestamp: raw.timestamp,
              message: { role: "user", content: string(attachment.prompt) ?? "" },
            }
          : raw;
      sessionId ??= string(value.sessionId);
      agentId ??= string(value.agentId);
      cwd ??= string(value.cwd);
      const at = timestamp(value.timestamp);
      firstAt ??= at;
      lastAt = at ?? lastAt;
      if (value.type === "workspace-directories") {
        cwd = string(array(value.directories)[0]) ?? cwd;
      }
      if (value.type === "runtime-config") model = string(value.model) ?? model;
      if (value.type === "custom-title") title = string(value.customTitle) ?? title;
      if (value.type === "ai-title" && !title) title = string(value.aiTitle);
      if (value.type !== "user" && value.type !== "assistant") continue;

      const envelope = object(value.message);
      const role =
        envelope.role === "assistant" ? "assistant" : envelope.role === "user" ? "user" : null;
      if (role === "assistant") model = string(envelope.model) ?? model;
      if (value.type === "assistant") {
        const id = string(envelope.id);
        if (id) {
          let state = assistantById.get(id);
          const previousUsage = state?.counted && state.role === "assistant" ? state.usage : null;
          if (!state) {
            state = {
              number: record.number,
              at,
              skipped: value.isMeta === true,
              counted: false,
              role,
              model: string(envelope.model),
              usage: tokenUsage(envelope.usage),
              item: null,
            };
            assistantById.set(id, state);
          } else {
            if (Object.hasOwn(envelope, "role")) state.role = role;
            if (Object.hasOwn(envelope, "model")) state.model = string(envelope.model);
            if (Object.hasOwn(envelope, "usage")) state.usage = tokenUsage(envelope.usage);
          }
          if (state.skipped || state.role === null) continue;
          const blocks = contentBlocks(
            array(envelope.content).filter((part) => object(part).type !== "redacted_thinking"),
          );
          if (!state.counted) {
            const item = message(state.number, state.role, blocks, state.at, state.model);
            if (!item) continue;
            if (state.role === "assistant") item.usage = state.usage;
            collector.add(item);
            state.counted = true;
            if (input.mode === "detail") state.item = item;
          } else {
            // 同 ID 的后续片段可能改写角色或用量，汇总必须按旧贡献替换。
            collector.replaceUsage(previousUsage, state.role === "assistant" ? state.usage : null);
            if (state.item) {
              state.item.role = state.role;
              state.item.model = state.model;
              state.item.usage = state.role === "assistant" ? state.usage : null;
              state.item.blocks.push(...blocks);
            }
          }
          continue;
        }
      }
      if (value.isMeta === true || role === null) continue;
      const blocks =
        value.type === "assistant"
          ? contentBlocks(
              array(envelope.content).filter((part) => object(part).type !== "redacted_thinking"),
            )
          : contentBlocks(envelope.content);
      const item = message(record.number, role, blocks, value.timestamp, envelope.model);
      if (item) {
        if (role === "assistant") item.usage = tokenUsage(envelope.usage);
        collector.add(item);
      }
    }
    const projectDirectory = input.relativePath.split("/")[0] ?? "";
    const decoded = projectDirectory.startsWith("-")
      ? `/${projectDirectory.replace(/^-+/, "").replaceAll("-", "/")}`
      : null;
    return {
      sessionId: agentId
        ? `${sessionId ?? basename(input.file, extname(input.file))}:${agentId}`
        : (sessionId ?? basename(input.file, extname(input.file))),
      title: title ?? collector.title,
      cwd: cwd ?? decoded,
      model,
      parentSessionId: agentId ? sessionId : null,
      isSubagent: agentId !== null,
      createdAt: firstAt,
      lastActivity: lastAt,
      messages: collector.messages,
      messageCount: collector.count,
      usage: collector.usage,
    };
  },
};
