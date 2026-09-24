import type { HistoryMessage, HistoryTokenUsage } from "../contract.js";
import { object } from "./value.js";

function nonnegative(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? Math.max(0, Math.trunc(value)) : 0;
}

export function tokenUsage(value: unknown): HistoryTokenUsage | null {
  const usage = object(value);
  if (Object.keys(usage).length === 0) return null;
  const cacheRead = nonnegative(
    usage.cache_read_input_tokens ?? usage.cached_input_tokens ?? usage.cache_read,
  );
  const cacheWrite = nonnegative(usage.cache_creation_input_tokens ?? usage.cache_creation);
  const input = nonnegative(usage.input_tokens ?? usage.inputTokens ?? usage.input);
  const output = nonnegative(usage.output_tokens ?? usage.outputTokens ?? usage.output);
  if (input + output + cacheRead + cacheWrite === 0) return null;
  return {
    inputTokens: input,
    outputTokens: output,
    cacheReadTokens: cacheRead,
    cacheWriteTokens: cacheWrite,
  };
}

export function totalUsage(messages: readonly HistoryMessage[]): HistoryTokenUsage | null {
  let total: HistoryTokenUsage | null = null;
  for (const message of messages) {
    if (!message.usage) continue;
    total ??= { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0 };
    total.inputTokens += message.usage.inputTokens;
    total.outputTokens += message.usage.outputTokens;
    total.cacheReadTokens += message.usage.cacheReadTokens;
    total.cacheWriteTokens += message.usage.cacheWriteTokens;
  }
  return total;
}
