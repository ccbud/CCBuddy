import { describe, expect, it } from "vitest";
import { SETTINGS_TAB_ID, type WindowTabState } from "@/store/tabStore.js";
import {
  buildConnectedRemoteWorkspaceSessionTargets,
  shouldPublishCompleteWorkspaceSnapshot,
} from "./rootPlatformWorkspaceSync.js";

function workspace(overrides: Partial<WindowTabState>): WindowTabState {
  return {
    id: "workspace",
    kind: "workspace",
    workspacePath: "/project",
    label: "project",
    ...overrides,
  } as WindowTabState;
}

describe("ordinary remote session target sync", () => {
  it("publishes only connected identity scopes and preserves separate same-path sessions", () => {
    const tabs: WindowTabState[] = [
      { id: SETTINGS_TAB_ID, kind: "settings", label: "settings" },
      workspace({}),
      workspace({ workspaceIdentity: "remote:a", remoteSessionId: "session-a" }),
      workspace({ workspaceIdentity: "remote:b", remoteSessionId: "session-b" }),
      workspace({ workspaceIdentity: "remote:offline" }),
      workspace({ remoteSessionId: "session-without-identity" }),
    ];
    expect(buildConnectedRemoteWorkspaceSessionTargets({ tabs })).toEqual([
      { workspacePath: "/project", workspaceIdentity: "remote:a", remoteSessionId: "session-a" },
      { workspacePath: "/project", workspaceIdentity: "remote:b", remoteSessionId: "session-b" },
    ]);
    expect(buildConnectedRemoteWorkspaceSessionTargets({ tabs: [] })).toEqual([]);
  });

  it("waits for full tab restoration before publishing the complete target snapshot", () => {
    expect(shouldPublishCompleteWorkspaceSnapshot(false)).toBe(false);
    expect(shouldPublishCompleteWorkspaceSnapshot(true)).toBe(true);
  });
});
