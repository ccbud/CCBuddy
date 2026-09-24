import type { HistoryContentBlock, HistoryLocale, HistoryMessage } from "./contract.js";

function indent(value: string): string {
  return value
    .split("\n")
    .map((line) => `  ${line}`)
    .join("\n");
}

/** Preserve multiline tool and patch strings instead of JSON-escaping their line breaks. */
export function formatHistoryPayload(value: unknown): string {
  const seen = new WeakSet<object>();
  function format(item: unknown, depth: number): string {
    if (typeof item === "string") return item;
    if (item == null || typeof item !== "object") return String(item);
    if (seen.has(item)) return "[Circular]";
    if (depth >= 12) return "[Nested value]";
    seen.add(item);
    let formatted: string;
    if (Array.isArray(item)) {
      formatted = item.length
        ? item.map((entry, index) => `[${index}]\n${indent(format(entry, depth + 1))}`).join("\n")
        : "[]";
    } else {
      const entries = Object.entries(item);
      formatted = entries.length
        ? entries
            .map(([key, entry]) => {
              const rendered = format(entry, depth + 1);
              return rendered.includes("\n")
                ? `${key}:\n${indent(rendered)}`
                : `${key}: ${rendered}`;
            })
            .join("\n")
        : "{}";
    }
    seen.delete(item);
    return formatted;
  }
  return format(value, 0);
}

export function blockSearchText(block: HistoryContentBlock): string | null {
  switch (block.type) {
    case "text":
    case "reasoning":
      return block.text;
    case "tool_call":
      return formatHistoryPayload(block.input);
    case "tool_result":
      return formatHistoryPayload(block.output);
    case "image":
      return null;
  }
}

export function containsHistoryQuery(text: string, query: string, locale: HistoryLocale): boolean {
  return Boolean(query) && text.toLocaleLowerCase(locale).includes(query.toLocaleLowerCase(locale));
}

/** Results are message-level so navigation remains bounded by transcript length. */
export function findMatchingMessages(
  messages: readonly HistoryMessage[],
  query: string,
  locale: HistoryLocale,
): number[] {
  const needle = query.trim();
  if (!needle) return [];
  const matches: number[] = [];
  for (let index = 0; index < messages.length; index += 1) {
    const message = messages[index];
    if (
      message?.blocks.some((block) => {
        const text = blockSearchText(block);
        return text !== null && containsHistoryQuery(text, needle, locale);
      })
    ) {
      matches.push(index);
    }
  }
  return matches;
}

export interface HighlightSegment {
  text: string;
  match: boolean;
}

export function highlightSegments(
  text: string,
  query: string,
  locale: HistoryLocale,
  maxMatches = 200,
): HighlightSegment[] {
  const needle = query.trim();
  if (!needle || maxMatches <= 0) return [{ text, match: false }];
  const haystack = text.toLocaleLowerCase(locale);
  const lowerNeedle = needle.toLocaleLowerCase(locale);
  const segments: HighlightSegment[] = [];
  let cursor = 0;
  let count = 0;
  while (count < maxMatches) {
    const index = haystack.indexOf(lowerNeedle, cursor);
    if (index < 0) break;
    if (index > cursor) segments.push({ text: text.slice(cursor, index), match: false });
    const end = index + needle.length;
    segments.push({ text: text.slice(index, end), match: true });
    cursor = end;
    count += 1;
  }
  if (cursor < text.length) segments.push({ text: text.slice(cursor), match: false });
  return segments.length ? segments : [{ text, match: false }];
}

export function matchExcerpt(
  text: string,
  query: string,
  locale: HistoryLocale,
  visibleEnd: number,
): string | null {
  if (!query.trim()) return null;
  const index = text.toLocaleLowerCase(locale).indexOf(query.trim().toLocaleLowerCase(locale));
  if (index < visibleEnd || index < 0) return null;
  const start = Math.max(0, index - 120);
  const end = Math.min(text.length, index + query.trim().length + 240);
  return `${start > 0 ? "…" : ""}${text.slice(start, end)}${end < text.length ? "…" : ""}`;
}

export function looksLikePatch(text: string): boolean {
  return /^(?:\s*\*\*\* Begin Patch|\s*diff --git |\s*@@(?: |$))/m.test(text);
}
