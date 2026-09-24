import type { HistoryMessage, HistoryTokenUsage } from "../contract.js";
import { firstUserTitle } from "./value.js";

function addUsage(total: HistoryTokenUsage, item: HistoryTokenUsage, sign: 1 | -1): void {
  total.inputTokens += sign * item.inputTokens;
  total.outputTokens += sign * item.outputTokens;
  total.cacheReadTokens += sign * item.cacheReadTokens;
  total.cacheWriteTokens += sign * item.cacheWriteTokens;
}

/** Metadata scans retain counts and bounded title text, not transcript bodies. */
export class MessageCollector {
  readonly messages: HistoryMessage[] = [];
  count = 0;
  title = "";
  usage: HistoryTokenUsage | null = null;

  constructor(readonly mode: "metadata" | "detail") {}

  add(item: HistoryMessage | null): number {
    if (!item) return -1;
    this.count += 1;
    if (!this.title && item.role === "user") this.title = firstUserTitle([item]);
    this.replaceUsage(null, item.usage ?? null);
    if (this.mode === "detail") {
      this.messages.push(item);
      return this.messages.length - 1;
    }
    return -1;
  }

  replaceUsage(previous: HistoryTokenUsage | null, next: HistoryTokenUsage | null): void {
    if (!previous && !next) return;
    this.usage ??= { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0 };
    if (previous) addUsage(this.usage, previous, -1);
    if (next) addUsage(this.usage, next, 1);
  }
}
