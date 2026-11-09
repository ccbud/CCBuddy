import { describe, expect, it } from "vitest";
import { searchTools } from "../src/tool/search/search.js";
import { buildToolExposure, resolveToolSearchMode } from "../src/tool/search/exposure.js";
import { collectDiscoveredTools } from "../src/tool/search/history.js";
import type { Model, ModelToolContract } from "@ccbuddy/contracts";

const catalog = [
  { name: "Read", aliases: ["read_file"], deferred: false, description: "Read files" },
  { name: "WebFetch", deferred: true, description: "Fetch content from URL" },
  { name: "mcp__slack__send", deferred: true, description: "Send messages" },
  { name: "mcp__slack__search", deferred: true, description: "Search messages" },
];
const model = {
  properties: { supportsToolCall: true },
  requestCapabilities: { toolSearch: { protocolSupported: true, defaultEnabled: false } },
} as Model;

describe("ToolSearch bounded discovery", () => {
  it("selects canonical names and explicit aliases without exposing unknown tools", () => {
    expect(searchTools("select:WebFetch,read_file,missing,WebFetch", catalog, 1)).toEqual([
      "WebFetch",
      "Read",
    ]);
    expect(searchTools("select:read", catalog)).toEqual([]);
    expect(searchTools("slack", catalog)).toEqual(["mcp__slack__send", "mcp__slack__search"]);
    expect(searchTools("+slack search", catalog)).toEqual([
      "mcp__slack__search",
      "mcp__slack__send",
    ]);
    expect(searchTools("^(a+)+$", catalog)).toEqual([]);
  });

  it("makes BYOK auto local and validates explicit native capability", () => {
    expect(resolveToolSearchMode(model, "off")).toBe("off");
    expect(resolveToolSearchMode(model, "auto")).toBe("local");
    expect(resolveToolSearchMode(model, "native")).toBe("native");
    expect(() =>
      resolveToolSearchMode({ ...model, requestCapabilities: undefined }, "native"),
    ).toThrow(/Anthropic/);
  });

  it("discovers only successful canonical references without altering raw history", () => {
    const entries = [
      {
        message: {
          role: "tool" as const,
          toolName: "ToolSearch",
          toolCallId: "search",
          content: [{ type: "tool_reference" as const, toolName: "WebFetch" }],
        },
      },
    ];
    expect([...collectDiscoveredTools(entries)]).toEqual(["WebFetch"]);
    const before = structuredClone(entries);
    const tools = ["ToolSearch", "DeferredToolCall", "Read", "WebFetch"].map((name) => ({
      name,
      description: name,
      inputSchema: { type: "object", properties: {} },
    })) as ModelToolContract[];
    const registry = {
      get: (name: string) => ({ metadata: { shouldDefer: name === "WebFetch" } }),
    } as never;
    const native = buildToolExposure({ model, mode: "native", tools, registry, entries });
    expect(native.tools.find((tool) => tool.name === "WebFetch")?.deferLoading).toBe(true);
    const local = buildToolExposure({ model, mode: "local", tools, registry, entries });
    expect(local.tools.map((tool) => tool.name)).toEqual([
      "LocalToolSearch",
      "DeferredToolCall",
      "Read",
    ]);
    expect(entries).toEqual(before);
  });
});
