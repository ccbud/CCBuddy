import { describe, expect, it } from "vitest";
import {
  shouldBlockRootRender,
  shouldResolveProviderStartupState,
  shouldShowRootStartupLoading,
} from "./rootStartupGate.js";

const ready = {
  isResolvingStartupAuthState: false,
  isResolvingProviderStartupState: false,
  isRestoring: false,
  isBootstrappingInitialWorkspace: false,
};

describe("ordinary startup gate", () => {
  it("blocks each unresolved startup stage and releases the ready shell", () => {
    expect(shouldBlockRootRender(ready)).toBe(false);
    for (const stage of Object.keys(ready))
      expect(shouldBlockRootRender({ ...ready, [stage]: true })).toBe(true);
  });

  it("does not cover the welcome screen or ordinary Web with desktop startup loading", () => {
    const restoring = { ...ready, isRestoring: true, welcomeScreenOpen: false };
    expect(shouldShowRootStartupLoading({ ...restoring, isDesktop: true })).toBe(true);
    expect(
      shouldShowRootStartupLoading({ ...restoring, isDesktop: true, welcomeScreenOpen: true }),
    ).toBe(false);
    expect(shouldShowRootStartupLoading({ ...restoring, isDesktop: false })).toBe(false);
  });

  it("resolves provider startup until hydration and the availability check finish", () => {
    expect(
      shouldResolveProviderStartupState({
        providerStartupSyncPending: true,
        providerAvailabilityStartupCheckCompleted: true,
      }),
    ).toBe(true);
    expect(
      shouldResolveProviderStartupState({
        providerStartupSyncPending: false,
        providerAvailabilityStartupCheckCompleted: false,
      }),
    ).toBe(true);
    expect(
      shouldResolveProviderStartupState({
        providerStartupSyncPending: false,
        providerAvailabilityStartupCheckCompleted: true,
      }),
    ).toBe(false);
  });
});
