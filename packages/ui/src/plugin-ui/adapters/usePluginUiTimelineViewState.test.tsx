// @vitest-environment jsdom
import { act, renderHook } from "@testing-library/react";
import type { ReactNode } from "react";
import { beforeEach, expect, it } from "vitest";
import { buildPluginUiSessionKey } from "../contract.js";
import { PluginUiSessionProvider } from "./PluginUiProviders.js";
import { usePluginUiTimelineViewState } from "./usePluginUiTimelineViewState.js";
import {
  getPluginUiRowDisposition,
  getPluginUiManualPin,
  resetPluginUiInstancesForTest,
  setPluginUiInstanceDerivation,
  setPluginUiManualPin,
} from "../app/pluginUiInstanceStore.js";
import type { PluginUiInstanceDerivation } from "../domain/pluginUiInstancePolicy.js";

const scope = { workspacePath: "/repo", workspaceIdentity: " host-one ", sessionId: "same" };
const derivation: PluginUiInstanceDerivation = {
  instances: [],
  byToolCallId: {
    current: { key: "surface", superseded: false, autoExpand: true, forcedInline: true },
    previous: { key: "surface", superseded: true, autoExpand: false, forcedInline: false },
  },
};
function wrapper({ children }: { children: ReactNode }) {
  return (
    <PluginUiSessionProvider
      {...scope}
      readOnly
      sendText={async () => undefined}
      uploadAttachment={async () => {
        throw new Error("not used");
      }}
    >
      {children}
    </PluginUiSessionProvider>
  );
}

beforeEach(resetPluginUiInstancesForTest);

it("publishes timeline policy to the card's workspace-scoped key and retains mounted data", () => {
  const { result, unmount } = renderHook(() => usePluginUiTimelineViewState(derivation), {
    wrapper,
  });
  const key = buildPluginUiSessionKey(scope);
  expect(result.current).toBe(key);
  expect(getPluginUiRowDisposition(key, "previous")?.superseded).toBe(true);
  expect(getPluginUiRowDisposition(key, "current")?.autoExpand).toBe(true);
  expect(getPluginUiRowDisposition(scope.sessionId, "current")).toBeUndefined();
  const otherWorkspace = buildPluginUiSessionKey({ ...scope, workspaceIdentity: "host-two" });
  expect(getPluginUiRowDisposition(otherWorkspace, "current")).toBeUndefined();
  act(() => {
    setPluginUiManualPin(key, "current", false);
    for (let i = 0; i < 40; i++) setPluginUiInstanceDerivation(`inactive-${i}`, derivation);
  });
  expect(getPluginUiManualPin(result.current!, "current")).toBe(false);
  expect(getPluginUiRowDisposition(key, "current")?.forcedInline).toBe(true);
  unmount();
  for (let i = 0; i < 30; i++) setPluginUiInstanceDerivation(`after-unmount-${i}`, derivation);
  expect(getPluginUiRowDisposition(key, "current")).toBeUndefined();
  expect(getPluginUiManualPin(key, "current")).toBeUndefined();
});
