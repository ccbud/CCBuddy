import assert from "node:assert/strict";
import { afterEach, mock, test } from "node:test";

const setIcon = mock.fn();
const app = { isPackaged: false, dock: { setIcon } };
let imageIsEmpty = false;
const image = { isEmpty: () => imageIsEmpty };
const createFromPath = mock.fn(() => image);
mock.module("electron", {
  namedExports: { app, nativeImage: { createFromPath } },
});

const { applyAppIcon } = await import("../src/main/desktopDockIcon.ts");

afterEach(() => {
  mock.restoreAll();
  setIcon.mock.resetCalls();
  createFromPath.mock.resetCalls();
  app.isPackaged = false;
  app.dock = { setIcon };
  imageIsEmpty = false;
});

test("installed macOS retains the bundle Dock icon without loading a replacement", () => {
  mock.property(process, "platform", "darwin");
  app.isPackaged = true;
  applyAppIcon("/Applications/CCbuddy.app/Contents/Resources/icon.png");
  assert.equal(createFromPath.mock.callCount(), 0);
  assert.equal(setIcon.mock.callCount(), 0);
});

test("development macOS uses the padded Dock asset rather than the window PNG", () => {
  mock.property(process, "platform", "darwin");
  applyAppIcon("/repo/packages/desktop/build/icon.png");
  assert.equal(createFromPath.mock.callCount(), 1);
  assert.deepEqual(createFromPath.mock.calls[0].arguments, [
    "/repo/packages/desktop/build/icon_macos.png",
  ]);
  assert.deepEqual(setIcon.mock.calls[0].arguments, [image]);
});

test("an unreadable development image leaves the existing Dock icon in place", () => {
  mock.property(process, "platform", "darwin");
  imageIsEmpty = true;
  applyAppIcon("/repo/packages/desktop/build/icon.png");
  assert.equal(setIcon.mock.callCount(), 0);
});

test("missing Dock support leaves the application icon untouched", () => {
  mock.property(process, "platform", "darwin");
  app.dock = undefined;
  applyAppIcon("/repo/packages/desktop/build/icon.png");
  assert.equal(createFromPath.mock.callCount(), 0);
});

for (const platform of ["win32", "linux"]) {
  test(`${platform} never uses the macOS Dock override`, () => {
    mock.property(process, "platform", platform);
    applyAppIcon("/repo/packages/desktop/build/icon.png");
    assert.equal(createFromPath.mock.callCount(), 0);
    assert.equal(setIcon.mock.callCount(), 0);
  });
}
