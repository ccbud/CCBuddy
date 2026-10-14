import assert from "node:assert/strict";
import { test } from "node:test";
import { createDesktopTelemetryFetch } from "./desktopTelemetryFetch.js";

test("the Electron telemetry adapter serializes URL input and preserves request options", async () => {
  const calls: unknown[][] = [];
  const response = new Response("ok");
  const fetchImpl = createDesktopTelemetryFetch({
    fetch: async (...args) => {
      calls.push(args);
      return response;
    },
  });
  const init = { method: "POST", body: "payload" };
  assert.equal(await fetchImpl(new URL("https://example.invalid/telemetry"), init), response);
  assert.deepEqual(calls, [["https://example.invalid/telemetry", init]]);
});

test("the Electron telemetry adapter preserves Request input", async () => {
  const request = new Request("https://example.invalid/telemetry", { method: "POST" });
  let received: unknown;
  const fetchImpl = createDesktopTelemetryFetch({
    fetch: async (input) => {
      received = input;
      return new Response("ok");
    },
  });
  await fetchImpl(request);
  assert.equal(received, request);
});
