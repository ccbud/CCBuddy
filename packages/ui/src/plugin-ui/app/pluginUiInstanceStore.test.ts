import { beforeEach, describe, expect, it, vi } from "vitest";
import { buildPluginUiSessionKey } from "../contract.js";
import {
  EMPTY_PLUGIN_UI_INSTANCE_DERIVATION,
  type PluginUiInstanceDerivation,
} from "../domain/pluginUiInstancePolicy.js";
import {
  clearPluginUiSessionViewState,
  getPluginUiRowDisposition,
  resetPluginUiInstancesForTest,
  retainPluginUiSessionViewState,
  setPluginUiInstanceDerivation,
  subscribePluginUiInstances,
} from "./pluginUiInstanceStore.js";
import {
  getPluginUiDisclosureVersion,
  getPluginUiManualPin,
  setPluginUiManualPin,
  subscribePluginUiDisclosure,
} from "./pluginUiDisclosureStore.js";

const session = (id: string, workspaceIdentity = "workspace") =>
  buildPluginUiSessionKey({ workspacePath: "/repo", workspaceIdentity, sessionId: id });
const derivation: PluginUiInstanceDerivation = {
  instances: [{ key: "surface", activeToolCallId: "tool", supersededToolCallIds: [] }],
  byToolCallId: {
    tool: { key: "surface", superseded: false, autoExpand: true, forcedInline: false },
  },
};
function visit(key: string) {
  const release = retainPluginUiSessionViewState(key);
  setPluginUiInstanceDerivation(key, derivation);
  setPluginUiManualPin(key, "tool", false);
  release();
}
const fill = (count = 30) => {
  for (let i = 0; i < count; i++) visit(session(`filler-${i}`));
};

describe("plugin row view-cache retention", () => {
  beforeEach(resetPluginUiInstancesForTest);

  it("evicts derivations and disclosure pins together after 30 inactive sessions", () => {
    visit(session("old"));
    fill();
    expect(getPluginUiRowDisposition(session("old"), "tool")).toBeUndefined();
    expect(getPluginUiManualPin(session("old"), "tool")).toBeUndefined();
    expect(getPluginUiRowDisposition(session("filler-0"), "tool")).toBeDefined();
  });

  it("protects mounted sessions and requires the last of two leases to release", () => {
    const key = session("active");
    const releaseA = retainPluginUiSessionViewState(key);
    const releaseB = retainPluginUiSessionViewState(key);
    visit(key);
    releaseA();
    releaseA();
    fill(40);
    expect(getPluginUiManualPin(key, "tool")).toBe(false);
    releaseB();
    fill(40);
    expect(getPluginUiManualPin(key, "tool")).toBeUndefined();
  });

  it("preserves a revisited preference and restores defaults after eviction", () => {
    const key = session("return");
    visit(key);
    const release = retainPluginUiSessionViewState(key);
    expect(getPluginUiManualPin(key, "tool")).toBe(false);
    release();
    fill();
    const releaseAgain = retainPluginUiSessionViewState(key);
    setPluginUiInstanceDerivation(key, derivation);
    expect(getPluginUiManualPin(key, "tool")).toBeUndefined();
    expect(getPluginUiRowDisposition(key, "tool")?.autoExpand).toBe(true);
    releaseAgain();
  });

  it("treats a StrictMode cleanup/remount as a new lease and ignores stale cleanup", () => {
    const key = session("strict");
    const oldRelease = retainPluginUiSessionViewState(key);
    oldRelease();
    const release = retainPluginUiSessionViewState(key);
    visit(key);
    oldRelease();
    fill(40);
    expect(getPluginUiManualPin(key, "tool")).toBe(false);
    clearPluginUiSessionViewState(key);
    const newRelease = retainPluginUiSessionViewState(key);
    visit(key);
    release();
    fill(40);
    expect(getPluginUiManualPin(key, "tool")).toBe(false);
    newRelease();
  });

  it("isolates identical session/tool IDs by workspace identity and local path fallback", () => {
    const a = session("same", "a");
    const b = session("same", "b");
    visit(a);
    visit(b);
    clearPluginUiSessionViewState(a);
    expect(getPluginUiManualPin(a, "tool")).toBeUndefined();
    expect(getPluginUiManualPin(b, "tool")).toBe(false);
    expect(session("same", " ")).toBe(
      buildPluginUiSessionKey({ workspacePath: "/repo", sessionId: "same" }),
    );
  });

  it("defers page eviction until the final mounted lease releases without losing unchanged rows", () => {
    const key = session("mounted-offscreen");
    const release = retainPluginUiSessionViewState(key);
    const releaseOther = retainPluginUiSessionViewState(key);
    visit(key);
    const instances = vi.fn();
    const pins = vi.fn();
    subscribePluginUiInstances(instances);
    subscribePluginUiDisclosure(pins);
    clearPluginUiSessionViewState(key);
    clearPluginUiSessionViewState(key);
    expect(getPluginUiRowDisposition(key, "tool")).toBe(derivation.byToolCallId.tool);
    expect(getPluginUiManualPin(key, "tool")).toBe(false);
    release();
    release();
    expect(instances).not.toHaveBeenCalled();
    expect(pins).not.toHaveBeenCalled();
    fill(40);
    expect(getPluginUiRowDisposition(key, "tool")).toBe(derivation.byToolCallId.tool);
    expect(getPluginUiManualPin(key, "tool")).toBe(false);
    instances.mockClear();
    pins.mockClear();
    releaseOther();
    releaseOther();
    expect(getPluginUiRowDisposition(key, "tool")).toBeUndefined();
    expect(getPluginUiManualPin(key, "tool")).toBeUndefined();
    expect(instances).toHaveBeenCalledOnce();
    expect(pins).toHaveBeenCalledOnce();
  });

  it("notifies disposition-only eviction when the admitted derivation is empty", () => {
    const key = session("old-disposition");
    setPluginUiInstanceDerivation(key, derivation);
    for (let i = 0; i < 29; i++) setPluginUiInstanceDerivation(session(`plain-${i}`), derivation);
    const instances = vi.fn();
    subscribePluginUiInstances(instances);
    setPluginUiInstanceDerivation(session("empty"), EMPTY_PLUGIN_UI_INSTANCE_DERIVATION);
    expect(getPluginUiRowDisposition(key, "tool")).toBeUndefined();
    expect(instances).toHaveBeenCalledOnce();
  });

  it("notifies removals once and snapshot reads neither notify nor refresh recency", () => {
    const key = session("old");
    visit(key);
    const instances = vi.fn(() => getPluginUiRowDisposition(key, "tool"));
    const pins = vi.fn(() => getPluginUiManualPin(key, "tool"));
    subscribePluginUiInstances(instances);
    subscribePluginUiDisclosure(pins);
    const version = getPluginUiDisclosureVersion();
    getPluginUiRowDisposition(key, "tool");
    getPluginUiManualPin(key, "tool");
    expect(getPluginUiDisclosureVersion()).toBe(version);
    expect(pins).not.toHaveBeenCalled();
    clearPluginUiSessionViewState(key);
    clearPluginUiSessionViewState(key);
    expect(instances).toHaveBeenCalledTimes(1);
    expect(pins).toHaveBeenCalledTimes(1);
    visit(key);
    for (let i = 0; i < 30; i++) {
      getPluginUiManualPin(key, "tool");
      visit(session(`read-filler-${i}`));
    }
    expect(getPluginUiManualPin(key, "tool")).toBeUndefined();
  });
});
