import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { runInNewContext } from "node:vm";
import ts from "typescript";

const source = await readFile(
  new URL("../src/main/browserView/browserGuestManager.ts", import.meta.url),
  "utf8",
);
const tree = ts.createSourceFile("browserGuestManager.ts", source, ts.ScriptTarget.Latest, true);
const manager = tree.statements.find(
  (node) => ts.isClassDeclaration(node) && node.name?.text === "BrowserGuestManager",
);
assert.ok(manager);
const methodNames = [
  "summary",
  "executeInScope",
  "ownedTabs",
  "effectiveActiveTabId",
  "resolveTab",
  "withMeta",
  "cancelledOrUnavailable",
  "cancelledResult",
  "closeTab",
  "releaseToUser",
  "closeTabDurably",
  "removeTabRecovery",
  "persistShell",
  "persistRecoverySnapshot",
  "canClaimUserTab",
  "finalizeTabs",
];
const methods = manager.members.filter(
  (node) => ts.isMethodDeclaration(node) && methodNames.includes(node.name.getText(tree)),
);
assert.equal(methods.length, methodNames.length);
const functionNames = [
  "scopeKey",
  "sameScope",
  "ownedBySession",
  "safeStr",
  "safeBool",
  "sanitizeBrowserMetaUrl",
];
const functions = tree.statements.filter(
  (node) => ts.isFunctionDeclaration(node) && functionNames.includes(node.name?.text),
);
assert.equal(functions.length, functionNames.length);
const compiled = ts.transpileModule(
  `${functions.map((node) => node.getText(tree)).join("\n")}\nclass Harness { ${methods.map((node) => node.getText(tree)).join("\n")} }`,
  {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  },
).outputText;
export const Harness = runInNewContext(`${compiled}\nHarness`, {
  exports: {},
  AbortController,
  Date,
  Map,
  URL,
  randomUUID: () => "test-id",
  TAB_CONTEXT_RECOVERY_HINT: "Recover the existing browser binding",
});

export function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}

export function fixture() {
  const context = {
    requestId: "summary-request",
    browserId: "iab",
    browserGeneration: 4,
    windowId: 7,
    workspaceKey: "identity-one",
    sessionId: "session",
    clientMode: "desktop-continuous",
  };
  const tab = {
    tabId: "pending-tab",
    owner: { ...context },
    cachedUrl: "https://example.invalid",
    cachedTitle: "Pending tab",
    lifecycle: "active",
    origin: "agent",
    claimable: false,
    cachedFaviconUrl: null,
    openedAt: 1,
    guest: {
      getURL: () => "https://example.invalid",
      getTitle: () => "Pending tab",
      isDestroyed: () => false,
    },
  };
  const manager = new Harness();
  manager.tabs = new Map([[tab.tabId, tab]]);
  manager.guestRecoveryFlights = new Map();
  manager.activeTabByScope = new Map();
  manager.defaultTabByScope = new Map();
  manager.closedTabIds = new Set();
  manager.inFlightScreenshots = new Map();
  manager.abandonedScreenshotCaptures = new Map();
  manager.downloads = new Map();
  manager.queuedDownloads = new Map();
  manager.downloadWaiters = new Map();
  manager.restoredTabClaims = new Map();
  manager.residencyCoordinator = { remove: () => {}, get: () => undefined };
  manager.residencyOptions = {};
  manager.now = () => 2;
  manager.warn = () => {};
  manager.abortRecordings = () => {};
  manager.resolveWaiters = () => {};
  manager.detachAndCloseGuest = (candidate) => {
    candidate.guest = undefined;
  };
  manager.readTabViewport = () => Promise.resolve({ width: 800, height: 600 });
  manager.ensureGuest = async () => tab.guest;
  manager.refreshRuntimeProtection = () => {};
  manager.selectTab = () => {};
  manager.createTab = () => tab;
  manager.canClaimUserTab = () => true;
  manager.claimTab = () => tab;
  const running = { context, controller: new AbortController(), dispatched: false };
  return { context, tab, manager, running };
}

export function pauseViewport(manager) {
  const entered = deferred();
  const viewport = deferred();
  manager.readTabViewport = () => {
    entered.resolve();
    return viewport.promise;
  };
  return { entered: entered.promise, viewport };
}
