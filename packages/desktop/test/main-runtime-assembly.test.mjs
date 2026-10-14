import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import ts from "typescript";
import {
  resolveCloseToTrayBootstrapValue,
  resolveCloseToTrayRuntimeValue,
} from "../src/main/desktopTraySupport.ts";

const source = await readFile(new URL("../src/main/index.ts", import.meta.url), "utf8");
const tree = ts.createSourceFile("index.ts", source, ts.ScriptTarget.Latest, true);

function findNode(predicate) {
  let result;
  function visit(node) {
    if (predicate(node)) result ??= node;
    ts.forEachChild(node, visit);
  }
  visit(tree);
  assert.ok(result, "main must include the runtime assembly under test");
  return result;
}

function runtimeContext(overrides) {
  const stub = () => {};
  const placeholder = new Proxy(stub, { get: () => placeholder });
  const context = {};
  // Evaluate real assembly expressions with inactive desktop dependencies. This
  // exercises the entry point's wiring without starting Electron or any Host.
  function visit(node) {
    if (ts.isIdentifier(node)) context[node.text] = placeholder;
    ts.forEachChild(node, visit);
  }
  visit(tree);
  return Object.assign(context, overrides);
}

function evaluate(expression, context) {
  const script = ts.transpileModule(`const result = ${expression.getText(tree)};`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  return runInNewContext(`(() => { ${script}\nreturn result; })()`, context);
}

function callArgument(name) {
  return findNode((node) => ts.isCallExpression(node) && node.expression.getText(tree) === name)
    .arguments[0];
}

test("main uses the ordinary remote-session registry for workspace synchronization", async () => {
  const events = [];
  const context = runtimeContext({
    remoteSessionManager: {
      bindRemoteWorkspaceSessionContext: async (...args) => events.push(args),
    },
  });
  const platform = evaluate(callArgument("registerPlatformIpcHandlers"), context);
  platform.syncRemoteWorkspaceSessions(71, [
    {
      workspacePath: "/same",
      workspaceIdentity: "remote:ssh:a:22:u:/same",
      remoteSessionId: "remote-1",
    },
  ]);
  await Promise.resolve();
  assert.deepEqual(JSON.parse(JSON.stringify(events)), [
    ["remote-1", { workspacePath: "/same", workspaceIdentity: "remote:ssh:a:22:u:/same" }, 71],
  ]);
});

test("Desktop runtime and public bridges expose no mobile-control API", async () => {
  const files = [
    "../src/main/index.ts",
    "../src/main/desktopMainIpcPlatform.ts",
    "../src/main/desktopMainIpcRemote.ts",
    "../src/main/desktopWindowLifecycle.ts",
    "../src/main/desktopRemoteSessions.ts",
    "../src/main/logger.ts",
    "../src/preload/index.ts",
    "../src/renderer/src/desktopPlatform.ts",
  ];
  for (const file of files) {
    assert.equal(
      /webRemoteControl|WebRemoteControl|CCBUDDY_WEB_REMOTE_CONTROL|web-remote-control/.test(
        await readFile(new URL(file, import.meta.url), "utf8"),
      ),
      false,
      `${file} must not expose or create removed mobile control`,
    );
  }
  const window = evaluate(callArgument("createWindow"), runtimeContext({}));
  assert.equal(typeof window.disposeRemoteWorkspaceSessionsForWindow, "function");
  const remote = evaluate(callArgument("registerRemoteIpcHandlers"), runtimeContext({}));
  assert.equal(typeof remote.createRemoteWorkspaceSession, "function");
});

test("main resolves the local provider path before sending Host initialization", () => {
  let sent;
  const context = runtimeContext({
    hostProcessLocalEnv: { LOCAL_ONLY: "local" },
    process: { env: { CCBUDDY_ENV: "test" } },
    resolveCCbuddyBuiltinProviderConfigFilePath: ({ env }) => {
      assert.equal(env.LOCAL_ONLY, "local");
      assert.equal(env.CCBUDDY_ENV, "test");
      return "/app/config/byok-provider.json";
    },
    spawnHostProcess: (_win, _label, message) => {
      sent = message;
    },
  });
  const window = evaluate(callArgument("createWindow"), context);
  const initialization = {
    type: "init-local",
    workspacePath: "/project",
    workspaceIdentity: "identity",
  };
  window.spawnHostProcess({}, "local-7", initialization);
  assert.deepEqual(
    { ...sent },
    {
      ...initialization,
      ccbuddyBuiltinProviderConfigFilePath: "/app/config/byok-provider.json",
    },
  );
});

test("main adapts a missing browser owner and preserves the accepted owner identity", () => {
  let owner = null;
  const context = runtimeContext({
    browserGuestManager: { getTabOwnerByWebContentsId: () => owner },
  });
  const window = evaluate(callArgument("createWindow"), context);
  assert.equal(window.resolveBrowserViewOwner(41), undefined);
  owner = { workspaceKey: "remote-identity", remoteSessionId: "remote-7", sessionId: "session-7" };
  assert.equal(window.resolveBrowserViewOwner(41), owner);
});

async function evaluateTrayBootstrap(settings, { platform = "linux", writeError } = {}) {
  const writes = [];
  const statement = findNode(
    (node) =>
      ts.isTryStatement(node) &&
      node.tryBlock.getText(tree).includes("bootstrapSettings = await mainSettingService.get()"),
  );
  const script = ts.transpileModule(
    `(async () => { ${statement.getText(tree)}; return closeToTrayOnWindows; })()`,
    {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
    },
  ).outputText;
  const context = runtimeContext({
    process: { platform },
    mainSettingService: {
      get: async () => ({ ...settings }),
      update: async (patch) => {
        writes.push({ ...patch });
        if (writeError) throw writeError;
      },
    },
    resolveCloseToTrayBootstrapValue,
    resolveCloseToTrayRuntimeValue,
    logger: { warn: () => {} },
  });
  return { value: await runInNewContext(script, context), writes };
}

test("Main resets the inherited Linux tray default once and preserves initialized preferences", async () => {
  const migrated = await evaluateTrayBootstrap({ closeToTrayOnWindows: true });
  assert.equal(migrated.value, false);
  assert.deepEqual(migrated.writes, [
    { closeToTrayOnWindows: false, closeToTrayLinuxMigrationInitialized: true },
  ]);
  assert.deepEqual(
    await evaluateTrayBootstrap({
      closeToTrayOnWindows: true,
      closeToTrayLinuxMigrationInitialized: true,
    }),
    {
      value: true,
      writes: [],
    },
  );
});

test("Main keeps the persisted preference if Linux tray migration cannot be written", async () => {
  const result = await evaluateTrayBootstrap(
    { closeToTrayOnWindows: true },
    { writeError: new Error("read-only test store") },
  );
  assert.equal(result.value, true);
  assert.equal(result.writes.length, 1);
});

test("Main keeps the existing Windows tray default without a Linux migration", async () => {
  assert.deepEqual(await evaluateTrayBootstrap({}, { platform: "win32" }), {
    value: true,
    writes: [],
  });
});
