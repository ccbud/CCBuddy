import { afterEach, expect, it, vi } from "vitest";
import { sandboxPages, type SandboxPageOwner } from "./sandboxPageOwners.js";
import { buildPluginUiSessionKey } from "../contract.js";
import {
  getPluginUiManualPin,
  getPluginUiRowDisposition,
  resetPluginUiInstancesForTest,
  retainPluginUiSessionViewState,
  setPluginUiInstanceDerivation,
  setPluginUiManualPin,
} from "../app/pluginUiInstanceStore.js";

afterEach(() => {
  sandboxPages.clear();
  resetPluginUiInstancesForTest();
  vi.useRealTimers();
});

it("removes paired view state with a page task while timeline release preserves the page", async () => {
  const task = buildPluginUiSessionKey({ workspacePath: "/repo", sessionId: "task" });
  const page: SandboxPageOwner = {
    kind: "mcp",
    key: "page",
    task,
    visible: true,
    busy: () => false,
    running: () => true,
    suspend: vi.fn(),
    destroy: vi.fn(),
  };
  await sandboxPages.add(page);
  const release = retainPluginUiSessionViewState(task);
  setPluginUiInstanceDerivation(task, {
    instances: [],
    byToolCallId: {
      tool: { key: "page", superseded: false, autoExpand: true, forcedInline: false },
    },
  });
  setPluginUiManualPin(task, "tool", false);
  release();
  expect(sandboxPages.get(page.key)).toBe(page);
  expect(page.destroy).not.toHaveBeenCalled();
  sandboxPages.removeTask(task);
  expect(page.destroy).toHaveBeenCalledOnce();
  expect(getPluginUiRowDisposition(task, "tool")).toBeUndefined();
  expect(getPluginUiManualPin(task, "tool")).toBeUndefined();
});
it("counts MCP and Gen UI against one capacity and deletes both for the same task", async () => {
  const pages: SandboxPageOwner[] = [];
  for (let index = 0; index < 64; index++) {
    const page: SandboxPageOwner = {
      kind: index % 2 ? "mcp" : "gen-ui",
      key: String(index),
      task: "shared-task",
      visible: true,
      busy: () => false,
      running: () => true,
      suspend: vi.fn(),
      destroy: vi.fn(),
    };
    pages.push(page);
    await sandboxPages.add(page);
    await sandboxPages.reserve(page);
  }
  const extra = { ...pages[0]!, key: "overflow" };
  await sandboxPages.add(extra);
  await expect(sandboxPages.reserve(extra)).rejects.toThrow("capacity");
  sandboxPages.removeTask("shared-task");
  for (const page of pages) {
    expect(page.destroy).toHaveBeenCalled();
    expect(sandboxPages.get(page.key)).toBeUndefined();
    sandboxPages.released(page);
  }
});
