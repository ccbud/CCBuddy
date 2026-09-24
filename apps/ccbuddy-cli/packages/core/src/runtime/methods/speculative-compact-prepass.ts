import {
  CompactTrigger,
  MAX_OUTPUT_TOKENS_FOR_SUMMARY,
  buildCompactPrompt,
  createChildTraceContext,
  traceContextToLogContext,
} from "../deps.js";
import type { Model, TraceContext } from "../deps.js";
import type { AutoCompactDecision } from "../../compact/policy.js";
import type { RuntimeMessageEntry } from "../../agent/message-history.js";
import type { AgentRuntimeInternal } from "../internal.js";
import { hasEnoughRuntimeEntriesToCompact, selectCompactEntries } from "../helpers/index.js";
import {
  buildCompactSummaryRequestMessages,
  formatCompactSummaryOrThrow,
} from "./compact-active-helpers.js";
import { runCompactSummaryModelRequest } from "./compact-summary-model-request.js";
import { createRefreshRuntimeHeadersBeforeModelAttempt } from "./model-runtime-headers.js";
import { resolveModelRequestSessionTypeFromTaskType } from "./model-request-session-type.js";
import { startSpeculativeCompaction } from "./speculative-compaction.js";
import { recordModelUsageFact } from "./usage-observability.js";

const SPECULATIVE_COMPACT_THRESHOLD_RATIO = 0.8;

export function startAutoCompactPrepass(
  runtime: AgentRuntimeInternal,
  input: {
    abortSignal?: AbortSignal;
    activeEntries: readonly RuntimeMessageEntry[];
    decision: AutoCompactDecision;
    model: Model;
    traceContext: TraceContext;
  },
): void {
  if (
    runtime.shuttingDown ||
    input.decision.threshold <= 0 ||
    input.decision.tokenCount <
      Math.ceil(input.decision.threshold * SPECULATIVE_COMPACT_THRESHOLD_RATIO)
  ) {
    return;
  }
  const selection = selectCompactEntries({
    entries: input.activeEntries,
    trigger: CompactTrigger.Auto,
  });
  if (!hasEnoughRuntimeEntriesToCompact(selection.entriesForSummary)) return;
  const instructions = buildCompactPrompt(undefined);
  const model = input.model;
  const useMidConversationSystem =
    runtime.config.midConversationSystem?.mode === "force" ||
    model.properties.supportsMidConversationSystem;

  startSpeculativeCompaction(runtime, {
    entries: selection.entriesForSummary,
    instructions,
    model,
    signal: input.abortSignal,
    onFailure: (error) => {
      runtime.logger?.warn("Speculative compact prepass failed; final pass will use full history", {
        ...traceContextToLogContext(input.traceContext),
        event: "compact.prepass.failed",
        errorType: error instanceof Error ? error.name : typeof error,
      });
    },
    run: async (signal) => {
      const traceContext = createChildTraceContext(input.traceContext, {
        attributes: {
          model: `${model.providerId}/${model.modelId}`,
          querySource: "compact_prepass",
        },
      });
      const startedAt = Date.now();
      let result: Awaited<ReturnType<typeof runCompactSummaryModelRequest>> | undefined;
      try {
        result = await runCompactSummaryModelRequest({
          logger: runtime.logger,
          model,
          request: {
            abortSignal: signal,
            maxOutputTokens: Math.min(
              MAX_OUTPUT_TOKENS_FOR_SUMMARY,
              model.optionSpecs.maxOutputTokens.max,
            ),
            messages: buildCompactSummaryRequestMessages(
              selection.entriesForSummary,
              instructions,
              {
                useMidConversationSystem,
              },
            ),
            metadata: traceContextToLogContext(traceContext),
            modelRequestSessionType: resolveModelRequestSessionTypeFromTaskType(
              runtime.config.taskType,
            ),
            modelCall: {
              attributes: { compactionTrigger: "speculative_prepass" },
              operation: "context_compaction",
              operationId: `cmp_pre_${crypto.randomUUID()}`,
            },
            preserveProviderStreamBoundaries: true,
            refreshRuntimeHeadersBeforeAttempt: createRefreshRuntimeHeadersBeforeModelAttempt(
              runtime,
              {
                abortSignal: signal,
                model,
                traceContext,
              },
            ),
            tools: [],
            traceContext,
          },
        });
        const summary = formatCompactSummaryOrThrow(runtime, result);
        await recordModelUsageFact(runtime, {
          events: [],
          model,
          networkEventStartIndex: 0,
          querySource: "compact_prepass",
          result,
          startedAt,
          status: "completed",
          traceContext,
        });
        return summary;
      } catch (error) {
        await recordModelUsageFact(runtime, {
          error,
          events: [],
          model,
          networkEventStartIndex: 0,
          querySource: "compact_prepass",
          result,
          startedAt,
          status: signal.aborted ? "cancelled" : "error",
          traceContext,
        });
        throw error;
      }
    },
  });
}
