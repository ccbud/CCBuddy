import assert from "node:assert/strict";
import { test } from "node:test";
import {
  getCurrentModelInvocationContext,
  type Model,
  type ModelInvocationContext,
  type ModelStreamEvent,
  type TraceContext,
} from "../packages/core/src/runtime/deps.js";
import { runCompactSummaryModelRequest } from "../packages/core/src/runtime/methods/compact-summary-model-request.js";

for (const fallback of [false, true]) {
  test(`compact request preserves speculative session attribution through ${fallback ? "HTTP fallback" : "streaming"}`, async () => {
    const observed: (ModelInvocationContext | undefined)[] = [];
    const traceContext = { traceId: "fixture-compact-trace" } as TraceContext;
    const model = {
      providerId: "fixture-provider",
      modelId: "fixture-model",
      async *streamText(): AsyncIterable<ModelStreamEvent> {
        observed.push(getCurrentModelInvocationContext());
        if (fallback) throw new Error("Stream ended before any content was committed");
        yield { type: "text_start", id: "summary" };
        yield { type: "text_delta", id: "summary", text: "Context summary" };
        yield { type: "text_end", id: "summary" };
        yield { type: "finish", finishReason: "stop", usage: { totalTokens: 1 } };
      },
      async generateText() {
        observed.push(getCurrentModelInvocationContext());
        return { text: "Context summary", finishReason: "stop", usage: { totalTokens: 1 } };
      },
    } as unknown as Model;
    const result = await runCompactSummaryModelRequest({
      model,
      request: {
        messages: [{ role: "user", content: "Summarize the current context" }],
        modelRequestSessionType: "main",
        traceContext,
      },
    });
    assert.equal(result.text, "Context summary");
    assert.equal(observed.length, fallback ? 2 : 1);
    for (const context of observed) {
      assert.equal(context?.modelRequestSessionType, "main");
      assert.equal(context?.traceContext, traceContext);
    }
    if (fallback) {
      assert.equal(observed[1]?.modelCall?.callCause, "fallback_replacement");
      assert.equal(
        observed[1]?.modelCall?.previousLogicalCallId,
        observed[0]?.modelCall?.logicalCallId,
      );
    }
  });
}
