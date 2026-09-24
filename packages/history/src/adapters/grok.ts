import { basename, dirname } from "node:path";
import type { HistoryContentBlock, HistoryDiagnostic } from "../contract.js";
import type { SourceAdapter, SourceInput, ParsedSource } from "../app/source-adapter.js";
import { MessageCollector } from "../domain/message-collector.js";
import {
  array,
  contentBlocks,
  message,
  nestedString,
  object,
  string,
  timestamp,
  textBlock,
} from "../domain/value.js";

function userBlocks(value: unknown): HistoryContentBlock[] {
  const source = typeof value === "string" ? [{ type: "text", text: value }] : array(value);
  const result: HistoryContentBlock[] = [];
  for (const part of source) {
    const record = object(part);
    if (record.type === "text") {
      const raw = string(record.text) ?? "";
      const query = raw.match(/<user_query>([\s\S]*?)(?:<\/user_query>|$)/)?.[1];
      if (
        /^\s*<(user_info|git_status|system-reminder|project_layout|workspace_)/.test(raw) &&
        !query
      )
        continue;
      const block = textBlock(query ?? raw);
      if (block) result.push(block);
    } else if (record.type === "image") {
      const url = string(record.url);
      if (url?.startsWith("data:image/")) result.push({ type: "image", dataUrl: url });
    }
  }
  return result;
}

function grokResult(
  input: SourceInput,
  summary: Record<string, unknown> | null,
  collector: MessageCollector,
  model: string | null,
  firstAt: string | null,
  lastAt: string | null,
  sessionId: string | null = null,
  diagnostics: HistoryDiagnostic[] = [],
): ParsedSource {
  const folder = basename(dirname(input.file));
  const encodedCwd = input.relativePath.split("/")[0];
  let fallbackCwd: string | null = null;
  if (encodedCwd?.toLowerCase().startsWith("%2f")) {
    try {
      fallbackCwd = decodeURIComponent(encodedCwd);
    } catch {
      /* unknown */
    }
  }
  return {
    sessionId: nestedString(summary, "info", "id") ?? sessionId ?? folder,
    title: string(summary?.generated_title) ?? string(summary?.session_summary) ?? collector.title,
    cwd: nestedString(summary, "info", "cwd") ?? fallbackCwd,
    model,
    parentSessionId: null,
    isSubagent: false,
    createdAt: firstAt,
    lastActivity: lastAt,
    messages: collector.messages,
    messageCount: collector.count,
    usage: collector.usage,
    diagnostics,
  };
}

function updateText(content: unknown): string | null {
  const value = object(content).text;
  return typeof value === "string" && value.length > 0 ? value : null;
}

function toolOutput(update: Record<string, unknown>): unknown {
  const parts = array(update.content);
  const texts = parts
    .map((part) => {
      const record = object(part);
      const content = record.type === "content" ? object(record.content) : record;
      return content.type === "text" ? updateText(content) : null;
    })
    .filter((part): part is string => part !== null);
  if (texts.length > 0) return texts.join("");
  return update.rawOutput ?? "";
}

async function parseUpdates(
  input: SourceInput,
  summary: Record<string, unknown> | null,
  model: string | null,
): Promise<ParsedSource> {
  const collector = new MessageCollector(input.mode);
  const diagnostics: HistoryDiagnostic[] = [];
  const completedTools = new Set<string>();
  let firstAt = timestamp(summary?.created_at);
  let lastAt: string | null = null;
  let sessionId: string | null = null;
  let pending:
    | {
        role: "user" | "assistant";
        number: number;
        at: string | null;
        blocks: HistoryContentBlock[];
        preview: string;
        hasContent: boolean;
      }
    | undefined;

  const flush = (): void => {
    if (!pending) return;
    if (pending.hasContent) {
      // Metadata scans keep only a title preview and a count, not accumulated transcript chunks.
      const blocks =
        input.mode === "detail"
          ? pending.blocks
          : [{ type: "text" as const, text: pending.role === "user" ? pending.preview : "" }];
      collector.add(message(pending.number, pending.role, blocks, pending.at, model));
    }
    pending = undefined;
  };
  const begin = (role: "user" | "assistant", number: number, at: string | null): void => {
    if (pending?.role !== role) {
      flush();
      pending = { role, number, at, blocks: [], preview: "", hasContent: false };
    }
  };
  const append = (block: HistoryContentBlock): void => {
    if (!pending) return;
    pending.hasContent = true;
    if (pending.role === "user" && block.type === "text" && pending.preview.length < 90) {
      pending.preview += block.text.slice(0, 90 - pending.preview.length);
    }
    if (input.mode !== "detail") return;
    const previous = pending.blocks.at(-1);
    if ((block.type === "text" || block.type === "reasoning") && previous?.type === block.type) {
      previous.text += block.text;
    } else {
      pending.blocks.push(block);
    }
  };
  const diagnose = (number: number, kind: string): void => {
    if (diagnostics.length >= 256) return;
    diagnostics.push({
      code: "unsupported_record",
      source: "grok",
      path: input.file,
      line: number,
      message: `Unsupported Grok update: ${kind}`,
    });
  };

  for await (const { number, value } of input.records) {
    const at = timestamp(value.timestamp ?? value.created_at);
    firstAt ??= at;
    lastAt = at ?? lastAt;
    const params = object(value.params);
    sessionId ??= string(params.sessionId) ?? string(value.sessionId);
    const method = string(value.method);
    const update = object(method ? params.update : value.update);
    const kind = string(update.sessionUpdate);
    // 生产者在重绕和压缩时会改变可见历史；未经完整重放不能显示旧消息。
    if (kind === "rewind_marker" || kind === "compaction_checkpoint") {
      throw new Error(`Grok ${kind} at line ${number} requires producer replay`);
    }
    if (
      (method !== "session/update" && !(method === null && Object.keys(update).length > 0)) ||
      !kind
    ) {
      diagnose(number, method ?? "missing sessionUpdate");
      continue;
    }
    const content = object(update.content);
    const meta = object(update._meta);
    if (kind === "user_message_chunk" || kind === "agent_message_chunk") {
      if (meta.hostTurn === true) {
        flush();
        continue;
      }
      const role = kind === "user_message_chunk" ? "user" : "assistant";
      if (role === "user" && meta.interjection === true) flush();
      begin(role, number, at);
      if (content.type === "text") {
        const raw = updateText(content);
        if (raw !== null) {
          const blocks =
            role === "user" ? userBlocks([content]) : [{ type: "text" as const, text: raw }];
          if (blocks.length === 0 && raw.trim() === "") append({ type: "text", text: raw });
          else for (const block of blocks) append(block);
        }
      } else if (role === "user" && content.type === "image_url") {
        const url = string(content.url);
        if (url?.startsWith("data:image/")) append({ type: "image", dataUrl: url });
      } else {
        diagnose(number, `${kind} content ${String(content.type)}`);
      }
      if (role === "user" && meta.interjection === true) flush();
    } else if (kind === "agent_thought_chunk") {
      const text = updateText(content);
      if (content.type !== "text" || text === null) {
        diagnose(number, `${kind} content ${String(content.type)}`);
        continue;
      }
      begin("assistant", number, at);
      append({ type: "reasoning", text });
    } else if (kind === "tool_call") {
      begin("assistant", number, at);
      append({
        type: "tool_call",
        toolName: string(update.title) ?? "tool",
        toolCallId: string(update.toolCallId),
        input: update.rawInput ?? null,
      });
    } else if (kind === "tool_call_update") {
      const id = string(update.toolCallId);
      if (id && update.rawInput !== undefined && pending?.role === "assistant") {
        const call = pending.blocks.find(
          (block) => block.type === "tool_call" && block.toolCallId === id,
        );
        if (call?.type === "tool_call" && call.input === null) call.input = update.rawInput;
      }
      if (update.status !== "completed" && update.status !== "failed") continue;
      if (id && completedTools.has(id)) continue;
      if (id) completedTools.add(id);
      flush();
      collector.add(
        message(
          number,
          "tool",
          [
            {
              type: "tool_result",
              toolCallId: id,
              output: toolOutput(update),
              isError: update.status === "failed",
            },
          ],
          at,
        ),
      );
    } else {
      diagnose(number, kind);
    }
  }
  flush();
  if (collector.count === 0) throw new Error("Grok updates contain no displayable conversation");
  return grokResult(input, summary, collector, model, firstAt, lastAt, sessionId, diagnostics);
}

export const grokAdapter: SourceAdapter = {
  source: "grok",
  async parse(input: SourceInput): Promise<ParsedSource> {
    const summary = await input.readJsonSidecar("summary.json");
    const model = string(summary?.current_model_id);
    if (basename(input.file) === "updates.jsonl") return parseUpdates(input, summary, model);
    const collector = new MessageCollector(input.mode);
    let firstAt: string | null = timestamp(summary?.created_at);
    let lastAt: string | null = null;
    for await (const { number, value } of input.records) {
      const at = timestamp(value.timestamp ?? value.created_at);
      firstAt ??= at;
      lastAt = at ?? lastAt;
      if (value.type === "user") {
        const item = message(number, "user", userBlocks(value.content), at);
        collector.add(item);
      } else if (value.type === "reasoning") {
        const text = array(value.summary)
          .map((part) => string(object(part).text))
          .filter(Boolean)
          .join("\n");
        const item = message(
          number,
          "assistant",
          text ? [{ type: "reasoning", text }] : [],
          at,
          model,
        );
        collector.add(item);
      } else if (value.type === "assistant") {
        const blocks = contentBlocks(value.content);
        for (const call of array(value.tool_calls)) {
          const tool = object(call);
          let args: unknown = tool.arguments ?? null;
          if (typeof args === "string") {
            try {
              args = JSON.parse(args) as unknown;
            } catch {
              /* preserve text */
            }
          }
          const name = string(tool.name) ?? "tool";
          blocks.push({
            type: "tool_call",
            toolName: name === "run_terminal_command" || name === "Shell" ? "Bash" : name,
            toolCallId: string(tool.id),
            input: args,
          });
        }
        const item = message(number, "assistant", blocks, at, model);
        collector.add(item);
      } else if (value.type === "tool_result") {
        const output: unknown = value.images
          ? { text: value.content ?? "", images: value.images }
          : (value.content ?? "");
        const item = message(
          number,
          "tool",
          [
            {
              type: "tool_result",
              toolCallId: string(value.tool_call_id),
              output,
            },
          ],
          at,
        );
        collector.add(item);
      }
    }
    return grokResult(input, summary, collector, model, firstAt, lastAt);
  },
};
