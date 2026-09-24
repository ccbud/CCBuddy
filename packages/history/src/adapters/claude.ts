import { basename, extname } from "node:path";
import type { SourceAdapter, SourceInput, ParsedSource } from "../app/source-adapter.js";
import { contentBlocks, message, object, string, timestamp } from "../domain/value.js";
import { MessageCollector } from "../domain/message-collector.js";
import { tokenUsage } from "../domain/usage.js";

export const claudeAdapter: SourceAdapter = {
  source: "claude",
  async parse(input: SourceInput): Promise<ParsedSource> {
    const collector = new MessageCollector(input.mode);
    let sessionId: string | null = null;
    let agentId: string | null = null;
    let cwd: string | null = null;
    let model: string | null = null;
    let firstAt: string | null = null;
    let lastAt: string | null = null;
    for await (const { number, value } of input.records) {
      sessionId ??= string(value.sessionId);
      agentId ??= string(value.agentId);
      cwd ??= string(value.cwd);
      const at = timestamp(value.timestamp);
      firstAt ??= at;
      lastAt = at ?? lastAt;
      if ((value.type !== "user" && value.type !== "assistant") || value.isMeta === true) continue;
      const envelope = object(value.message);
      const role =
        envelope.role === "assistant" ? "assistant" : envelope.role === "user" ? "user" : null;
      if (role === null) continue;
      const item = message(
        number,
        role,
        contentBlocks(envelope.content),
        value.timestamp,
        envelope.model,
      );
      if (item) {
        if (role === "assistant") item.usage = tokenUsage(envelope.usage);
        collector.add(item);
      }
      if (role === "assistant") model = string(envelope.model) ?? model;
    }
    const stem = basename(input.file, extname(input.file));
    const projectDirectory = input.relativePath.split("/")[0] ?? "";
    const decoded = projectDirectory.startsWith("-")
      ? `/${projectDirectory.replace(/^-+/, "").replaceAll("-", "/")}`
      : null;
    return {
      sessionId: agentId ? `${sessionId ?? stem}:${agentId}` : (sessionId ?? stem),
      title: collector.title,
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
