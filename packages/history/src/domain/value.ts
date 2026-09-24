import type { HistoryContentBlock, HistoryMessage } from "../contract.js";

export type JsonRecord = Record<string, unknown>;

export function object(value: unknown): JsonRecord {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as JsonRecord)
    : {};
}

export function array(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

export function string(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value : null;
}

export function nestedString(value: unknown, ...keys: string[]): string | null {
  let current = value;
  for (const key of keys) current = object(current)[key];
  return string(current);
}

export function timestamp(value: unknown): string | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    const millis = value > 10_000_000_000 ? value : value * 1_000;
    const date = new Date(millis);
    return Number.isNaN(date.valueOf()) ? null : date.toISOString();
  }
  const raw = string(value);
  if (raw === null) return null;
  const date = new Date(raw);
  return Number.isNaN(date.valueOf()) ? null : date.toISOString();
}

export function textBlock(text: unknown): HistoryContentBlock | null {
  const value = string(text);
  return value === null ? null : { type: "text", text: value };
}

export function contentBlocks(value: unknown): HistoryContentBlock[] {
  if (typeof value === "string") {
    const block = textBlock(value);
    return block === null ? [] : [block];
  }
  const result: HistoryContentBlock[] = [];
  for (const item of array(value)) {
    const part = object(item);
    const type = string(part.type);
    if (type === "text" || type === "input_text" || type === "output_text") {
      const block = textBlock(part.text);
      if (block) result.push(block);
    } else if (type === "thinking" || type === "reasoning" || type === "reasoning_text") {
      const text = string(part.thinking) ?? string(part.text);
      if (text) result.push({ type: "reasoning", text });
    } else if (type === "tool_use" || type === "tool_call") {
      result.push({
        type: "tool_call",
        toolName: string(part.name) ?? "tool",
        toolCallId: string(part.id) ?? string(part.call_id),
        input: part.input ?? part.arguments ?? null,
      });
    } else if (type === "tool_result") {
      result.push({
        type: "tool_result",
        toolCallId: string(part.tool_use_id) ?? string(part.toolCallId),
        output: part.content ?? part.output ?? null,
        isError: part.is_error === true || part.isError === true,
      });
    } else if (type === "image" || type === "input_image") {
      const source = object(part.source);
      const dataUrl =
        string(part.image_url) ??
        string(part.url) ??
        (string(source.data) && string(source.media_type)
          ? `data:${source.media_type};base64,${source.data}`
          : null);
      if (dataUrl) result.push({ type: "image", dataUrl });
    }
  }
  return result;
}

export function message(
  recordNumber: number,
  role: HistoryMessage["role"],
  blocks: HistoryContentBlock[],
  at: unknown = null,
  model: unknown = null,
  ordinal = 0,
): HistoryMessage | null {
  if (blocks.length === 0) return null;
  return {
    id: `${recordNumber}:${ordinal}`,
    sequence: recordNumber,
    role,
    timestamp: timestamp(at),
    model: string(model),
    blocks,
  };
}

export function firstUserTitle(messages: readonly HistoryMessage[]): string {
  for (const item of messages) {
    if (item.role !== "user") continue;
    const text = item.blocks.find((block) => block.type === "text");
    if (text?.type === "text") return text.text.trim().slice(0, 90);
  }
  return "";
}
