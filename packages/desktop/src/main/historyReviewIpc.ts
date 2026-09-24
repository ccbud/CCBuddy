import { app, BrowserWindow, ipcMain, type IpcMainInvokeEvent } from "electron";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { HistoryLibrary } from "@ccbuddy/history";
import { HistoryReviewChannels } from "@ccbuddy/shared";
import {
  parseHistoryRefreshEvent,
  parseHistorySessionDetail,
  parseHistorySnapshot,
} from "@ccbuddy/history/contract";
import { isMainApplicationWindowWebContents } from "./resourceManagerWindow.js";
import { isTrustedHistoryMainFrameUrl } from "./historyMainFrameUrl.js";

function expectedMainRendererUrl(): string {
  return !app.isPackaged && process.env["ELECTRON_RENDERER_URL"]
    ? new URL(process.env["ELECTRON_RENDERER_URL"]).href
    : pathToFileURL(join(import.meta.dirname, "../renderer/index.html")).href;
}

export function isTrustedHistoryMainWindow(window: BrowserWindow | null): window is BrowserWindow {
  return Boolean(
    window &&
    !window.isDestroyed() &&
    isMainApplicationWindowWebContents(window.webContents.id) &&
    isTrustedHistoryMainFrameUrl(window.webContents.getURL(), expectedMainRendererUrl()),
  );
}

export function isTrustedHistoryMainWindowSender(event: IpcMainInvokeEvent): boolean {
  const window = BrowserWindow.fromWebContents(event.sender);
  if (!isTrustedHistoryMainWindow(window) || event.senderFrame !== window.webContents.mainFrame) {
    return false;
  }
  return isTrustedHistoryMainFrameUrl(event.senderFrame.url, expectedMainRendererUrl());
}

function assertHistoryReaderSender(event: IpcMainInvokeEvent): BrowserWindow {
  const window = BrowserWindow.fromWebContents(event.sender);
  if (!window || !isTrustedHistoryMainWindowSender(event)) {
    throw new Error("History access is limited to trusted CCbuddy main windows");
  }
  return window;
}

function assertNoArguments(args: readonly unknown[]): void {
  if (args.length !== 0) {
    throw new TypeError("This history operation accepts no arguments");
  }
}

function parseCatalogSessionId(args: readonly unknown[], library: HistoryLibrary): string {
  const id = args[0];
  if (
    args.length !== 1 ||
    typeof id !== "string" ||
    id.length === 0 ||
    id.length > 2_048 ||
    !library.list().sessions.some((session) => session.id === id)
  ) {
    throw new TypeError("Unknown history session ID");
  }
  return id;
}

/** Main owns the disposable catalog; the renderer receives only typed read DTOs. */
export function registerHistoryReviewIpc(): void {
  const states = new WeakMap<
    BrowserWindow,
    { library: HistoryLibrary; refreshes: Set<AbortController> }
  >();
  const stateFor = (window: BrowserWindow) => {
    let state = states.get(window);
    if (!state) {
      state = { library: new HistoryLibrary(), refreshes: new Set() };
      states.set(window, state);
      // 导航或 renderer 崩溃后旧扫描不能继续向新页面发布进度。
      const abortRefreshes = () => {
        for (const refresh of state?.refreshes ?? []) refresh.abort();
      };
      window.webContents.on("did-start-loading", abortRefreshes);
      window.webContents.on("render-process-gone", abortRefreshes);
      window.once("closed", () => {
        abortRefreshes();
        states.delete(window);
      });
    }
    return state;
  };

  ipcMain.handle(HistoryReviewChannels.list, (event, ...args: unknown[]) => {
    const window = assertHistoryReaderSender(event);
    assertNoArguments(args);
    return parseHistorySnapshot(stateFor(window).library.list());
  });

  ipcMain.handle(HistoryReviewChannels.load, async (event, ...args: unknown[]) => {
    const window = assertHistoryReaderSender(event);
    const library = stateFor(window).library;
    const id = parseCatalogSessionId(args, library);
    return parseHistorySessionDetail(await library.load(id));
  });

  ipcMain.handle(HistoryReviewChannels.refresh, async (event, ...args: unknown[]) => {
    const window = assertHistoryReaderSender(event);
    assertNoArguments(args);
    const state = stateFor(window);
    const controller = new AbortController();
    state.refreshes.add(controller);
    try {
      const terminal = await state.library.refresh({
        signal: controller.signal,
        onEvent: (untrustedPayload) => {
          const payload = parseHistoryRefreshEvent(untrustedPayload);
          if (!window.isDestroyed() && isTrustedHistoryMainWindowSender(event)) {
            window.webContents.send(HistoryReviewChannels.refreshEvent, payload);
          }
        },
      });
      const validated = parseHistoryRefreshEvent(terminal);
      if (validated.type !== "terminal") {
        throw new TypeError("History refresh did not return a terminal result");
      }
      return validated;
    } finally {
      state.refreshes.delete(controller);
    }
  });
}
