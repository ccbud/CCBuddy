import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { afterEach, mock, test } from "node:test";

const windows = [];
afterEach(() => {
  windows.length = 0;
});
mock.module("electron", {
  namedExports: {
    BrowserWindow: {
      getAllWindows: () => windows,
      fromId: (id) => windows.find((win) => win.id === id),
    },
    MessageChannelMain: class {},
  },
});
const { HostMessageTypes, HostResponseTypes } = await import("@ccbuddy/shared");
const { createRemoteWorkspaceSessionManager } =
  await import("../src/main/desktopRemoteSessions.ts");

async function connectedRegistry() {
  const child = new EventEmitter();
  child.pid = 42;
  const messages = [];
  child.postMessage = (message) => messages.push(message);
  let manager;
  const win = {
    id: 7,
    isDestroyed: () => false,
    webContents: {
      id: 71,
      isDestroyed: () => false,
      send() {},
      postMessage(_channel, payload) {
        queueMicrotask(() => manager.confirmRendererAttachmentReady(71, payload));
      },
    },
  };
  windows.push(win);
  manager = createRemoteWorkspaceSessionManager({
    logger: { info() {}, warn() {}, error() {} },
    windowHostProcessMap: new Map([[71, child]]),
    resolveRemoteAssetDirs: () => ({}),
    createMessageChannel: () => ({ port1: { close() {} }, port2: { close() {} } }),
    providerProvisioningCoordinator: {
      register: () => ({ initialSync: Promise.resolve(), dispose() {} }),
    },
  });
  const target = { kind: "ssh", host: "host.example", username: "user" };
  const workspacePath = "/workspace";
  const workspaceIdentity = "remote:ssh:host.example:22:user:/workspace";
  const connected = manager.createRemoteWorkspaceSession(win, target, "request-1", {
    workspacePath,
    workspaceIdentity,
  });
  child.emit("message", {
    type: HostResponseTypes.RemoteWorkspaceConnected,
    requestId: "request-1",
    descriptor: {
      remoteSessionId: "remote-1",
      target,
      workspacePath,
      workspaceIdentity,
      generation: 1,
    },
  });
  assert.equal(await connected, "remote-1");
  return { manager, messages, child, target, win, context: { workspacePath, workspaceIdentity } };
}

test("repeated remote-session targets are idempotent and do not replace the renderer attachment", async () => {
  const { manager, messages, context } = await connectedRegistry();
  const before = messages.length;
  await manager.bindRemoteWorkspaceSessionContext("remote-1", context, 71);
  await manager.bindRemoteWorkspaceSessionContext(
    "remote-1",
    {
      ...context,
      workspaceIdentity: ` ${context.workspaceIdentity} `,
    },
    71,
  );
  assert.equal(messages.length, before);
  windows.length = 0;
});

test("an identical remote-session target from another window cannot bypass ownership", async () => {
  const { manager, messages, context } = await connectedRegistry();
  const before = messages.length;
  await assert.rejects(
    manager.bindRemoteWorkspaceSessionContext("remote-1", context, 72),
    /不属于当前窗口/,
  );
  assert.equal(messages.length, before);
  windows.length = 0;
});

test("ordinary Bot runtime ports retain the same Host and verified remote workspace scope", async () => {
  const { manager, messages, target, win, context } = await connectedRegistry();
  const port = await manager.createBotRemoteWorkspaceRuntimePort(win, { target, ...context });
  assert.equal(typeof port.close, "function");
  const attachment = messages.at(-1);
  assert.equal(attachment.type, HostMessageTypes.AttachServicePort);
  assert.equal(attachment.clientMode, "web-remote-replayable");
  assert.deepEqual(attachment.scope, { kind: "remote", remoteSessionId: "remote-1", ...context });
  windows.length = 0;
});

test("a closed source cannot be accepted as an identical active remote-session target", async () => {
  const { manager, messages, child, context } = await connectedRegistry();
  child.emit("message", {
    type: HostResponseTypes.RemoteWorkspaceClosed,
    remoteSessionId: "remote-1",
    reason: "connection-closed",
  });
  const before = messages.length;
  await assert.rejects(
    manager.bindRemoteWorkspaceSessionContext("remote-1", context, 71),
    /已关闭|离线/,
  );
  assert.equal(messages.length, before);
  windows.length = 0;
});

test("repeated scope binding waits for the original renderer ready ACK without rebuilding", async () => {
  const { manager, messages, win, context } = await connectedRegistry();
  let pending;
  win.webContents.postMessage = (_channel, payload) => {
    pending = payload;
  };
  const nextContext = {
    ...context,
    workspacePath: "/next-workspace",
    workspaceIdentity: "next-identity",
  };
  let firstSettled = false;
  let secondSettled = false;
  const first = manager.bindRemoteWorkspaceSessionContext("remote-1", nextContext, 71);
  first.then(() => {
    firstSettled = true;
  });
  const second = manager.bindRemoteWorkspaceSessionContext("remote-1", nextContext, 71);
  second.then(() => {
    secondSettled = true;
  });
  await Promise.resolve();
  await Promise.resolve();
  const beforeAck = { firstSettled, secondSettled };
  const bindMessages = messages.filter(
    (message) => message.type === HostMessageTypes.BindRemoteWorkspaceContext,
  );
  manager.confirmRendererAttachmentReady(71, pending);
  await Promise.all([first, second]);
  assert.deepEqual(beforeAck, { firstSettled: false, secondSettled: false });
  assert.equal(bindMessages.length, 1);
});

test("a failed renderer delivery retries its attachment without rewriting the same scope", async () => {
  const { manager, messages, win, context } = await connectedRegistry();
  win.webContents.postMessage = () => {
    throw new Error("delivery unavailable");
  };
  const nextContext = {
    ...context,
    workspacePath: "/next-workspace",
    workspaceIdentity: "next-identity",
  };
  await assert.rejects(
    manager.bindRemoteWorkspaceSessionContext("remote-1", nextContext, 71),
    /delivery unavailable/,
  );
  const before = messages.length;
  win.webContents.postMessage = (_channel, payload) => {
    queueMicrotask(() => manager.confirmRendererAttachmentReady(71, payload));
  };
  await manager.bindRemoteWorkspaceSessionContext("remote-1", nextContext, 71);
  const retried = messages.slice(before);
  assert.equal(
    retried.filter((message) => message.type === HostMessageTypes.BindRemoteWorkspaceContext)
      .length,
    0,
  );
  assert.equal(
    retried.filter((message) => message.type === HostMessageTypes.AttachServicePort).length,
    1,
  );
});
