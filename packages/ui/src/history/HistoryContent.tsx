import { useEffect, useMemo, useState } from "react";
import { AlertCircle, ChevronDown, ChevronRight, Image as ImageIcon, Wrench } from "lucide-react";
import { MessageResponse } from "../components/ai-elements/message.js";
import { Button } from "../components/ui/button.js";
import type {
  HistoryContentBlock,
  HistoryLocale,
  HistoryMessage,
  HistoryTokenUsage,
} from "./contract.js";
import { formatHistoryTime, historyLabels } from "./labels.js";
import {
  containsHistoryQuery,
  formatHistoryPayload,
  highlightSegments,
  looksLikePatch,
  matchExcerpt,
} from "./reader-utils.js";

const INITIAL_VISIBLE_CHARS = 16_000;
const NEXT_VISIBLE_CHARS = 16_000;

function boundedEnd(text: string, proposed: number): number {
  const end = Math.min(text.length, proposed);
  const last = text.charCodeAt(end - 1);
  return last >= 0xd800 && last <= 0xdbff ? Math.min(end + 1, text.length) : end;
}

function HighlightedText({
  text,
  query,
  locale,
  active,
}: {
  text: string;
  query: string;
  locale: HistoryLocale;
  active: boolean;
}) {
  return highlightSegments(text, query, locale).map((segment, index) =>
    segment.match ? (
      <mark
        key={index}
        className={
          active ? "bg-find-highlight-active text-foreground" : "bg-find-highlight text-foreground"
        }
      >
        {segment.text}
      </mark>
    ) : (
      <span key={index}>{segment.text}</span>
    ),
  );
}

function HistoryText({
  text,
  locale,
  query,
  active,
}: {
  text: string;
  locale: HistoryLocale;
  query: string;
  active: boolean;
}) {
  const [visibleChars, setVisibleChars] = useState(INITIAL_VISIBLE_CHARS);
  const labels = historyLabels(locale);
  useEffect(() => setVisibleChars(INITIAL_VISIBLE_CHARS), [text]);
  const end = boundedEnd(text, visibleChars);
  const visible = end < text.length ? text.slice(0, end) : text;
  const excerpt = active ? matchExcerpt(text, query, locale, end) : null;
  return (
    <div className="min-w-0 break-words text-ui-base">
      {excerpt ? (
        <div className="mb-2 rounded-md border border-border bg-surface px-3 py-2">
          <span className="text-ui-xs text-foreground-subtle">{labels.matchExcerpt}</span>
          <pre className="whitespace-pre-wrap break-words font-sans text-ui-base">
            <HighlightedText text={excerpt} query={query} locale={locale} active />
          </pre>
        </div>
      ) : null}
      {!query && text.length <= INITIAL_VISIBLE_CHARS ? (
        <MessageResponse>{text}</MessageResponse>
      ) : (
        <pre className="whitespace-pre-wrap break-words font-sans text-ui-base leading-relaxed">
          <HighlightedText text={visible} query={query} locale={locale} active={active} />
        </pre>
      )}
      {end < text.length ? (
        <Button
          variant="ghost"
          size="sm"
          className="mt-2"
          onClick={() => setVisibleChars((current) => current + NEXT_VISIBLE_CHARS)}
        >
          {labels.showMore} · {(text.length - end).toLocaleString(locale)} {labels.remainingChars}
        </Button>
      ) : null}
    </div>
  );
}

function ToolPayload({
  text,
  locale,
  query,
  active,
}: {
  text: string;
  locale: HistoryLocale;
  query: string;
  active: boolean;
}) {
  const labels = historyLabels(locale);
  const [visibleChars, setVisibleChars] = useState(INITIAL_VISIBLE_CHARS);
  useEffect(() => setVisibleChars(INITIAL_VISIBLE_CHARS), [text]);
  const end = boundedEnd(text, visibleChars);
  const visible = end < text.length ? text.slice(0, end) : text;
  const excerpt = active ? matchExcerpt(text, query, locale, end) : null;
  const patch = looksLikePatch(text);

  function renderCode(value: string) {
    if (!patch)
      return <HighlightedText text={value} query={query} locale={locale} active={active} />;
    return value.split("\n").map((line, index) => {
      const marker = line.trimStart();
      const color =
        marker.startsWith("+") && !marker.startsWith("+++")
          ? "text-diff-added"
          : marker.startsWith("-") && !marker.startsWith("---")
            ? "text-diff-removed"
            : "";
      return (
        <span key={index} className={`block ${color}`}>
          <HighlightedText text={line || " "} query={query} locale={locale} active={active} />
        </span>
      );
    });
  }

  return (
    <div className="max-h-96 overflow-auto border-t border-border px-3 py-2">
      {excerpt ? (
        <div className="mb-2 rounded-md border border-border bg-surface px-2 py-1">
          <span className="text-ui-xs text-foreground-subtle">{labels.matchExcerpt}</span>
          <pre className="font-mono text-ui-sm whitespace-pre-wrap break-words">
            {renderCode(excerpt)}
          </pre>
        </div>
      ) : null}
      <pre className="font-mono text-ui-sm whitespace-pre-wrap break-words">
        {renderCode(visible)}
      </pre>
      {end < text.length ? (
        <Button
          variant="ghost"
          size="sm"
          onClick={() => setVisibleChars((current) => current + NEXT_VISIBLE_CHARS)}
        >
          {labels.showMore} · {(text.length - end).toLocaleString(locale)} {labels.remainingChars}
        </Button>
      ) : null}
    </div>
  );
}

function ToolBlock({
  block,
  locale,
  query,
  active,
}: {
  block: Extract<HistoryContentBlock, { type: "tool_call" | "tool_result" }>;
  locale: HistoryLocale;
  query: string;
  active: boolean;
}) {
  const [expanded, setExpanded] = useState(false);
  const labels = historyLabels(locale);
  const isCall = block.type === "tool_call";
  const title = isCall ? `${labels.toolCall} · ${block.toolName}` : labels.toolResult;
  const payload = isCall ? block.input : block.output;
  const text = useMemo(() => formatHistoryPayload(payload), [payload]);
  const visibleExpanded = expanded || (active && containsHistoryQuery(text, query, locale));
  return (
    <div className="overflow-hidden rounded-lg border border-border bg-card">
      <Button
        type="button"
        variant="ghost"
        className="h-auto min-h-8 w-full justify-start gap-2 rounded-md px-3 py-2 text-left text-ui-sm"
        aria-expanded={visibleExpanded}
        onClick={() => setExpanded((value) => !value)}
      >
        {visibleExpanded ? <ChevronDown className="size-4" /> : <ChevronRight className="size-4" />}
        <Wrench className="size-4" />
        <span className="min-w-0 flex-1 truncate">{title}</span>
        {!isCall && block.isError ? (
          <span className="flex items-center gap-1 text-ui-xs text-destructive">
            <AlertCircle className="size-3" />
            {labels.toolError}
          </span>
        ) : null}
      </Button>
      {visibleExpanded ? (
        <ToolPayload text={text} locale={locale} query={query} active={active} />
      ) : null}
    </div>
  );
}

function ContentBlock({
  block,
  locale,
  query,
  active,
}: {
  block: HistoryContentBlock;
  locale: HistoryLocale;
  query: string;
  active: boolean;
}) {
  const labels = historyLabels(locale);
  switch (block.type) {
    case "text":
      return <HistoryText text={block.text} locale={locale} query={query} active={active} />;
    case "reasoning":
      return (
        <details
          className="rounded-lg border border-border bg-surface px-3 py-2"
          open={active && containsHistoryQuery(block.text, query, locale) ? true : undefined}
        >
          <summary className="cursor-pointer text-ui-sm font-medium text-foreground-subtle">
            {labels.reasoning}
          </summary>
          <div className="mt-2 border-t border-border pt-2">
            <HistoryText text={block.text} locale={locale} query={query} active={active} />
          </div>
        </details>
      );
    case "tool_call":
    case "tool_result":
      return <ToolBlock block={block} locale={locale} query={query} active={active} />;
    case "image":
      return /^data:image\/(?:png|jpe?g|gif|webp|avif);base64,/i.test(block.dataUrl) ? (
        <img
          src={block.dataUrl}
          alt={labels.image}
          loading="lazy"
          className="max-h-96 max-w-full rounded-lg border border-border object-contain"
        />
      ) : (
        <span className="flex items-center gap-2 text-ui-sm text-foreground-subtle">
          <ImageIcon className="size-4" />
          {labels.unsupportedImage}
        </span>
      );
  }
}

export function HistoryUsageStats({
  usage,
  locale,
}: {
  usage: HistoryTokenUsage;
  locale: HistoryLocale;
}) {
  const labels = historyLabels(locale);
  const format = (value: number) => value.toLocaleString(locale);
  return (
    <span className="flex flex-wrap gap-x-2 gap-y-0.5 font-mono text-ui-xs text-foreground-subtle">
      <span>
        {labels.inputTokens} {format(usage.inputTokens)}
      </span>
      <span>
        {labels.outputTokens} {format(usage.outputTokens)}
      </span>
      {usage.cacheReadTokens > 0 ? (
        <span>
          {labels.cacheReadTokens} {format(usage.cacheReadTokens)}
        </span>
      ) : null}
      {usage.cacheWriteTokens > 0 ? (
        <span>
          {labels.cacheWriteTokens} {format(usage.cacheWriteTokens)}
        </span>
      ) : null}
    </span>
  );
}

export function HistoryMessageRow({
  message,
  locale,
  query,
  active,
}: {
  message: HistoryMessage;
  locale: HistoryLocale;
  query: string;
  active: boolean;
}) {
  const labels = historyLabels(locale);
  const role = labels[message.role];
  const time = formatHistoryTime(message.timestamp, locale);
  return (
    <article
      className={`rounded-xl border bg-card p-4 ${active ? "border-brand ring-1 ring-brand" : "border-card-border"}`}
      aria-label={`${role} ${message.sequence + 1}`}
      aria-current={active ? "true" : undefined}
    >
      <header className="mb-3 flex flex-wrap items-center gap-2 text-ui-xs text-foreground-subtle">
        <span className="font-semibold text-foreground">{role}</span>
        <span>#{message.sequence + 1}</span>
        {time ? <time dateTime={message.timestamp ?? undefined}>{time}</time> : null}
        {message.model ? <span className="font-mono">{message.model}</span> : null}
        {message.usage ? <HistoryUsageStats usage={message.usage} locale={locale} /> : null}
      </header>
      <div className="flex min-w-0 flex-col gap-3">
        {message.blocks.map((block, index) => (
          <ContentBlock
            key={`${message.id}:${index}`}
            block={block}
            locale={locale}
            query={query}
            active={active}
          />
        ))}
      </div>
    </article>
  );
}
