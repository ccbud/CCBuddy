import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { afterEach, beforeEach, mock, test } from "node:test";

const ipcMain = new EventEmitter();
const contents = new Map();
let focusedWindow;
let allWindows = [];
const desktopCapturer = { getSources: mock.fn(async () => []) };
mock.module("electron", {
  namedExports: {
    ipcMain,
    desktopCapturer,
    BrowserWindow: {
      getFocusedWindow: () => focusedWindow,
      getAllWindows: () => allWindows,
      fromWebContents: (host) => allWindows.find((win) => win.webContents === host),
    },
    webContents: {
      fromId: (id) => contents.get(id),
      fromFrame: (frame) => frame?.contents,
    },
  },
});
const { PlatformChannels } = await import("@ccbuddy/shared");
const { createEmbeddedBrowserPermissionUiBridge } =
  await import("../src/main/embeddedBrowserPermissionUiBridge.ts");

function host(id) {
  const value = new EventEmitter();
  value.id = id;
  value.mainFrame = { id: `main-${id}` };
  value.destroyed = false;
  value.isDestroyed = () => value.destroyed;
  value.getType = () => "window";
  value.prompts = [];
  value.send = (_channel, event) => value.prompts.push(event);
  contents.set(id, value);
  return value;
}

function resolveFrom(sender, requestId, action, senderFrame = sender.mainFrame) {
  ipcMain.emit(
    PlatformChannels.EmbeddedBrowserPermissionResolve,
    { sender, senderFrame },
    { requestId, resolution: { action } },
  );
}

let bridge;
beforeEach(() => {
  bridge = createEmbeddedBrowserPermissionUiBridge({
    logger: { info() {}, warn() {} },
    promptTimeoutMs: 10,
  });
  bridge.registerResolveListener();
});
afterEach(() => {
  ipcMain.removeAllListeners();
  contents.clear();
  focusedWindow = undefined;
  allWindows = [];
  desktopCapturer.getSources.mock.resetCalls();
});

test("a missing permission owner is dismissed without prompting another application window", async () => {
  const other = host(22);
  focusedWindow = { webContents: other };
  allWindows = [focusedWindow];
  const result = bridge.promptPermission({
    origin: "https://example.invalid",
    permission: "media",
    hostWebContentsId: 11,
  });
  if (other.prompts[0]) resolveFrom(other, other.prompts[0].requestId, "allow-always");
  assert.equal(await result, "dismiss");
  assert.equal(other.prompts.length, 0);
});

test("only the owner main frame can resolve a permission prompt", async () => {
  const owner = host(11);
  const other = host(22);
  allWindows = [{ webContents: owner }, { webContents: other }];
  const result = bridge.promptPermission({
    origin: "https://example.invalid",
    permission: "media",
    hostWebContentsId: owner.id,
  });
  const { requestId } = owner.prompts[0];
  resolveFrom(other, requestId, "allow-always");
  resolveFrom(owner, requestId, "allow-always", { id: "child-frame" });
  resolveFrom(owner, requestId, "dismiss");
  assert.equal(await result, "dismiss");
});

test("the owner main frame can allow a permission and settlement releases lifecycle listeners", async () => {
  const owner = host(11);
  allWindows = [{ webContents: owner }];
  const result = bridge.promptPermission({
    origin: "https://example.invalid",
    permission: "media",
    hostWebContentsId: owner.id,
  });
  resolveFrom(owner, owner.prompts[0].requestId, "allow-always");
  assert.equal(await result, "allow-always");
  assert.equal(owner.listenerCount("destroyed"), 0);
  assert.equal(owner.listenerCount("render-process-gone"), 0);
});

test("an owner destroyed during a device chooser cannot transfer the prompt to another window", async () => {
  const owner = host(11);
  const other = host(22);
  allWindows = [{ webContents: owner }, { webContents: other }];
  focusedWindow = allWindows[1];
  const picker = bridge.devicePicker({
    origin: "https://example.invalid",
    permission: "select-usb-device",
    devices: [],
    hostWebContentsId: owner.id,
  });
  owner.destroyed = true;
  contents.delete(owner.id);
  owner.emit("destroyed");
  picker.updateDevices([{ deviceId: "device-1", name: "Device" }]);
  assert.equal(await picker.result, null);
  assert.equal(other.prompts.length, 0);
});

test("screen sharing uses the requesting guest's owner even when a different window is focused", async () => {
  const owner = host(11);
  const other = host(22);
  allWindows = [{ webContents: owner }, { webContents: other }];
  focusedWindow = allWindows[1];
  const guest = { hostWebContents: owner };
  let screenPrompt;
  const sent = new Promise((resolve) => {
    screenPrompt = resolve;
  });
  owner.send = (_channel, event) => {
    owner.prompts.push(event);
    screenPrompt();
  };
  other.send = (_channel, event) => {
    other.prompts.push(event);
    screenPrompt();
  };
  const response = new Promise((resolve) =>
    bridge.onDisplayMediaRequest(
      { origin: "https://example.invalid", frame: { contents: guest } },
      resolve,
    ),
  );
  await sent;
  const target = owner.prompts[0] ? owner : other;
  resolveFrom(target, target.prompts[0].requestId, "cancel");
  await response;
  assert.equal(owner.prompts.length, 1);
  assert.equal(other.prompts.length, 0);
});

test("framed USB/HID requests resolve their host and accept a selection from that host", async () => {
  const owner = host(11);
  allWindows = [{ webContents: owner }];
  const picker = bridge.devicePicker({
    origin: "https://example.invalid",
    permission: "select-usb-device",
    devices: [{ deviceId: "device-1", name: "Device" }],
    frame: { contents: { hostWebContents: owner } },
  });
  assert.equal(owner.prompts.length, 1);
  const { requestId } = owner.prompts[0];
  ipcMain.emit(
    PlatformChannels.EmbeddedBrowserPermissionResolve,
    { sender: owner, senderFrame: owner.mainFrame },
    { requestId, resolution: { action: "select-device", deviceId: "device-1" } },
  );
  assert.deepEqual(await picker.result, { deviceId: "device-1" });
});

test("screen sharing without a live requesting frame is denied without enumerating sources", async () => {
  const other = host(22);
  focusedWindow = { webContents: other };
  allWindows = [focusedWindow];
  const result = await new Promise((resolve) =>
    bridge.onDisplayMediaRequest({ origin: "https://example.invalid" }, resolve),
  );
  assert.deepEqual(result, {});
  assert.equal(other.prompts.length, 0);
  assert.equal(desktopCapturer.getSources.mock.callCount(), 0);
});
