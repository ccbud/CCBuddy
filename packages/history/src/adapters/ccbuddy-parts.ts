import type { SQLOutputValue } from "node:sqlite";
import type { HistoryContentBlock, HistoryTokenUsage } from "../contract.js";
import { object, string, textBlock, timestamp, type JsonRecord } from "../domain/value.js";

/** Row and JSON decoding for CCbuddy's own `session` / `message` / `part` tables. */

export type Row = Record<string, SQLOutputValue>;

/** Part types that carry reader-visible content; steps, snapshots and patches are bookkeeping. */
export const CONTENT_PART_TYPES: ReadonlySet<string> = new Set([
  "text",
  "reasoning",
  "tool",
  "file",
  "subtask",
]);

export interface DecodedMessage {
  role: "user" | "assistant";
  hidden: boolean;
  at: string | null;
  model: string | null;
  usage: HistoryTokenUsage | null;
}

export function parseJson(data: SQLOutputValue | undefined): JsonRecord {
  if (typeof data !== "string") return {};
  try {
    return object(JSON.parse(data));
  } catch {
    return {};
  }
}

export function numberValue(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

export function rowNumber(value: SQLOutputValue | undefined): number {
  if (typeof value === "bigint") return Number(value);
  return numberValue(value);
}

export function rowString(value: SQLOutputValue | undefined): string | null {
  return typeof value === "string" ? string(value) : null;
}

export function decodeMessage(data: SQLOutputValue | undefined): DecodedMessage | null {
  const value = parseJson(data);
  const role = value.role === "assistant" ? "assistant" : value.role === "user" ? "user" : null;
  if (role === null) return null;
  const semantics = object(value.semantics);
  const hidden =
    value.synthetic === true ||
    value.visibility === "model-only" ||
    semantics.uiVisibility === "hidden";
  const tokens = object(value.tokens);
  const cache = object(tokens.cache);
  const usage =
    role === "assistant" && typeof tokens.input === "number"
      ? {
          inputTokens: numberValue(tokens.input),
          outputTokens: numberValue(tokens.output),
          cacheReadTokens: numberValue(cache.read),
          cacheWriteTokens: numberValue(cache.write),
        }
      : null;
  return {
    role,
    hidden,
    at: timestamp(object(value.time).created),
    model: role === "assistant" ? string(value.modelId) : null,
    usage,
  };
}

/** Maps one persisted agent part to reader blocks; bookkeeping parts (steps, snapshots, patches) are skipped. */
export function partBlocks(part: JsonRecord): HistoryContentBlock[] {
  switch (string(part.type)) {
    case "text": {
      const block = textBlock(part.text);
      return block ? [block] : [];
    }
    case "reasoning": {
      const text = string(part.text);
      return text ? [{ type: "reasoning", text }] : [];
    }
    case "tool": {
      const state = object(part.state);
      const toolCallId = string(part.callID);
      const blocks: HistoryContentBlock[] = [
        {
          type: "tool_call",
          toolName: string(part.tool) ?? "tool",
          toolCallId,
          input: state.input ?? null,
        },
      ];
      const status = string(state.status);
      if (status === "completed") {
        blocks.push({ type: "tool_result", toolCallId, output: state.output ?? null });
      } else if (status === "error") {
        blocks.push({
          type: "tool_result",
          toolCallId,
          output: state.error ?? null,
          isError: true,
        });
      }
      return blocks;
    }
    case "file": {
      const url = string(part.url);
      if (url?.startsWith("data:image/")) return [{ type: "image", dataUrl: url }];
      const label = string(part.filename) ?? url ?? string(part.mime) ?? "file";
      return [{ type: "text", text: `[file] ${label}` }];
    }
    case "subtask": {
      const text = string(part.description) ?? string(part.prompt);
      return text ? [{ type: "text", text: `[subtask] ${text}` }] : [];
    }
    default:
      return [];
  }
}
