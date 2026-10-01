import { describe, expect, it, vi } from "vitest";
import type { McpToolDescriptor, TraceContext } from "@ccbuddy/contracts";
import { ToolRegistryImpl } from "../../tool/registry.js";
import type { AgentRuntimeInternal } from "../internal.js";
import { initializeMcp, refreshMcpToolsIfChanged } from "./mcp.js";

vi.mock("../deps.js", async () => ({
  registerMcpTools: (await import("../../mcp/index.js")).registerMcpTools,
  traceContextToLogContext: () => ({}),
}));

const TOOL_NAME = "mcp__fixture__example";
const TRACE = { traceId: "trace", spanId: "span" } as TraceContext;
const descriptor: McpToolDescriptor = {
  serverName: "fixture",
  toolName: "example",
  description: "An example tool",
  inputSchema: { type: "object", properties: { query: { type: "string" } } },
  annotations: { readOnlyHint: true, destructiveHint: false },
  visibility: ["model", "app"],
  timeoutMs: 30_000,
  ui: { resourceUri: "ui://fixture/old", prefersBorder: true },
};

async function fixture(initial: McpToolDescriptor[] = [descriptor]) {
  let revision = 0;
  let descriptors = initial;
  const listTools = vi.fn(async () => descriptors);
  const invalidateToolCache = vi.fn();
  const registry = new ToolRegistryImpl();
  const runtime = {
    config: {},
    registry,
    mcpPort: { listTools, toolListRevision: () => revision },
    startMcpStartup: () => Promise.resolve({ statuses: {}, tools: initial }),
    invalidateToolCache,
  } as unknown as AgentRuntimeInternal;
  await initializeMcp.call(runtime, TRACE);
  invalidateToolCache.mockClear();
  return {
    runtime,
    registry,
    listTools,
    invalidateToolCache,
    notify(next: McpToolDescriptor[]) {
      descriptors = next;
      revision += 1;
    },
    refresh: () => refreshMcpToolsIfChanged.call(runtime, TRACE),
  };
}

describe("MCP descriptor refresh at turn boundaries", () => {
  const changes: {
    field: string;
    update: Partial<McpToolDescriptor>;
    verify: (registry: ToolRegistryImpl) => void;
  }[] = [
    {
      field: "inputSchema",
      update: { inputSchema: { type: "object", required: ["query"] } },
      verify: (registry) =>
        expect(registry.toContracts()[0]?.inputSchema.required).toEqual(["query"]),
    },
    {
      field: "annotations",
      update: { annotations: { readOnlyHint: false, destructiveHint: true } },
      verify: (registry) => {
        expect(registry.toContracts()[0]).toMatchObject({
          readOnly: false,
          destructive: true,
          concurrentSafe: false,
          permission: { riskLevel: "high" },
        });
      },
    },
    {
      field: "visibility",
      update: { visibility: ["app"] },
      verify: (registry) => expect(registry.toContracts()).toEqual([]),
    },
    {
      field: "timeoutMs",
      update: { timeoutMs: 90_000 },
      verify: (registry) => {
        expect(registry.toContracts()[0]?.timeoutMs).toBe(90_000);
        expect(registry.get(TOOL_NAME)?.timeout).toMatchObject({ defaultMs: 90_000 });
      },
    },
    {
      field: "ui",
      update: { ui: { resourceUri: "ui://fixture/new", prefersBorder: false } },
      verify: (registry) =>
        expect(registry.getMetadata(TOOL_NAME)?.mcpPresentation?.ui).toEqual({
          resourceUri: "ui://fixture/new",
          prefersBorder: false,
        }),
    },
    {
      field: "official",
      update: { official: true },
      verify: (registry) =>
        expect(registry.getMetadata(TOOL_NAME)?.mcpPresentation?.official).toBe(true),
    },
    {
      field: "outputSchema",
      update: { outputSchema: { type: "object", required: ["result"] } },
      verify: (registry) => {
        // MCP 输出沿用宿主 envelope；descriptor 更新不能误改既有 provider 输出契约。
        expect(registry.toContracts()[0]?.outputSchema.required).not.toContain("result");
      },
    },
  ];

  it.each(changes)("refreshes $field without changing names or descriptions", async (change) => {
    const f = await fixture();
    const original = f.registry.get(TOOL_NAME);
    f.notify([{ ...descriptor, ...change.update }]);
    expect(f.registry.get(TOOL_NAME)).toBe(original);
    expect(f.listTools).not.toHaveBeenCalled();

    await f.refresh();

    expect(f.registry.get(TOOL_NAME)).not.toBe(original);
    expect(f.invalidateToolCache).toHaveBeenCalledTimes(1);
    change.verify(f.registry);
    await f.refresh();
    expect(f.listTools).toHaveBeenCalledTimes(1);
    expect(f.invalidateToolCache).toHaveBeenCalledTimes(1);
  });

  it("exposes an app-only tool when visibility changes to model", async () => {
    const f = await fixture([{ ...descriptor, visibility: ["app"] }]);
    expect(f.registry.toContracts()).toEqual([]);
    f.notify([descriptor]);
    await f.refresh();
    expect(f.registry.toContracts().map((tool) => tool.name)).toEqual([TOOL_NAME]);
    expect(f.invalidateToolCache).toHaveBeenCalledTimes(1);
  });

  it("does not replace tools for identical descriptors or reordered tools and nested keys", async () => {
    const second = { ...descriptor, toolName: "another" };
    const f = await fixture([descriptor, second]);
    const original = f.registry.get(TOOL_NAME);
    f.notify([descriptor, second]);
    await f.refresh();
    const reordered: McpToolDescriptor = {
      ui: { prefersBorder: true, resourceUri: "ui://fixture/old" },
      timeoutMs: 30_000,
      visibility: ["model", "app"],
      annotations: { destructiveHint: false, readOnlyHint: true },
      inputSchema: { properties: { query: { type: "string" } }, type: "object" },
      description: descriptor.description,
      toolName: descriptor.toolName,
      serverName: descriptor.serverName,
    };
    f.notify([second, reordered]);
    await f.refresh();
    expect(f.registry.get(TOOL_NAME)).toBe(original);
    expect(f.invalidateToolCache).not.toHaveBeenCalled();
    expect(f.runtime.mcpToolListRevision).toBe(2);
  });

  it("preserves the significance of ordered arrays inside schemas", async () => {
    const tuple = [{ type: "string" }, { type: "number" }];
    const original = {
      ...descriptor,
      inputSchema: { type: "object", properties: { pair: { type: "array", prefixItems: tuple } } },
    };
    const f = await fixture([original]);
    f.notify([
      {
        ...original,
        inputSchema: {
          type: "object",
          properties: { pair: { type: "array", prefixItems: [...tuple].reverse() } },
        },
      },
    ]);
    await f.refresh();
    expect(f.invalidateToolCache).toHaveBeenCalledTimes(1);
    expect(f.registry.toContracts()[0]?.inputSchema).not.toEqual(original.inputSchema);
  });

  it("skips fetches without a new revision or an initialized registry", async () => {
    const f = await fixture();
    await f.refresh();
    expect(f.listTools).not.toHaveBeenCalled();
    f.notify([{ ...descriptor, visibility: ["app"] }]);
    f.runtime.mcpToolsRegistered = false;
    await f.refresh();
    expect(f.listTools).not.toHaveBeenCalled();
    f.runtime.mcpToolsRegistered = true;
    delete f.runtime.mcpPort!.toolListRevision;
    await f.refresh();
    expect(f.listTools).not.toHaveBeenCalled();
    expect(f.invalidateToolCache).not.toHaveBeenCalled();
  });

  it("does not consume a failed fetch and retries at the next boundary", async () => {
    const f = await fixture();
    f.notify([{ ...descriptor, visibility: ["app"] }]);
    f.listTools.mockRejectedValueOnce(new Error("fixture unavailable"));
    await f.refresh();
    expect(f.runtime.mcpToolListRevision).toBe(0);
    expect(f.invalidateToolCache).not.toHaveBeenCalled();
    await f.refresh();
    expect(f.listTools).toHaveBeenCalledTimes(2);
    expect(f.registry.toContracts()).toEqual([]);
  });

  it("keeps a notification received during a fetch pending for the next boundary", async () => {
    const f = await fixture();
    const pending = Promise.withResolvers<McpToolDescriptor[]>();
    const first = { ...descriptor, timeoutMs: 60_000 };
    f.notify([first]);
    f.listTools.mockImplementationOnce(() => pending.promise);
    const refresh = f.refresh();
    f.notify([{ ...descriptor, timeoutMs: 90_000 }]);
    pending.resolve([first]);
    await refresh;
    expect(f.runtime.mcpToolListRevision).toBe(1);
    expect(f.registry.toContracts()[0]?.timeoutMs).toBe(60_000);
    await f.refresh();
    expect(f.listTools).toHaveBeenCalledTimes(2);
    expect(f.runtime.mcpToolListRevision).toBe(2);
    expect(f.registry.toContracts()[0]?.timeoutMs).toBe(90_000);
  });
});
