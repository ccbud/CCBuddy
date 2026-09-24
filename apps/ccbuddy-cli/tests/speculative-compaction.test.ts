import assert from "node:assert/strict";
import { setImmediate } from "node:timers/promises";
import { test } from "node:test";
import type { RuntimeMessageEntry } from "../packages/core/src/agent/message-history.js";
import {
  buildSecondPassEntries,
  discardSpeculativeCompaction,
  startSpeculativeCompaction,
  takeSpeculativeCompaction,
} from "../packages/core/src/runtime/methods/speculative-compaction.js";

const prefix: RuntimeMessageEntry = { message: { role: "system", content: "Current context" } };
const firstUser: RuntimeMessageEntry = { message: { role: "user", content: "First question" } };
const firstAssistant: RuntimeMessageEntry = {
  message: { role: "assistant", content: "First answer" },
};
const laterUser: RuntimeMessageEntry = { message: { role: "user", content: "Later question" } };
const sourceEntries = [prefix, firstUser, firstAssistant];
const model = { id: "user-configured-model" };

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

test("matching completed prepass is reused once and preserves current prefix plus new tail", async () => {
  const owner = {};
  let runs = 0;
  startSpeculativeCompaction(owner, {
    entries: sourceEntries,
    instructions: "Summarize",
    model,
    run: async () => {
      runs += 1;
      return "First answer, summarized";
    },
  });
  await setImmediate();

  const laterEntries = [...sourceEntries, laterUser];
  startSpeculativeCompaction(owner, {
    entries: laterEntries,
    instructions: "Summarize",
    model,
    run: async () => {
      runs += 1;
      return "Unexpected duplicate";
    },
  });
  assert.equal(runs, 1);
  const prepared = takeSpeculativeCompaction(owner, {
    entries: laterEntries,
    instructions: "Summarize",
    model,
  });
  assert.deepEqual(prepared, {
    entryCount: sourceEntries.length,
    summary: "First answer, summarized",
  });
  assert.deepEqual(buildSecondPassEntries(laterEntries, 1, prepared!), [
    prefix,
    {
      message: {
        role: "user",
        content:
          "Earlier conversation summary (first compaction pass):\n\nFirst answer, summarized",
      },
    },
    laterUser,
  ]);
  assert.equal(
    takeSpeculativeCompaction(owner, { entries: laterEntries, instructions: "Summarize", model }),
    undefined,
  );
});

test("changed content, model instance, or instructions cannot reuse a summary", async () => {
  for (const mismatch of ["content", "model", "instructions"] as const) {
    const owner = {};
    startSpeculativeCompaction(owner, {
      entries: sourceEntries,
      instructions: "Summarize",
      model,
      run: async () => "Old summary",
    });
    await setImmediate();
    const current = {
      entries:
        mismatch === "content"
          ? [
              prefix,
              { message: { role: "user" as const, content: "Changed question" } },
              firstAssistant,
            ]
          : sourceEntries,
      instructions: mismatch === "instructions" ? "Different instructions" : "Summarize",
      model: mismatch === "model" ? { id: model.id } : model,
    };
    assert.equal(takeSpeculativeCompaction(owner, current), undefined, mismatch);
  }
});

test("pending or failed prepass falls back and late results stay unusable", async () => {
  const pendingOwner = {};
  const pending = deferred<string>();
  let pendingSignal: AbortSignal | undefined;
  startSpeculativeCompaction(pendingOwner, {
    entries: sourceEntries,
    instructions: "Summarize",
    model,
    run: async (signal) => {
      pendingSignal = signal;
      return pending.promise;
    },
  });
  await setImmediate();
  assert.equal(
    takeSpeculativeCompaction(pendingOwner, {
      entries: sourceEntries,
      instructions: "Summarize",
      model,
    }),
    undefined,
  );
  assert.equal(pendingSignal?.aborted, true);
  pending.resolve("Late summary");
  await setImmediate();
  assert.equal(
    takeSpeculativeCompaction(pendingOwner, {
      entries: sourceEntries,
      instructions: "Summarize",
      model,
    }),
    undefined,
  );

  const failedOwner = {};
  let failures = 0;
  startSpeculativeCompaction(failedOwner, {
    entries: sourceEntries,
    instructions: "Summarize",
    model,
    run: async () => {
      throw new Error("provider unavailable");
    },
    onFailure: () => {
      failures += 1;
    },
  });
  await setImmediate();
  assert.equal(failures, 1);
  assert.equal(
    takeSpeculativeCompaction(failedOwner, {
      entries: sourceEntries,
      instructions: "Summarize",
      model,
    }),
    undefined,
  );
});

test("cancellation and close invalidate pending prepasses, including compatible later turns", async () => {
  const owner = {};
  const pending = deferred<string>();
  const firstTurn = new AbortController();
  const nextTurn = new AbortController();
  startSpeculativeCompaction(owner, {
    entries: sourceEntries,
    instructions: "Summarize",
    model,
    signal: firstTurn.signal,
    run: async () => pending.promise,
  });
  await setImmediate();
  startSpeculativeCompaction(owner, {
    entries: [...sourceEntries, laterUser],
    instructions: "Summarize",
    model,
    signal: nextTurn.signal,
    run: async () => "Should not start another request",
  });
  nextTurn.abort();
  pending.resolve("Late summary after cancellation");
  await setImmediate();
  assert.equal(
    takeSpeculativeCompaction(owner, {
      entries: [...sourceEntries, laterUser],
      instructions: "Summarize",
      model,
    }),
    undefined,
  );

  const closingOwner = {};
  const closing = deferred<string>();
  startSpeculativeCompaction(closingOwner, {
    entries: sourceEntries,
    instructions: "Summarize",
    model,
    run: async () => closing.promise,
  });
  await setImmediate();
  discardSpeculativeCompaction(closingOwner);
  closing.resolve("Late summary after close");
  await setImmediate();
  assert.equal(
    takeSpeculativeCompaction(closingOwner, {
      entries: sourceEntries,
      instructions: "Summarize",
      model,
    }),
    undefined,
  );
});
