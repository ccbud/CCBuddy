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
  },
  ipc: { handle: vi.fn(), on: vi.fn() },
  logger: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
  prepare: vi.fn(async () => {}),
}));

vi.mock("electron", () => ({
  app: fixture.app,
  BrowserWindow: { getAllWindows: () => [] },
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

async function stageUpdate() {
  registeredHandler(fixture.updater.on, "update-downloaded")({ version: "2.0.18" });
  await vi.advanceTimersByTimeAsync(0);
}

async function requestInstall() {
  await registeredHandler(fixture.ipc.handle, PlatformChannels.QuitAndInstallUpdate)();
}

function requestQuit() {
  const event = { preventDefault: vi.fn() };
  registeredHandler(fixture.app.on, "before-quit")(event);
  return event;
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
  it("allows delayed native quits without starting another installation", async () => {
    await requestInstall();
    for (const attempt of [1, 2, 3]) {
      const event = requestQuit();
      await vi.advanceTimersByTimeAsync(0);
      expect(event.preventDefault, `native quit ${attempt}`).not.toHaveBeenCalled();
    }
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
    expect(requestQuit().preventDefault).not.toHaveBeenCalled();
  });

  it("initiates one install on ordinary quit and allows the later native quit", async () => {
    expect(requestQuit().preventDefault).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(0);
    expect(fixture.updater.quitAndInstall).toHaveBeenCalledTimes(1);
    expect(requestQuit().preventDefault).not.toHaveBeenCalled();
    expect(fixture.prepare).toHaveBeenCalledTimes(1);
  });

  it("rejects failed preparation without installing and permits a restaged retry", async () => {
    const error = new Error("shutdown preparation failed");
    fixture.prepare.mockRejectedValueOnce(error);
    await expect(requestInstall()).rejects.toThrow(error);
    expect(fixture.updater.quitAndInstall).not.toHaveBeenCalled();
    expect(requestQuit().preventDefault).not.toHaveBeenCalled();
    await stageUpdate();
    await requestInstall();
    expect(fixture.prepare).toHaveBeenCalledTimes(2);
    expect(fixture.updater.quitAndInstall).toHaveBeenCalledTimes(1);
  });

  it("reports a synchronous handoff exception and permits a restaged retry", async () => {
    const error = new Error("native install failed");
    fixture.updater.quitAndInstall.mockImplementationOnce(() => {
      throw error;
    });
    await expect(requestInstall()).rejects.toThrow(error);
    expect(requestQuit().preventDefault).not.toHaveBeenCalled();
    await stageUpdate();
    await requestInstall();
    expect(fixture.updater.quitAndInstall).toHaveBeenCalledTimes(2);
    expect(requestQuit().preventDefault).not.toHaveBeenCalled();
  });

  it("releases a failed asynchronous handoff so a restaged update can install", async () => {
    await requestInstall();
    registeredHandler(fixture.updater.on, "error")(new Error("Squirrel staging failed"));
    await vi.advanceTimersByTimeAsync(0);
    expect(requestQuit().preventDefault).not.toHaveBeenCalled();
    await expect(requestInstall()).rejects.toThrow("Update is not ready to install");
    await stageUpdate();
    await requestInstall();
    expect(fixture.updater.quitAndInstall).toHaveBeenCalledTimes(2);
    expect(requestQuit().preventDefault).not.toHaveBeenCalled();
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
    expect(requestQuit().preventDefault).not.toHaveBeenCalled();
    await stageUpdate();
    await requestInstall();
    expect(fixture.updater.quitAndInstall).toHaveBeenCalledTimes(2);
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
    await vi.advanceTimersByTimeAsync(0);
    expect(requestQuit().preventDefault).not.toHaveBeenCalled();
    await requestInstall();
    expect(fixture.updater.quitAndInstall).toHaveBeenCalledTimes(1);
  });

  it.each(["win32", "linux"])("keeps explicit install single-flight on %s", async (platform) => {
    vi.stubGlobal("process", { ...process, platform });
    await requestInstall();
    await requestInstall();
    expect(fixture.updater.quitAndInstall).toHaveBeenCalledTimes(1);
    expect(fixture.prepare).toHaveBeenCalledTimes(1);
    expect(requestQuit().preventDefault).not.toHaveBeenCalled();
  });
});
