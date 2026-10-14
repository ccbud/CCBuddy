import { afterEach, describe, expect, it, vi } from "vitest";
import type { IPlatformService } from "@ccbuddy/shared";
import { createDesktopPlatform } from "./desktopPlatform.js";

vi.mock("@ccbuddy/ui", () => ({ recordArmsCustomEventForE2E: vi.fn() }));
vi.mock("./desktopBrowserPlatformBridge.js", () => ({ desktopBrowserPlatformBridge: {} }));
vi.mock("./plugin-sandbox/desktopPluginSandboxPlatform.js", () => ({
  createDesktopPluginSandboxPlatform: () => undefined,
}));

afterEach(() => vi.unstubAllGlobals());

describe("Desktop history platform integration", () => {
  it("exposes the separate preload bridge that enables calendar and session navigation", async () => {
    const snapshot = { protocolVersion: 1, sessions: [] };
    const detail = { id: "fixture-session", messages: [] };
    const terminal = { type: "terminal", status: "success", snapshot };
    const bridge = {
      protocolVersion: 1,
      list: vi.fn(async () => snapshot),
      load: vi.fn(async (_id: string) => detail),
      refresh: vi.fn(async () => terminal),
      onRefreshEvent: vi.fn(() => () => {}),
    } satisfies NonNullable<IPlatformService["historyReview"]>;
    vi.stubGlobal("window", { ccbuddy: {}, ccbuddyHistory: bridge });

    const platform = createDesktopPlatform({ isLocalDevelopmentRuntime: false });
    expect(platform.historyReview?.protocolVersion).toBe(1);
    expect(await platform.historyReview!.list()).toBe(snapshot);
    expect(await platform.historyReview!.load("fixture-session")).toBe(detail);
    expect(bridge.load).toHaveBeenCalledWith("fixture-session");
    expect(await platform.historyReview!.refresh()).toBe(terminal);
  });

  it("forwards history progress and preserves subscription cleanup", () => {
    let publish: ((event: unknown) => void) | undefined;
    const unsubscribe = vi.fn();
    vi.stubGlobal("window", {
      ccbuddy: {},
      ccbuddyHistory: {
        protocolVersion: 1,
        onRefreshEvent: (listener: (event: unknown) => void) => {
          publish = listener;
          return unsubscribe;
        },
      },
    });
    const platform = createDesktopPlatform({ isLocalDevelopmentRuntime: true });
    const listener = vi.fn();
    const dispose = platform.historyReview!.onRefreshEvent(listener);
    const event = { type: "progress", generation: 1 };
    publish!(event);
    expect(listener).toHaveBeenCalledWith(event);
    dispose();
    expect(unsubscribe).toHaveBeenCalledOnce();
  });

  it("forwards native menu requests for both views and subscription cleanup", () => {
    let publish: ((view: "list" | "timeline") => void) | undefined;
    const unsubscribe = vi.fn();
    vi.stubGlobal("window", {
      ccbuddy: {
        onOpenHistoryViewRequested: (listener: (view: "list" | "timeline") => void) => {
          publish = listener;
          return unsubscribe;
        },
      },
    });
    const platform = createDesktopPlatform({ isLocalDevelopmentRuntime: false });
    const listener = vi.fn();
    const dispose = platform.onOpenHistoryViewRequested!(listener);
    publish!("timeline");
    publish!("list");
    expect(listener.mock.calls).toEqual([["timeline"], ["list"]]);
    dispose();
    expect(unsubscribe).toHaveBeenCalledOnce();
  });

  it("keeps read failures visible to the history controller", async () => {
    const failure = new Error("Fixture history read failed");
    vi.stubGlobal("window", {
      ccbuddy: {},
      ccbuddyHistory: { protocolVersion: 1, list: () => Promise.reject(failure) },
    });
    const platform = createDesktopPlatform({ isLocalDevelopmentRuntime: false });
    await expect(platform.historyReview!.list()).rejects.toBe(failure);
  });

  it("does not invent history capability when the preload bridge is unavailable", () => {
    vi.stubGlobal("window", { ccbuddy: {} });
    const platform = createDesktopPlatform({ isLocalDevelopmentRuntime: false });
    expect(platform.historyReview).toBeUndefined();
    expect(() => platform.onOpenHistoryViewRequested!(vi.fn())()).not.toThrow();
  });
});
