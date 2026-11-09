import { expect, it } from "vitest";
import {
  resolveModelRequestCapabilities,
  resolveToolSearchCapability,
  toolSearchHeaders,
} from "../src/model/tool-search.js";

it("keeps BYOK native search opt-in and gates the protocol", () => {
  for (const apiType of ["anthropic-messages", "openai-chat-completions"]) {
    expect(resolveToolSearchCapability(apiType, { type: "api-key" })).toEqual({
      protocolSupported: apiType === "anthropic-messages",
      defaultEnabled: false,
    });
    expect(
      resolveModelRequestCapabilities(apiType, { type: "api-key" }).foldRemindersIntoToolResults,
    ).toBe(apiType === "anthropic-messages");
  }
});

it("merges native beta headers without changing non-native requests", () => {
  const headers = { "Anthropic-Beta": "existing-beta,advanced-tool-use-2025-11-20" };
  expect(toolSearchHeaders(headers, false)).toBe(headers);
  expect(toolSearchHeaders(headers, true)).toEqual(headers);
});
