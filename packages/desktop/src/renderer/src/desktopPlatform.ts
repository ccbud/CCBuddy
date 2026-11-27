import { recordArmsCustomEventForE2E } from "@ccbuddy/ui";
import {
  DesktopCommandIds,
  buildLocalMediaPreviewUrl,
  resolveLocaleFromLanguageTag,
  unwrapRemoteWorkspaceBindResult,
  type IPlatformService,
} from "@ccbuddy/shared";

import { desktopBrowserPlatformBridge } from "./desktopBrowserPlatformBridge.js";
import { registerAppControlNavigationHandler } from "#src/app-control-navigation/renderer.js";
import { createDesktopPluginSandboxPlatform } from "./plugin-sandbox/desktopPluginSandboxPlatform.js";

declare global {
  interface Window {
    ccbuddyHistory?: NonNullable<IPlatformService["historyReview"]>;
  }
}

export function createDesktopPlatform(options: {
  isLocalDevelopmentRuntime: boolean;
}): IPlatformService {
  return {
    onAppControlNavigation: (handler) =>
      registerAppControlNavigationHandler(
        {
          subscribe: (listener) => window.ccbuddy.onAppControlNavigationMessage(listener),
          register: (generation) =>
            window.ccbuddy.sendAppControlNavigation({ type: "register", generation }),
          unregister: (generation) =>
            window.ccbuddy.sendAppControlNavigation({ type: "unregister", generation }),
          reply: (message) =>
            window.ccbuddy.sendAppControlNavigation({ type: "result", ...message }),
        },
        handler,
        crypto.randomUUID(),
      ),
    canSelectFilePath: true,
    canOpenLocalFiles: true,
    pluginSandbox: createDesktopPluginSandboxPlatform(),
    createLocalMediaPreviewUrl: buildLocalMediaPreviewUrl,
    isLocalDevelopmentRuntime: options.isLocalDevelopmentRuntime,
    selectDirectory: () => window.ccbuddy.selectDirectory(),
    selectDirectories: () => window.ccbuddy.selectDirectories(),
    selectFile: () => window.ccbuddy.selectFile(),
    selectFiles: () => window.ccbuddy.selectFiles?.() ?? Promise.resolve([]),
    createTempTextAttachment: (payload) => window.ccbuddy.createTempTextAttachment(payload),
    materializeWorkflowArtifactFile: (payload) =>
      window.ccbuddy.materializeWorkflowArtifactFile(payload),
    onRemoteConnectionLog: (handler) => window.ccbuddy.onRemoteConnectionLog(handler),
    onRemoteSessionClosed: (handler) => window.ccbuddy.onRemoteSessionClosed(handler),
    // Source 自动重连会替换 logical session；统一由 preload bridge 转发换代事件。
    onRemoteSessionReconnected: (handler) =>
      window.ccbuddy.onRemoteSessionReconnected?.(handler) ?? (() => {}),
    activateOrSetWorkspace: (path) =>
      window.ccbuddy.activateOrSetWorkspace?.(path) ?? Promise.resolve({ activated: false }),
    connectRemote: (remoteOptions, requestId, context) =>
      window.ccbuddy.connectRemote(remoteOptions, requestId, context),
    requestSourceSettingsAttachment: (sourceServerId) =>
      window.ccbuddy.requestSourceSettingsAttachment?.(sourceServerId) ??
      Promise.reject(new Error("Source settings attachment bridge unavailable")),
    cancelPendingRemoteConnection: (requestId) =>
      window.ccbuddy.cancelPendingRemoteConnection?.(requestId) ?? Promise.resolve(),
    bindRemoteWorkspaceSessionContext: async (context) => {
      if (!window.ccbuddy.bindRemoteWorkspaceSessionContext) {
        throw new Error("Desktop bindRemoteWorkspaceSessionContext bridge unavailable");
      }
      // preload 返回结构化结果，在页面一侧还原错误才能保留 code/retryable。
      return unwrapRemoteWorkspaceBindResult(
        await window.ccbuddy.bindRemoteWorkspaceSessionContext(context),
      );
    },
    startWebRemoteControl: (context) => window.ccbuddy.startWebRemoteControl(context),
    stopWebRemoteControl: () => window.ccbuddy.stopWebRemoteControl(),
    getWebRemoteControlStatus: () => window.ccbuddy.getWebRemoteControlStatus(),
    onWebRemoteControlStatusChanged: (handler) =>
      window.ccbuddy.onWebRemoteControlStatusChanged?.(handler) ?? (() => {}),
    disposeRemoteSession: (sessionId) => window.ccbuddy.disposeRemoteSession(sessionId),
    isDockerAvailable: () => window.ccbuddy.isDockerAvailable(),
    listWSLDistros: () => window.ccbuddy.listWSLDistros(),
    listDockerContainers: () => window.ccbuddy.listDockerContainers(),
    listSSHConfigAliases: () => window.ccbuddy.listSSHConfigAliases(),
    loadMcpFromUserDirectory: (payload) => window.ccbuddy.loadMcpFromUserDirectory(payload),
    saveMcpToUserDirectory: (payload) => window.ccbuddy.saveMcpToUserDirectory(payload),
    migrateLegacyCommonMcp: (payload) => window.ccbuddy.migrateLegacyCommonMcp(payload),
    openExternal: (url) => window.ccbuddy.openExternal(url),
    openFeedback: () => window.ccbuddy.executeDesktopCommand(DesktopCommandIds.OpenFeedback),
    openCommunity: () => window.ccbuddy.executeDesktopCommand(DesktopCommandIds.OpenCommunity),
    canOpenCommunity: (locale) => window.ccbuddy.canOpenCommunity(locale),
    openInFileManager: (path) => window.ccbuddy.openInFileManager(path),
    openExternalFile: (path) => window.ccbuddy.openExternalFile(path),
    openCuaPermissionOnboarding: window.ccbuddy.openCuaPermissionOnboarding
      ? (permissionOptions) =>
          window.ccbuddy.openCuaPermissionOnboarding?.(permissionOptions) ??
          Promise.resolve({ success: false, error: "not_supported" })
      : undefined,
    prepareCuaHelperPermissionDrag: window.ccbuddy.prepareCuaHelperPermissionDrag
      ? () =>
          window.ccbuddy.prepareCuaHelperPermissionDrag?.() ??
          Promise.resolve({ success: false, error: "not_supported" })
      : undefined,
    startCuaHelperPermissionDrag: window.ccbuddy.startCuaHelperPermissionDrag
      ? () => window.ccbuddy.startCuaHelperPermissionDrag?.()
      : undefined,
    notifyWebRemoteControlAuthStateChanged: (change) =>
      window.ccbuddy.notifyWebRemoteControlAuthStateChanged(change),
    registerOAuthState: (payload) => window.ccbuddy.registerOAuthState(payload),
    onOAuthCallback: (callback) => window.ccbuddy.onOAuthCallback(callback),
    onPaymentCallback: (callback) => window.ccbuddy.onPaymentCallback(callback),
    onShareImport: (callback) => window.ccbuddy.onShareImport?.(callback) ?? (() => {}),
    notifyRendererReady: () => window.ccbuddy.notifyRendererReady(),
    syncTelemetryContext: (context) => window.ccbuddy.syncTelemetryContext(context),
    reportTelemetryEvent: (payload) => window.ccbuddy.reportTelemetryEvent(payload),
    reportArmsCustomEvent: (payload) => {
      recordArmsCustomEventForE2E(payload);
      return window.ccbuddy.reportArmsCustomEvent(payload);
    },
    getRendererActionTraceConfig: window.ccbuddy.getRendererActionTraceConfig
      ? () => window.ccbuddy.getRendererActionTraceConfig!()
      : undefined,
    onRendererActionTraceConfigChanged: window.ccbuddy.onRendererActionTraceConfigChanged
      ? (callback) => window.ccbuddy.onRendererActionTraceConfigChanged!(callback)
      : undefined,
    reportLocalTtftBatch: (batch) => window.ccbuddy.reportLocalTtftBatch(batch),
    reportRendererActionTraceBatch: window.ccbuddy.reportRendererActionTraceBatch
      ? (batch) => window.ccbuddy.reportRendererActionTraceBatch!(batch)
      : undefined,
    reportRendererHeapSample: window.ccbuddy.reportRendererHeapSample
      ? (sample) => window.ccbuddy.reportRendererHeapSample!(sample)
      : undefined,
    showTaskNotification: (payload) => window.ccbuddy.showTaskNotification(payload),
    // 扩展的系统通知（§18.1 H8）：只有桌面实现；Web 与手机远控没有这两个方法，Renderer 按 unsupported 处理。
    showExtensionNotification: (payload) => window.ccbuddy.showExtensionNotification(payload),
    onExtensionNotificationClick: (handler) => window.ccbuddy.onExtensionNotificationClick(handler),
    syncWindowTabs: (paths) => window.ccbuddy.syncWindowTabs(paths),
    syncRemoteWorkspaceSessions: (targets) => window.ccbuddy.syncRemoteWorkspaceSessions?.(targets),
    syncWindowUnreadCount: (count) => window.ccbuddy.syncWindowUnreadCount(count),
    syncActiveTaskSession: (sessionId) => window.ccbuddy.syncActiveTaskSession(sessionId),
    syncAppSettings: (patch) => window.ccbuddy.syncAppSettings?.(patch),
    // 桥缺失（旧 preload 升级窗口）时按 supported 兜底，与 Windows 现状一致，设置开关可用。
    getCloseToTrayCapability: () =>
      window.ccbuddy.getCloseToTrayCapability?.() ??
      Promise.resolve({ supported: true, gnomeLikeWithoutTray: false }),
    setShortcutRecordingActive: (active) => window.ccbuddy.setShortcutRecordingActive?.(active),
    onFocusTab: (handler) => window.ccbuddy.onFocusTab(handler),
    onNewTab: (handler) => window.ccbuddy.onNewTab(handler),
    onCloseActiveContextRequest: (handler) =>
      window.ccbuddy.onCloseActiveContextRequest?.(handler) ?? (() => {}),
    onOpenBrowserUrl: (handler) => window.ccbuddy.onOpenBrowserUrl?.(handler) ?? (() => {}),
    onEmbeddedBrowserPermissionPrompt: (handler) =>
      window.ccbuddy.onEmbeddedBrowserPermissionPrompt?.(handler) ?? (() => {}),
    resolveEmbeddedBrowserPermissionPrompt: (request) =>
      window.ccbuddy.resolveEmbeddedBrowserPermissionPrompt?.(request),
    getEmbeddedBrowserSitePermissions: () =>
      window.ccbuddy.getEmbeddedBrowserSitePermissions?.() ?? Promise.resolve({}),
    setEmbeddedBrowserSitePermission: (request) =>
      window.ccbuddy.setEmbeddedBrowserSitePermission?.(request) ?? Promise.resolve({}),
    clearEmbeddedBrowserSitePermissions: () =>
      window.ccbuddy.clearEmbeddedBrowserSitePermissions?.() ?? Promise.resolve({}),
    resetEmbeddedBrowserSitePermission: (request) =>
      window.ccbuddy.resetEmbeddedBrowserSitePermission?.(request) ?? Promise.resolve({}),
    onBrowserViewScreenshotSurfacePrepare: (handler) =>
      window.ccbuddy.onBrowserViewScreenshotSurfacePrepare?.(handler) ?? (() => {}),
    onBrowserViewScreenshotSurfaceRelease: (handler) =>
      window.ccbuddy.onBrowserViewScreenshotSurfaceRelease?.(handler) ?? (() => {}),
    browserViewScreenshotSurfaceReady: (payload) =>
      window.ccbuddy.browserViewScreenshotSurfaceReady?.(payload),
    ...desktopBrowserPlatformBridge,
    onNewTask: (handler) => window.ccbuddy.onNewTask(handler),
    onOpenWorkspace: (handler) => {
      // 开发态或升级后的旧窗口可能仍运行未暴露 onOpenWorkspace 的 preload，
      // renderer 直接调用会在启动时崩溃。这里和 activateOrSetWorkspace 一样做兼容兜底，
      // 缺少该 bridge 时只禁用原生菜单回调，不影响应用继续打开。
      return window.ccbuddy.onOpenWorkspace?.(handler) ?? (() => {});
    },
    onOpenWorkspacePath: (handler) => window.ccbuddy.onOpenWorkspacePath?.(handler) ?? (() => {}),
    onOpenFeedbackDialog: (handler) => window.ccbuddy.onOpenFeedbackDialog?.(handler) ?? (() => {}),
    onOpenTicketsPanel: (handler) => window.ccbuddy.onOpenTicketsPanel?.(handler) ?? (() => {}),
    onWindowFullscreenChanged: (handler) => window.ccbuddy.onWindowFullscreenChanged(handler),
    getDesktopWindowChromeState: window.ccbuddy.getDesktopWindowChromeState
      ? () => window.ccbuddy.getDesktopWindowChromeState!()
      : undefined,
    onDesktopWindowChromeStateChanged: window.ccbuddy.onDesktopWindowChromeStateChanged
      ? (handler) => window.ccbuddy.onDesktopWindowChromeStateChanged!(handler)
      : undefined,
    getWindowControlsOverlayMetrics: () =>
      window.ccbuddy.getWindowControlsOverlayMetrics?.() ?? null,
    onWindowControlsOverlayChanged: (handler) =>
      window.ccbuddy.onWindowControlsOverlayChanged?.(handler) ?? (() => {}),
    getDesktopZoomLevel: () =>
      window.ccbuddy.getDesktopZoomLevel?.() ?? Promise.resolve({ zoomLevel: 0 }),
    onDesktopZoomLevelChanged: (handler) =>
      window.ccbuddy.onDesktopZoomLevelChanged?.(handler) ?? (() => {}),
    onTaskNotificationClick: (handler) => window.ccbuddy.onTaskNotificationClick(handler),
    exportLogs: () => window.ccbuddy.exportLogs(),
    captureWindowScreenshot: () =>
      window.ccbuddy.captureWindowScreenshot?.() ?? Promise.resolve(null),
    onUpdateReady: (callback) => window.ccbuddy.onUpdateReady(callback),
    onUpdateCheckResult: (callback) => window.ccbuddy.onUpdateCheckResult(callback),
    onUpdateStateChanged: (callback) =>
      window.ccbuddy.onUpdateStateChanged?.(callback) ?? (() => {}),
    getUpdateState: () =>
      window.ccbuddy.getUpdateState?.() ?? Promise.resolve({ kind: "idle", enabled: true }),
    downloadUpdate: () => window.ccbuddy.downloadUpdate?.() ?? Promise.resolve(),
    cancelUpdateDownload: () => window.ccbuddy.cancelUpdateDownload?.() ?? Promise.resolve(),
    openUpdateStatusWindow: () => window.ccbuddy.openUpdateStatusWindow?.() ?? Promise.resolve(),
    // 合并时遗漏历史平台转接，侧栏因能力缺失同时隐藏日历和会话列表，原生菜单也无法导航。
    // 恢复既有 preload 只读桥与菜单订阅，让 App 继续作为主视图状态的唯一所有者。
    onOpenHistoryViewRequested: (listener) =>
      window.ccbuddy.onOpenHistoryViewRequested?.(listener) ?? (() => {}),
    historyReview: window.ccbuddyHistory
      ? {
          protocolVersion: 1,
          list: () => window.ccbuddyHistory!.list(),
          load: (id) => window.ccbuddyHistory!.load(id),
          refresh: () => window.ccbuddyHistory!.refresh(),
          onRefreshEvent: (listener) =>
            window.ccbuddyHistory!.onRefreshEvent((event) => listener(event)),
        }
      : undefined,
    getAutoUpdatePreferences: () =>
      window.ccbuddy.getAutoUpdatePreferences?.() ??
      Promise.resolve({ autoDownloadAndInstallUpdates: false }),
    setAutoDownloadAndInstallUpdates: (enabled) =>
      window.ccbuddy.setAutoDownloadAndInstallUpdates?.(enabled) ?? Promise.resolve(),
    getDesktopSessionActivity: () =>
      window.ccbuddy.getDesktopSessionActivity?.() ??
      Promise.resolve({ runningAgentSessionCount: 0 }),
    getCCbuddyStdioTapDevState: () =>
      window.ccbuddy.getCCbuddyStdioTapDevState?.() ??
      Promise.resolve({ enabled: false, visible: false, logDir: "", statePath: "" }),
    executePreinstalledToolsCommand: (command) =>
      window.ccbuddy.executePreinstalledToolsCommand!(command),
    getPreinstalledToolsState: () => window.ccbuddy.getPreinstalledToolsState!(),
    onPreinstalledToolsState: (callback) =>
      window.ccbuddy.onPreinstalledToolsState?.(callback) ?? (() => {}),
    onSettingsChanged: (callback) => window.ccbuddy.onSettingsChanged?.(callback) ?? (() => {}),
    onApplicationLocaleChanged: (callback) =>
      window.ccbuddy.onApplicationLocaleChanged?.(callback) ?? (() => {}),
    onPostUpdateReleaseNotes: (callback) => window.ccbuddy.onPostUpdateReleaseNotes(callback),
    acknowledgePostUpdateReleaseNotes: (version) =>
      window.ccbuddy.acknowledgePostUpdateReleaseNotes(version),
    skipUpdateVersion: (version) =>
      window.ccbuddy.skipUpdateVersion?.(version) ?? Promise.resolve(),
    quitAndInstallUpdate: () => window.ccbuddy.quitAndInstallUpdate(),
    getInstalledEditors: (filePath) => window.ccbuddy.getInstalledEditors(filePath),
    getFileApplications: (target) => window.ccbuddy.getFileApplications(target),
    openFileWithApplication: (applicationId, target) =>
      window.ccbuddy.openFileWithApplication(applicationId, target),
    getApplicationIcon: (bundleId) =>
      window.ccbuddy.getApplicationIcon?.(bundleId) ?? Promise.resolve(null),
    openInEditor: (editorId, path, editorOptions) =>
      window.ccbuddy.openInEditor(editorId, path, editorOptions),
    executeDesktopCommand: (command) => window.ccbuddy.executeDesktopCommand(command),
    setApplicationLocale: (locale) => window.ccbuddy.setApplicationLocale(locale),
    setReplyLanguage: (language) => window.ccbuddy.setReplyLanguage(language),
    getSystemLocale: () =>
      window.ccbuddy.getSystemLocale?.() ??
      Promise.resolve(resolveLocaleFromLanguageTag(navigator.language)),
    setTitleBarTheme: (theme) => window.ccbuddy.setTitleBarTheme(theme),
    getDeviceId: () =>
      (window as Window & { __CCBUDDY_DEVICE_ID__?: string }).__CCBUDDY_DEVICE_ID__ ?? "",
  };
}
