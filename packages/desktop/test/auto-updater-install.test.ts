import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PlatformChannels } from "@ccbuddy/shared";

const fixture = vi.hoisted(() => ({
  app: {
    isPackaged: true,
    getVersion: vi.fn(() => "2.0.17"),
    on: vi.fn(),
    relaunch: vi.fn(),
    exit: vi.fn(),
  },
  updater: {
    on: vi.fn(),
    setFeedURL: vi.fn(),
    checkForUpdates: vi.fn(async () => null),
    quitAndInstall: vi.fn(),
    installerPath: "C:\\updates\\CCbuddy-setup.exe",
    autoInstallOnAppQuit: true,
  },
  ipc: { handle: vi.fn(), on: vi.fn() },
  dialog: { showMessageBox: vi.fn(async () => ({ response: 0 })) },
  logger: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
  prepare: vi.fn(async () => {}),
}));

vi.mock("node:child_process", async () => {
  const actual = await vi.importActual<typeof import("node:child_process")>("node:child_process");
  return {
    ...actual,
    execFile: (
      _file: string,
      _args?: readonly string[],
      optionsOrCallback?: unknown,
      callback?: (error: NodeJS.ErrnoException) => void,
    ) => {
      const notify = typeof optionsOrCallback === "function" ? optionsOrCallback : callback;
      notify?.(Object.assign(new Error("sudo"), { code: 1 }));
    },
  };
});
vi.mock("../scripts/powershell-command.mjs", () => ({
  verifyWindowsAuthenticodeSignature: vi.fn(async () => null),
}));
vi.mock("electron", () => ({
  app: fixture.app,
  BrowserWindow: { getAllWindows: () => [], getFocusedWindow: () => null },
  dialog: fixture.dialog,
  ipcMain: fixture.ipc,
  Menu: { getApplicationMenu: () => null },
}));
vi.mock("electron-updater", () => ({
  default: { autoUpdater: fixture.updater },
  CancellationToken: class {},
}));
vi.mock("../src/main/logger.js", () => ({ logger: fixture.logger }));
vi.mock("../src/main/manifestUpdateProvider.js", () => ({
  ManifestUpdateProvider: class {},
  getElectronReleasePlatform: () => "darwin-arm64",
}));

function registeredHandler(mock: ReturnType<typeof vi.fn>, event: string) {
  const registration = mock.mock.calls.find(([name]) => name === event);
  expect(registration, `missing handler for ${event}`).toBeDefined();
  return registration![1] as (...args: unknown[]) => unknown;
}

function assertOrdinaryQuitDoesNotInstall() {
  // 普通退出不再注册 before-quit 安装，也不允许 updater 在退出时自动安装。
  expect(fixture.app.on.mock.calls.some(([name]) => name === "before-quit")).toBe(false);
  expect(fixture.updater.autoInstallOnAppQuit).toBe(false);
}

async function stageUpdate() {
  registeredHandler(fixture.updater.on, "update-downloaded")({ version: "2.0.18" });
  await vi.advanceTimersByTimeAsync(0);
}

async function requestInstall() {
  await registeredHandler(fixture.ipc.handle, PlatformChannels.QuitAndInstallUpdate)();
}

beforeEach(async () => {
  vi.resetModules();
  vi.clearAllMocks();
  vi.useFakeTimers();
  vi.stubGlobal("process", { ...process, platform: "darwin" });
  const { initAutoUpdater } = await import("../src/main/autoUpdater.js");
  await initAutoUpdater({ onBeforeQuitAndInstall: fixture.prepare });
  await vi.advanceTimersByTimeAsync(0);
  await stageUpdate();
});

afterEach(() => {
  vi.clearAllTimers();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("updater install handoff", () => {
  it("does not install when the app quits without an explicit update action", () => {
    assertOrdinaryQuitDoesNotInstall();
    expect(fixture.updater.quitAndInstall).not.toHaveBeenCalled();
    expect(fixture.prepare).not.toHaveBeenCalled();
  });

  it("allows delayed native quits without starting another installation", async () => {
    await requestInstall();
    assertOrdinaryQuitDoesNotInstall();
    expect(fixture.updater.quitAndInstall).toHaveBeenCalledTimes(1);
    expect(fixture.prepare).toHaveBeenCalledTimes(1);
  });

  it("ignores duplicate IPC requests after native handoff", async () => {
    await requestInstall();
    await requestInstall();
    registeredHandler(fixture.ipc.on, PlatformChannels.QuitAndInstallUpdate)();
    await vi.advanceTimersByTimeAsync(0);
    expect(fixture.updater.quitAndInstall).toHaveBeenCalledTimes(1);
    expect(fixture.prepare).toHaveBeenCalledTimes(1);
  });

  it("waits for shutdown preparation and ignores concurrent install requests", async () => {
    let completePreparation!: () => void;
    fixture.prepare.mockImplementationOnce(
      () =>
        new Promise<void>((resolve) => {
          completePreparation = resolve;
        }),
    );
    const pending = requestInstall();
    await requestInstall();
    expect(fixture.prepare).toHaveBeenCalledTimes(1);
    expect(fixture.updater.quitAndInstall).not.toHaveBeenCalled();
    completePreparation();
    await pending;
    expect(fixture.updater.quitAndInstall).toHaveBeenCalledTimes(1);
    assertOrdinaryQuitDoesNotInstall();
  });

  it("relaunches after failed preparation and does not install again in-process", async () => {
    const error = new Error("shutdown preparation failed");
    fixture.prepare.mockRejectedValueOnce(error);
    await expect(requestInstall()).rejects.toThrow(error);
    expect(fixture.updater.quitAndInstall).not.toHaveBeenCalled();
    expect(fixture.app.relaunch).toHaveBeenCalledTimes(1);
    expect(fixture.app.exit).toHaveBeenCalledWith(0);
    await stageUpdate();
    await requestInstall();
    expect(fixture.prepare).toHaveBeenCalledTimes(1);
    expect(fixture.updater.quitAndInstall).not.toHaveBeenCalled();
    expect(fixture.app.relaunch).toHaveBeenCalledTimes(1);
  });

  it("relaunches after a synchronous handoff exception and does not retry in-process", async () => {
    const error = new Error("native install failed");
    fixture.updater.quitAndInstall.mockImplementationOnce(() => {
      throw error;
    });
    await expect(requestInstall()).rejects.toThrow(error);
    expect(fixture.app.relaunch).toHaveBeenCalledTimes(1);
    expect(fixture.app.exit).toHaveBeenCalledWith(0);
    await stageUpdate();
    await requestInstall();
    expect(fixture.updater.quitAndInstall).toHaveBeenCalledTimes(1);
    expect(fixture.app.relaunch).toHaveBeenCalledTimes(1);
  });

  it("relaunches after a native staging error instead of installing the failed package again", async () => {
    await requestInstall();
    registeredHandler(fixture.updater.on, "error")(new Error("Squirrel staging failed"));
    await vi.advanceTimersByTimeAsync(0);
    expect(fixture.app.relaunch).toHaveBeenCalledTimes(1);
    await expect(requestInstall()).resolves.toBeUndefined();
    await stageUpdate();
    await requestInstall();
    expect(fixture.updater.quitAndInstall).toHaveBeenCalledTimes(1);
    expect(fixture.app.relaunch).toHaveBeenCalledTimes(1);
  });

  it("handles a legacy IPC handoff exception without an unhandled rejection", async () => {
    const error = new Error("legacy native install failed");
    fixture.updater.quitAndInstall.mockImplementationOnce(() => {
      throw error;
    });
    registeredHandler(fixture.ipc.on, PlatformChannels.QuitAndInstallUpdate)();
    await vi.advanceTimersByTimeAsync(0);
    expect(fixture.logger.error).toHaveBeenCalledWith(
      "[auto-update] quit and install failed:",
      error,
    );
    expect(fixture.app.relaunch).toHaveBeenCalledTimes(1);
    await stageUpdate();
    await requestInstall();
    expect(fixture.updater.quitAndInstall).toHaveBeenCalledTimes(1);
  });

  it("keeps the handoff guard when an older background check fails", async () => {
    let rejectCheck!: (error: Error) => void;
    fixture.updater.checkForUpdates.mockImplementationOnce(
      () =>
        new Promise<null>((_resolve, reject) => {
          rejectCheck = reject;
        }),
    );
    await stageUpdate();
    await requestInstall();
    rejectCheck(new Error("background check failed"));
    registeredHandler(fixture.updater.on, "error")(
      new Error("background check failed"),
      "Cannot check for updates: background check failed",
    );
    await vi.advanceTimersByTimeAsync(0);
    assertOrdinaryQuitDoesNotInstall();
    await requestInstall();
    expect(fixture.updater.quitAndInstall).toHaveBeenCalledTimes(1);
    expect(fixture.app.relaunch).not.toHaveBeenCalled();
  });

  it.each(["win32", "linux"])("keeps explicit install single-flight on %s", async (platform) => {
    vi.stubGlobal("process", { ...process, platform });
    await requestInstall();
    await requestInstall();
    expect(fixture.updater.quitAndInstall).toHaveBeenCalledTimes(1);
    expect(fixture.prepare).toHaveBeenCalledTimes(1);
    assertOrdinaryQuitDoesNotInstall();
  });
});
