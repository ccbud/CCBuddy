import assert from "node:assert/strict";
import { createServer, type IncomingHttpHeaders } from "node:http";
import { test } from "node:test";
import { ModelRequestSessionType, runWithModelInvocationContext } from "../packages/contracts/dist/index.js";
import { createRuntimeAiSdkModelExecutionConfig } from "../packages/bootstrap/src/model-config.js";
import { createModelAdapter } from "../packages/bootstrap/src/model-factory.js";

test("a BYOK model request sends CCbuddy identity and attribution to the configured endpoint", async () => {
  const received: Array<{ headers: IncomingHttpHeaders; path: string | undefined }> = [];
  const server = createServer((request, response) => {
    received.push({ headers: request.headers, path: request.url });
    request.resume();
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({
      id: "chatcmpl-local",
      object: "chat.completion",
      created: 1,
      model: "local-test-model",
      choices: [{ index: 0, message: { role: "assistant", content: "ok" }, finish_reason: "stop" }],
      usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
    }));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));

  try {
    const address = server.address();
    assert.ok(address && typeof address !== "string");
    const baseUrl = `http://127.0.0.1:${address.port}/v1`;
    const adapter = createModelAdapter({
      env: {},
      executionConfig: createRuntimeAiSdkModelExecutionConfig({}, {
        appVersion: "1.2.3",
        sourceTitle: "cli",
      }),
    });
    const model = adapter.createModel({
      providerId: "local-user-provider",
      modelId: "local-test-model",
      providerConfig: {
        access: { type: "api-key", apiKey: "local-fixture-key" },
        api: { type: "openai-chat-completions", baseUrl },
      } as Parameters<typeof adapter.createModel>[0]["providerConfig"],
      modelConfig: {
        properties: {
          contextWindow: 8192,
          inputFormat: {
            supportsText: true, supportsImage: false, supportsVideo: false,
            supportsAudio: false, supportsPdf: false,
          },
          outputFormat: { supportsText: true },
          supportsToolCall: false,
          supportsJsonSchemaOutput: false,
          supportsNativeWebSearch: false,
          supportsMidConversationSystem: false,
          requiresMfjsToolSchema: false,
        },
        optionSpecs: {
          reasoningLevel: { values: ["disabled"], map: "{}" },
          maxOutputTokens: { max: 1024, map: "{}" },
        },
      } as Parameters<typeof adapter.createModel>[0]["modelConfig"],
      options: { maxOutputTokens: 32, reasoningLevel: "disabled" },
    });

    await runWithModelInvocationContext({
      modelRequestSessionType: ModelRequestSessionType.Main,
      traceContext: { traceId: "fixture-trace", sessionId: "sess_fixture-session" } as NonNullable<
        Parameters<typeof runWithModelInvocationContext>[0]["traceContext"]
      >,
    }, () => model.generateText({ messages: [{ role: "user", content: "hello" }] }));

    assert.equal(received.length, 1);
    const { headers, path } = received[0]!;
    assert.equal(path, "/v1/chat/completions");
    assert.equal(headers.authorization, "Bearer local-fixture-key");
    assert.match(String(headers["user-agent"]), /^CCbuddy\/1\.2\.3(?:\s|$)/i);
    assert.match(String(headers["x-title"]), /^CCbuddy@cli$/i);
    assert.match(String(headers["http-referer"]), /ccbuddy/i);
    assert.equal(headers["x-ccbuddy-trace-id"], "fixture-trace");
    assert.equal(headers["x-ccbuddy-session-type"], "main");
    assert.equal(headers["x-session-id"], "fixture-session");
    assert.equal(headers["x-ccbuddy-app-version"], "1.2.3");
    assert.equal(headers["x-ccbuddy-agent"], "glm");
  } finally {
    await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
});
