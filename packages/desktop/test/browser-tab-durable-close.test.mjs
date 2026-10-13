import assert from "node:assert/strict";
import { mkdir, mkdtemp, rename, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { browserCommandResultSchema } from "@ccbuddy/shared";
import { BrowserTabRecoveryStore } from "../src/main/browserView/browserTabRecoveryStore.ts";
import { deferred, fixture, Harness, pauseViewport } from "./browser-guest-manager-harness.mjs";

async function recoveryFixture(t) {
  const directory = await mkdtemp(join(tmpdir(), "ccbuddy-browser-close-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const state = fixture();
  const recoveryPath = join(directory, "recovery.json");
  const store = new BrowserTabRecoveryStore(recoveryPath);
  state.manager.residencyOptions = { recoveryStore: store };
  state.manager.canClaimUserTab = Harness.prototype.canClaimUserTab.bind(state.manager);
  await state.manager.persistShell(state.tab);
  return { ...state, store, recoveryPath };
}

function pauseRemoval(store) {
  const entered = deferred();
  const removal = deferred();
  const remove = store.remove.bind(store);
  let calls = 0;
  store.remove = async (tabId) => {
    calls++;
    entered.resolve();
    await removal.promise;
    await remove(tabId);
  };
  return { entered: entered.promise, removal, calls: () => calls };
}

test("durable close rejects concurrent finalization and joins duplicate close", async (t) => {
  const { context, tab, manager, running, store } = await recoveryFixture(t);
  const { entered, removal, calls } = pauseRemoval(store);
  let guestCloses = 0;
  manager.detachAndCloseGuest = () => guestCloses++;
  const firstClose = manager.closeTabDurably(tab);
  await entered;
  const secondClose = manager.closeTabDurably(tab);
  const result = await manager.executeInScope(
    context,
    { method: "finalizeTabs", keep: [{ tabId: tab.tabId, status: "deliverable" }] },
    running,
  );
  assert.equal(browserCommandResultSchema.safeParse(result).success, true);
  assert.equal(result.ok, false);
  assert.equal(result.error.code, "backend_unavailable");
  assert.equal(tab.owner.browserId, context.browserId);
  assert.equal(tab.claimable, false);
  assert.equal(manager.resolveTab(context, tab.tabId), undefined);
  removal.resolve();
  await Promise.all([firstClose, secondClose]);
  assert.equal(calls(), 1);
  assert.equal(guestCloses, 1);
  assert.equal(tab.lifecycle, "closed");
  assert.equal(manager.tabs.has(tab.tabId), false);
  assert.equal((await store.readSnapshot()).shells.length, 0);
});

test("user release and claim cannot change ownership after durable close starts", async (t) => {
  const { context, tab, manager, store } = await recoveryFixture(t);
  const { entered, removal } = pauseRemoval(store);
  const closing = manager.closeTabDurably(tab);
  await entered;
  manager.releaseToUser(tab);
  assert.equal(tab.owner.browserId, context.browserId);
  assert.equal(tab.claimable, false);
  assert.equal(manager.canClaimUserTab(tab, context), false);
  removal.resolve();
  await closing;
  assert.equal(tab.lifecycle, "closed");
  assert.equal(tab.owner.browserId, context.browserId);
  assert.equal((await store.readSnapshot()).shells.length, 0);
});

test("failed removal preserves recovery and guest before deferred user release", async (t) => {
  const { context, tab, manager, store } = await recoveryFixture(t);
  const guest = tab.guest;
  const { entered, removal, calls } = pauseRemoval(store);
  const closing = manager.closeTabDurably(tab);
  await entered;
  manager.releaseToUser(tab);
  assert.equal(tab.owner.browserId, context.browserId);
  assert.equal(tab.claimable, false);
  removal.reject(new Error("recovery deletion failed"));
  await assert.rejects(closing, /recovery deletion failed/);
  assert.equal(calls(), 1);
  assert.equal(manager.tabs.get(tab.tabId), tab);
  assert.equal(tab.guest, guest);
  assert.equal(tab.lifecycle, "active");
  assert.equal(tab.claimable, true);
  assert.equal(manager.canClaimUserTab(tab, context), true);
  assert.equal(tab.closeFlight, undefined);
  assert.equal((await store.readSnapshot()).shells.length, 1);
});

test("deferred release cannot affect a replacement registry object after deletion fails", async (t) => {
  const { context, tab, manager, store } = await recoveryFixture(t);
  const { entered, removal } = pauseRemoval(store);
  const closing = manager.closeTabDurably(tab);
  await entered;
  manager.releaseToUser(tab);
  const replacement = { ...tab, owner: { ...context, workspaceKey: "identity-two" } };
  manager.tabs.set(tab.tabId, replacement);
  removal.reject(new Error("recovery deletion failed"));
  await assert.rejects(closing, /recovery deletion failed/);
  assert.equal(manager.tabs.get(tab.tabId), replacement);
  assert.equal(tab.claimable, false);
  assert.equal(replacement.owner.workspaceKey, "identity-two");
  assert.equal(replacement.claimable, false);
});

test("a shell update during removal cannot recreate deleted recovery data", async (t) => {
  const { tab, manager, store } = await recoveryFixture(t);
  const removed = deferred();
  const removalSettled = deferred();
  const remove = store.remove.bind(store);
  store.remove = async (tabId) => {
    await remove(tabId);
    removed.resolve();
    await removalSettled.promise;
  };
  const closing = manager.closeTabDurably(tab);
  await removed.promise;
  await manager.persistShell(tab);
  removalSettled.resolve();
  await closing;
  assert.equal((await store.readSnapshot()).shells.length, 0);
});

test("a snapshot finishing after close cannot recreate deleted page state", async (t) => {
  const { tab, manager, store } = await recoveryFixture(t);
  tab.guest.navigationHistory = {
    getAllEntries: () => [{ url: "https://example.invalid", title: "Test", pageState: "state" }],
    getActiveIndex: () => 0,
  };
  const shellWritten = deferred();
  const shellSettled = deferred();
  const upsert = store.upsert.bind(store);
  store.upsert = async (record) => {
    await upsert(record);
    shellWritten.resolve();
    await shellSettled.promise;
  };
  const snapshot = manager.persistRecoverySnapshot(tab, tab.guest);
  await shellWritten.promise;
  await manager.closeTabDurably(tab);
  shellSettled.resolve();
  await snapshot;
  const recovery = await store.readSnapshot();
  assert.equal(recovery.shells.length, 0);
  assert.equal(recovery.pageStates.length, 0);
});

test("list omits a tab whose durable close starts during its viewport read", async (t) => {
  const { context, tab, manager, running, store } = await recoveryFixture(t);
  const { entered: viewportEntered, viewport } = pauseViewport(manager);
  const { entered: removalEntered, removal } = pauseRemoval(store);
  const listing = manager.executeInScope(context, { method: "list" }, running);
  await viewportEntered;
  const closing = manager.closeTabDurably(tab);
  await removalEntered;
  viewport.resolve({ width: 800, height: 600 });
  const result = await listing;
  assert.equal(browserCommandResultSchema.safeParse(result).success, true);
  assert.equal(result.tabs.length, 0);
  removal.resolve();
  await closing;
});

test("list rechecks a completed entry when durable close starts during another read", async (t) => {
  const { context, tab, manager, running, store } = await recoveryFixture(t);
  const other = { ...tab, tabId: "second-tab" };
  manager.tabs.set(other.tabId, other);
  const firstCompleted = deferred();
  const otherViewport = deferred();
  const summary = manager.summary.bind(manager);
  manager.summary = async (candidate) => {
    const result = await summary(candidate);
    if (candidate === tab) firstCompleted.resolve();
    return result;
  };
  manager.readTabViewport = (candidate) =>
    candidate === tab ? Promise.resolve({ width: 800, height: 600 }) : otherViewport.promise;
  const { entered, removal } = pauseRemoval(store);
  const listing = manager.executeInScope(context, { method: "list" }, running);
  await firstCompleted.promise;
  const closing = manager.closeTabDurably(tab);
  await entered;
  otherViewport.resolve({ width: 800, height: 600 });
  const result = await listing;
  assert.equal(browserCommandResultSchema.safeParse(result).success, true);
  assert.equal(result.tabs.length, 1);
  assert.equal(result.tabs[0].tabId, other.tabId);
  removal.resolve();
  await closing;
});

test("real file-write failure keeps cached recovery and guest for release and retry", async (t) => {
  const { context, tab, manager, store, recoveryPath } = await recoveryFixture(t);
  const guest = tab.guest;
  const pageState = {
    schemaVersion: 1,
    tabId: tab.tabId,
    entries: [{ url: "https://example.invalid", title: "Test", pageState: "state" }],
    activeIndex: 0,
    updatedAt: 2,
  };
  await store.upsertPageState(pageState);
  const before = await store.readSnapshot();
  const backupPath = `${recoveryPath}.backup`;
  await rename(recoveryPath, backupPath);
  await mkdir(recoveryPath);
  const closing = manager.closeTabDurably(tab);
  manager.releaseToUser(tab);
  assert.equal(tab.owner.browserId, context.browserId);
  await assert.rejects(closing, (error) =>
    ["EISDIR", "ENOTEMPTY", "EEXIST", "EPERM"].includes(error.code),
  );
  assert.equal(manager.tabs.get(tab.tabId), tab);
  assert.equal(tab.guest, guest);
  assert.equal(tab.claimable, true);
  assert.deepEqual(await store.readSnapshot(), before);
  await rm(recoveryPath, { recursive: true });
  await rename(backupPath, recoveryPath);
  assert.deepEqual(await new BrowserTabRecoveryStore(recoveryPath).readSnapshot(), before);
  await manager.closeTabDurably(tab);
  assert.equal(tab.lifecycle, "closed");
  const after = await store.readSnapshot();
  assert.equal(after.shells.length, 0);
  assert.equal(after.pageStates.length, 0);
  assert.deepEqual(await new BrowserTabRecoveryStore(recoveryPath).readSnapshot(), after);
});
