import assert from "node:assert/strict";
import { test } from "node:test";
import { browserCommandResultSchema } from "@ccbuddy/shared";
import { deferred, fixture, pauseViewport } from "./browser-guest-manager-harness.mjs";

test("list omits a tab closed while its real summary awaits viewport", async () => {
  const { context, tab, manager, running } = fixture();
  const { entered, viewport } = pauseViewport(manager);
  const resultPromise = manager.executeInScope(context, { method: "list" }, running);
  await entered;
  manager.closeTab(tab);
  viewport.resolve({ width: 800, height: 600 });
  const result = await resultPromise;
  assert.equal(browserCommandResultSchema.safeParse(result).success, true);
  assert.equal(result.ok, true);
  assert.equal(result.tabs.length, 0);
  assert.equal(result.meta.openTabIds.length, 0);
});

test("list rechecks entries already read while another viewport is pending", async () => {
  const { context, tab, manager, running } = fixture();
  const other = { ...tab, tabId: "second-tab" };
  manager.tabs.set(other.tabId, other);
  const firstCompleted = deferred();
  const summary = manager.summary.bind(manager);
  manager.summary = async (candidate) => {
    const result = await summary(candidate);
    if (candidate === tab) firstCompleted.resolve();
    return result;
  };
  const entered = deferred();
  const viewport = deferred();
  manager.readTabViewport = (candidate) =>
    candidate === tab
      ? Promise.resolve({ width: 800, height: 600 })
      : (entered.resolve(), viewport.promise);
  const resultPromise = manager.executeInScope(context, { method: "list" }, running);
  await Promise.all([entered.promise, firstCompleted.promise]);
  manager.closeTab(tab);
  viewport.resolve({ width: 800, height: 600 });
  const result = await resultPromise;
  assert.equal(browserCommandResultSchema.safeParse(result).success, true);
  assert.equal(result.tabs.length, 1);
  assert.equal(result.tabs[0].tabId, other.tabId);
});

for (const method of ["activateTab", "claimTab", "newTab"]) {
  test(`${method} returns unavailable with closed metadata when viewport resolves after close`, async () => {
    const { context, tab, manager, running } = fixture();
    const { entered, viewport } = pauseViewport(manager);
    const resultPromise = manager.executeInScope(context, { method, tabId: tab.tabId }, running);
    await entered;
    manager.closeTab(tab);
    viewport.resolve({ width: 800, height: 600 });
    const result = await resultPromise;
    assert.equal(browserCommandResultSchema.safeParse(result).success, true);
    assert.equal(result.ok, false);
    assert.equal(result.error.code, "backend_unavailable");
    assert.equal(result.tab, undefined);
    assert.equal(result.meta.tabId, tab.tabId);
    assert.equal(result.meta.lifecycle, "closed");
    assert.equal(result.meta.browserGeneration, context.browserGeneration);
    assert.equal(result.meta.openTabIds.length, 0);
  });

  test(`${method} rejects closure between summary completion and caller resumption`, async () => {
    const { context, tab, manager, running } = fixture();
    const summary = manager.summary.bind(manager);
    manager.summary = async (candidate) => {
      const result = await summary(candidate);
      queueMicrotask(() => {
        manager.closeTab(candidate);
      });
      return result;
    };
    const result = await manager.executeInScope(context, { method, tabId: tab.tabId }, running);
    assert.equal(browserCommandResultSchema.safeParse(result).success, true);
    assert.equal(result.ok, false);
    assert.equal(result.error.code, "backend_unavailable");
    assert.equal(result.tab, undefined);
    assert.equal(result.meta.tabId, tab.tabId);
    assert.equal(result.meta.lifecycle, "closed");
    assert.equal(result.meta.openTabIds.length, 0);
  });

  test(`${method} rejects transfer after summary without exposing the new owner's metadata`, async () => {
    const { context, tab, manager, running } = fixture();
    const summary = manager.summary.bind(manager);
    manager.summary = async (candidate) => {
      const result = await summary(candidate);
      queueMicrotask(() => {
        candidate.owner = { ...context, workspaceKey: "identity-two" };
        candidate.cachedUrl = "https://foreign.example.invalid/private";
        candidate.guest.getURL = () => candidate.cachedUrl;
      });
      return result;
    };
    const result = await manager.executeInScope(context, { method, tabId: tab.tabId }, running);
    assert.equal(browserCommandResultSchema.safeParse(result).success, true);
    assert.equal(result.ok, false);
    assert.equal(result.error.code, "backend_unavailable");
    assert.equal(result.tab, undefined);
    assert.equal(result.meta.tabId, undefined);
    assert.equal(result.meta.currentUrl, undefined);
    assert.equal(result.meta.lifecycle, undefined);
    assert.equal(result.meta.browserId, context.browserId);
    assert.equal(result.meta.browserGeneration, context.browserGeneration);
    assert.equal(result.meta.openTabIds.length, 0);
  });

  test(`${method} rejects a replaced registry entry after summary`, async () => {
    const { context, tab, manager, running } = fixture();
    const summary = manager.summary.bind(manager);
    manager.summary = async (candidate) => {
      const result = await summary(candidate);
      queueMicrotask(() => {
        manager.tabs.set(candidate.tabId, {
          ...candidate,
          owner: { ...context, workspaceKey: "identity-two" },
        });
      });
      return result;
    };
    const result = await manager.executeInScope(context, { method, tabId: tab.tabId }, running);
    assert.equal(browserCommandResultSchema.safeParse(result).success, true);
    assert.equal(result.ok, false);
    assert.equal(result.error.code, "backend_unavailable");
    assert.equal(result.tab, undefined);
    assert.equal(result.meta.tabId, undefined);
    assert.equal(result.meta.currentUrl, undefined);
    assert.equal(result.meta.lifecycle, undefined);
  });
}

test("a rejected viewport after close is omitted without rejecting list", async () => {
  const { context, tab, manager, running } = fixture();
  const { entered, viewport } = pauseViewport(manager);
  const resultPromise = manager.executeInScope(context, { method: "list" }, running);
  await entered;
  manager.closeTab(tab);
  viewport.reject(new Error("guest destroyed during viewport query"));
  const result = await resultPromise;
  assert.equal(browserCommandResultSchema.safeParse(result).success, true);
  assert.equal(result.tabs.length, 0);
});

test("close cancellation preserves existing cancellation metadata and side-effect contract", async () => {
  const { context, tab, manager, running } = fixture();
  const { entered, viewport } = pauseViewport(manager);
  const resultPromise = manager.executeInScope(
    context,
    { method: "activateTab", tabId: tab.tabId },
    running,
  );
  await entered;
  manager.closeTab(tab);
  running.controller.abort();
  viewport.resolve({ width: 800, height: 600 });
  const result = await resultPromise;
  assert.equal(browserCommandResultSchema.safeParse(result).success, true);
  assert.equal(result.error.code, "cancelled");
  assert.equal(result.error.sideEffect, "none");
  assert.equal(result.meta.lifecycle, "closed");
});

test("active tab summaries remain valid and list keeps workspace identity isolation", async () => {
  const { context, tab, manager, running } = fixture();
  manager.tabs.set("foreign-tab", {
    ...tab,
    tabId: "foreign-tab",
    owner: { ...context, workspaceKey: "identity-two" },
  });
  const result = await manager.executeInScope(context, { method: "list" }, running);
  assert.equal(browserCommandResultSchema.safeParse(result).success, true);
  assert.equal(result.tabs.length, 1);
  assert.equal(result.tabs[0].tabId, tab.tabId);
  assert.equal(result.tabs[0].active, true);
});

test("cancellation after ownership transfer preserves request metadata and hides tab metadata", async () => {
  const { context, tab, manager, running } = fixture();
  const summary = manager.summary.bind(manager);
  running.dispatched = true;
  manager.summary = async (candidate) => {
    const result = await summary(candidate);
    queueMicrotask(() => {
      candidate.owner = { ...context, workspaceKey: "identity-two" };
      running.controller.abort();
    });
    return result;
  };
  const result = await manager.executeInScope(
    context,
    { method: "activateTab", tabId: tab.tabId },
    running,
  );
  assert.equal(browserCommandResultSchema.safeParse(result).success, true);
  assert.equal(result.ok, false);
  assert.equal(result.error.code, "cancelled");
  assert.equal(result.error.sideEffect, "uncertain");
  assert.equal(result.meta.browserId, context.browserId);
  assert.equal(result.meta.browserGeneration, context.browserGeneration);
  assert.equal(result.meta.tabId, undefined);
  assert.equal(result.meta.currentUrl, undefined);
  assert.equal(result.meta.lifecycle, undefined);
});

for (const recovered of [true, false]) {
  test(`activation rejects ownership released during guest recovery (${recovered ? "success" : "failure"}) before selection`, async () => {
    const { context, tab, manager, running } = fixture();
    const entered = deferred();
    const recovery = deferred();
    let selections = 0;
    manager.ensureGuest = () => {
      entered.resolve();
      return recovery.promise;
    };
    manager.selectTab = () => selections++;
    const resultPromise = manager.executeInScope(
      context,
      { method: "activateTab", tabId: tab.tabId },
      running,
    );
    await entered.promise;
    manager.releaseToUser(tab);
    recovery.resolve(recovered ? tab.guest : null);
    const result = await resultPromise;
    assert.equal(browserCommandResultSchema.safeParse(result).success, true);
    assert.equal(result.ok, false);
    assert.equal(result.error.code, "backend_unavailable");
    assert.equal(selections, 0);
    assert.equal(result.meta.tabId, undefined);
    assert.equal(result.meta.currentUrl, undefined);
    assert.equal(result.meta.lifecycle, undefined);
  });
}

test("activation cancellation during guest recovery cannot select a tab", async () => {
  const { context, tab, manager, running } = fixture();
  const entered = deferred();
  const recovery = deferred();
  let selections = 0;
  manager.ensureGuest = () => {
    entered.resolve();
    return recovery.promise;
  };
  manager.selectTab = () => selections++;
  const resultPromise = manager.executeInScope(
    context,
    { method: "activateTab", tabId: tab.tabId },
    running,
  );
  await entered.promise;
  running.controller.abort();
  recovery.resolve(tab.guest);
  const result = await resultPromise;
  assert.equal(browserCommandResultSchema.safeParse(result).success, true);
  assert.equal(result.error.code, "cancelled");
  assert.equal(selections, 0);
});

test("failed creation cannot close a tab released during guest recovery", async () => {
  const { context, tab, manager, running } = fixture();
  const entered = deferred();
  const recovery = deferred();
  manager.ensureGuest = () => {
    entered.resolve();
    return recovery.promise;
  };
  const resultPromise = manager.executeInScope(context, { method: "newTab" }, running);
  await entered.promise;
  manager.releaseToUser(tab);
  recovery.resolve(null);
  const result = await resultPromise;
  assert.equal(browserCommandResultSchema.safeParse(result).success, true);
  assert.equal(result.ok, false);
  assert.equal(result.error.code, "backend_unavailable");
  assert.equal(manager.tabs.get(tab.tabId), tab);
  assert.equal(tab.lifecycle, "active");
  assert.equal(tab.claimable, true);
  assert.equal(result.meta.tabId, undefined);
  assert.equal(result.meta.currentUrl, undefined);
  assert.equal(result.meta.lifecycle, undefined);
});

test("a viewport failure on a still-open tab retains the existing failure path", async () => {
  const { context, manager, running } = fixture();
  manager.readTabViewport = async () => {
    throw new Error("live viewport failure");
  };
  await assert.rejects(
    manager.executeInScope(context, { method: "list" }, running),
    /live viewport failure/,
  );
});
