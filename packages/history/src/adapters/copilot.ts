import { basename, dirname, extname } from "node:path";
import type { SourceAdapter, SourceInput, ParsedSource } from "../app/source-adapter.js";
import { MessageCollector } from "../domain/message-collector.js";
import {
  array,
  message,
  nestedString,
  object,
  string,
  timestamp,
  textBlock,
} from "../domain/value.js";

function workspaceYaml(text: string | null): Record<string, string> {
  const values: Record<string, string> = {};
  for (const line of text?.split(/\r?\n/) ?? []) {
    const separator = line.indexOf(":");
    if (separator <= 0 || line.trimStart().startsWith("#")) continue;
    const key = line.slice(0, separator).trim();
    const value = line
      .slice(separator + 1)
      .trim()
      .replace(/^(['"])(.*)\1$/, "$2");
    if (key && value) values[key] = value;
  }
  return values;
}

export const copilotAdapter: SourceAdapter = {
  source: "copilot",
  async parse(input: SourceInput): Promise<ParsedSource> {
    const workspace = input.file.endsWith("/events.jsonl")
      ? workspaceYaml(await input.readTextSidecar("workspace.yaml"))
      : {};
    const collector = new MessageCollector(input.mode);
    let sessionId: string | null = null;
    let cwd: string | null = null;
    let model: string | null = null;
    let firstAt: string | null = timestamp(workspace.created_at);
    let lastAt: string | null = null;
    for await (const { number, value } of input.records) {
      const data = object(value.data);
      const at = timestamp(value.timestamp);
      firstAt ??= at;
      lastAt = at ?? lastAt;
      if (value.type === "session.start") {
        sessionId = string(data.sessionId) ?? sessionId;
        cwd = nestedString(data, "context", "cwd") ?? cwd;
      } else if (value.type === "session.model_change") {
        model = string(data.newModel) ?? model;
      } else if (value.type === "user.message") {
        const block = textBlock(data.content);
        const item = message(number, "user", block ? [block] : [], at);
        collector.add(item);
      } else if (value.type === "assistant.message") {
        model = string(data.model) ?? model;
        const blocks: ParsedSource["messages"][number]["blocks"] = [];
        const block = textBlock(data.content);
        if (block) blocks.push(block);
        for (const call of array(data.toolRequests)) {
          const tool = object(call);
          const name = string(tool.name) ?? "tool";
          blocks.push({
            type: "tool_call",
            toolName: name === "bash" ? "Bash" : name,
            toolCallId: string(tool.toolCallId),
            input: tool.arguments ?? null,
          });
        }
        const item = message(number, "assistant", blocks, at, model);
        collector.add(item);
      } else if (value.type === "tool.execution_complete") {
        const item = message(
          number,
          "tool",
          [
            {
              type: "tool_result",
              toolCallId: string(data.toolCallId),
              output: object(data.result).content ?? null,
              isError: data.success === false,
            },
          ],
          at,
        );
        collector.add(item);
      }
    }
    const stem = input.file.endsWith("/events.jsonl")
      ? basename(dirname(input.file))
      : basename(input.file, extname(input.file));
    return {
      sessionId: sessionId ?? stem,
      title: workspace.name ?? collector.title,
      cwd: workspace.cwd ?? cwd,
      model,
      parentSessionId: null,
      isSubagent: false,
      createdAt: firstAt,
      lastActivity: lastAt,
      messages: collector.messages,
      messageCount: collector.count,
      usage: collector.usage,
    };
  },
};
