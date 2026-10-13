import { createRoot } from "react-dom/client";
import {
  AppErrorBoundary,
  Root,
  CCbuddyIntlProvider,
  generateMobileDeviceFingerprint,
  installDocumentHiddenMotionPause,
  playTaskNotificationSound,
  setStreamClientId,
  type Theme,
} from "@ccbuddy/ui";
import "@ccbuddy/ui/styles.css";
import { connectViaWebSocket } from "@ccbuddy/client";
import type { IPlatformService, RemoteTarget, ServerRemoteInfo } from "@ccbuddy/shared";
import { WebCallbackPage } from "./auth/WebCallbackPage.js";
import { createWebAuthService } from "./auth/webAuthService.js";
import { WEB_ZAI_OAUTH_CONFIG, resolveWebAuthDevReturnTo } from "./auth/webZaiOAuthConfig.js";
import { parseOAuthState, resolveSafeAppReturnTo } from "./auth/oauthStateCodec.js";
import { resolveWebCommunityUrl, resolveWebHelpConfig } from "./communityUrl.js";
import {
  ConversationShareLandingLoader,
  ConversationShareLandingStatus,
} from "./share/ConversationShareLandingPage.js";
import {
  ConversationSharePreviewClient,
  resolveConversationShareRouteLocale,
} from "./share/conversationSharePreviewClient.js";
import {
  isConversationSharePath,
  resolveConversationShareCodeFromPath,
} from "./share/conversationShareRoute.js";

function resolveWebThemePreference(defaultTheme: Theme = "zai-dark"): Theme {
  const saved = localStorage.getItem("ccbuddy-theme");
  if (saved === "system") return saved;
  if (saved === "dark" || saved === "zai-dark") return "zai-dark";
  if (saved === "light" || saved === "zai-light") return "zai-light";
  return defaultTheme;
}

// 普通 Web 启动沿用本地主题偏好，分享页无偏好时使用浅色。
{
  const saved = resolveWebThemePreference(
    isConversationSharePath(window.location.pathname) ? "zai-light" : undefined,
  );
  const dark =
    saved === "system"
      ? window.matchMedia("(prefers-color-scheme: dark)").matches
      : saved === "zai-dark";
  document.documentElement.classList.toggle("dark", dark);
  document.documentElement.classList.toggle("theme-zai-light", !dark);
  document.documentElement.classList.toggle("theme-zai-dark", dark);
}

installDocumentHiddenMotionPause();
setStreamClientId(generateMobileDeviceFingerprint());
const root = createRoot(document.getElementById("root")!);
const webAuthService = createWebAuthService();

interface WebBootstrapResult {
  wsUrl: string;
  initialWorkspaceAbsPath?: string;
  initialWorkspaceIdentity?: string;
  initialTaskId?: string;
  restoreSession?: boolean;
  allowOpenWorkspace?: boolean;
}

async function resolveFeedbackUrl(): Promise<string | undefined> {
  return (await resolveWebHelpConfig()).feedback_url;
}

function renderConnectionError(error: unknown, unknownRoute = false): void {
  const zh = navigator.language.toLowerCase().startsWith("zh");
  root.render(
    <main className="flex min-h-screen items-center justify-center bg-background p-6 text-foreground">
      <section className="w-full max-w-sm rounded-xl border border-border bg-card p-6">
        <h1 className="text-ui-xl font-semibold">
          {unknownRoute
            ? zh
              ? "页面不存在"
              : "Page not found"
            : zh
              ? "连接失败"
              : "Connection failed"}
        </h1>
        {!unknownRoute ? (
          <p className="mt-3 text-ui-base text-foreground-subtle">
            {error instanceof Error ? error.message : String(error)}
          </p>
        ) : null}
        <button
          type="button"
          className="mt-4 h-8 rounded-lg bg-primary px-3 text-ui-base text-primary-foreground"
          onClick={() =>
            unknownRoute
              ? window.location.assign(import.meta.env.BASE_URL)
              : window.location.reload()
          }
        >
          {unknownRoute ? (zh ? "返回首页" : "Back home") : zh ? "重试" : "Retry"}
        </button>
      </section>
    </main>,
  );
}

function isWebOAuthCallback(params: URLSearchParams): boolean {
  return (
    ["/cn/share/callback", "/share/callback"].includes(window.location.pathname) &&
    params.has("state") &&
    (params.has("code") || params.has("error"))
  );
}

function renderWebAuthCallbackPage(): void {
  document.title = "CCbuddy - Sign In";
  const callbackState = parseOAuthState(
    new URLSearchParams(window.location.search).get("state") ?? "",
  );
  const safeRetryTarget = resolveSafeAppReturnTo(callbackState?.app_return_to);
  root.render(
    <WebCallbackPage
      authService={webAuthService}
      onSuccess={({ appReturnTo }) => window.location.replace(appReturnTo ?? "/")}
      onRetry={() => window.location.replace(safeRetryTarget ?? "/")}
    />,
  );
}

async function renderConversationSharePage(): Promise<void> {
  // 页面语言跟随路径前缀：/cn/share 中文，裸 /share 英文。
  const routeLocale = resolveConversationShareRouteLocale(window.location.pathname);
  // index.html 固定 lang="en"；不同步会让中文分享页对无障碍与浏览器翻译都报错语言。
  document.documentElement.lang = routeLocale;
  // 分享页必须设置 title：否则浏览器标签只显示 index.html 的通用标题。
  // 会话标题要等 preview 加载完，先给一个语言正确的兜底。
  document.title = routeLocale === "zh-CN" ? "CCbuddy 会话分享" : "CCbuddy Conversation Share";
  const shareCode = resolveConversationShareCodeFromPath(window.location.pathname);
  if (!shareCode) {
    root.render(
      <ConversationShareLandingStatus
        state={{ kind: "error", error: "invalid_contract" }}
        locale={routeLocale}
      />,
    );
    return;
  }

  const endpointOrigin =
    import.meta.env.VITE_CCBUDDY_BASE_URL?.trim().replace(/\/+$/u, "") || window.location.origin;
  const mockMode =
    import.meta.env.DEV && import.meta.env.VITE_CONVERSATION_SHARE_PREVIEW_MOCK === "true";
  // Share 加载失败不能只有通用 network 文案：需要区分 mock、endpoint 配置或跨域 fetch。
  // 这里只记录运行时路由与 endpoint，不记录完整 pathname，避免把 share code 写入日志。
  console.info("[conversation-share-web]", "preview_runtime_initialized", {
    browserOrigin: window.location.origin,
    routeKind: "canonical",
    endpointOrigin,
    transport: mockMode ? "mock" : "fetch",
  });
  const client = mockMode
    ? new (
        await import("./share/mockConversationSharePreviewClient.js")
      ).MockConversationSharePreviewClient()
    : new ConversationSharePreviewClient({ baseUrl: `${endpointOrigin}/api/v1` });
  const getMockToken = () =>
    mockMode && window.sessionStorage.getItem("ccbuddy:share:mock-auth") === "owner"
      ? "mock-owner-token"
      : null;
  const onLogout = () => {
    if (mockMode) {
      window.sessionStorage.removeItem("ccbuddy:share:mock-auth");
      window.location.reload();
      return;
    }
    void webAuthService.logout();
  };
  root.render(
    <ConversationShareLandingLoader
      shareCode={shareCode}
      client={client}
      getAccessToken={() => getMockToken() ?? webAuthService.getCCbuddyJwtToken()}
      onLogin={(provider) => {
        if (mockMode) {
          window.sessionStorage.setItem("ccbuddy:share:mock-auth", "owner");
          window.location.reload();
          return;
        }
        webAuthService.startLogin({
          provider,
          appReturnTo: window.location.href,
          redirectUri: WEB_ZAI_OAUTH_CONFIG.shareRedirectUri,
          devReturnTo: resolveWebAuthDevReturnTo(WEB_ZAI_OAUTH_CONFIG),
        });
      }}
      onLogout={onLogout}
      locale={routeLocale}
      theme={resolveWebThemePreference("zai-light")}
    />,
  );
}

function createWebPlatform(): IPlatformService {
  return {
    canSelectFilePath: false,
    selectDirectory: () => Promise.resolve(null),
    selectFile: () => Promise.resolve(null),
    selectFiles: () => Promise.resolve([]),
    getPathForFile: () => null,
    createTempTextAttachment: () =>
      Promise.reject(new Error("Temporary text attachments require a desktop host")),
    onRemoteConnectionLog: () => () => {},
    onRemoteSessionClosed: () => () => {},
    onBotRemoteWorkspaceReconnected: () => () => {},
    activateOrSetWorkspace: () => Promise.resolve({ activated: false }),
    // 普通 Web 当前只支持 server 的本地工作区，沿用已有能力边界。
    connectRemote: (options: RemoteTarget) =>
      Promise.resolve({
        success: false,
        error: `Remote connect is not supported in Web mode yet: ${options.kind}`,
      }),
    cancelPendingRemoteConnection: () => Promise.resolve(),
    disposeRemoteSession: () => Promise.resolve(),
    isDockerAvailable: () => Promise.resolve(false),
    listWSLDistros: () => Promise.resolve([]),
    listDockerContainers: () => Promise.resolve([]),
    listSSHConfigAliases: () => Promise.resolve([]),
    loadMcpFromUserDirectory: () => Promise.resolve({ servers: [] }),
    saveMcpToUserDirectory: () =>
      Promise.resolve({
        success: false,
        error: "MCP native directory management requires a desktop attachment",
      }),
    migrateLegacyCommonMcp: () =>
      Promise.resolve({ servers: {}, totalCount: 0, importedCount: 0, skippedCount: 0 }),
    openExternal: (url) => {
      window.open(url, "_blank", "noopener,noreferrer");
    },
    openFeedback: async () => {
      const url = await resolveFeedbackUrl();
      if (url) window.open(url, "_blank", "noopener,noreferrer");
    },
    openCommunity: async () => {
      const locale = document.documentElement.lang === "en-US" ? "en-US" : "zh-CN";
      const url = await resolveWebCommunityUrl(locale);
      if (url) window.open(url, "_blank", "noopener,noreferrer");
    },
    canOpenCommunity: async (locale) => Boolean(await resolveWebCommunityUrl(locale)),
    openInFileManager: () =>
      Promise.resolve({ success: false, error: "Not supported in web mode" }),
    openExternalFile: () => Promise.resolve({ success: false, error: "Not supported in web mode" }),
    registerOAuthState: () => {},
    onOAuthCallback: () => () => {},
    onPaymentCallback: () => () => {},
    onShareImport: () => () => {},
    notifyRendererReady: () => {},
    reportTelemetryEvent: () => Promise.resolve(),
    reportArmsCustomEvent: () => Promise.resolve(),
    showTaskNotification: (payload) => {
      if (
        document.hasFocus() ||
        typeof window.Notification === "undefined" ||
        window.Notification.permission !== "granted"
      )
        return;
      try {
        new window.Notification(payload.title, { body: payload.body, silent: true });
        void playTaskNotificationSound();
      } catch {
        /* 浏览器通知不可用不影响会话。 */
      }
    },
    syncWindowTabs: () => {},
    syncWindowUnreadCount: () => {},
    syncActiveTaskSession: () => {},
    onFocusTab: () => () => {},
    onNewTab: () => () => {},
    onCloseActiveContextRequest: () => () => {},
    onOpenBrowserUrl: () => () => {},
    onNewTask: () => () => {},
    onOpenWorkspace: () => () => {},
    onWindowFullscreenChanged: () => () => {},
    onTaskNotificationClick: () => () => {},
    exportLogs: () => Promise.resolve({ success: false, error: "Not supported in web mode" }),
    captureWindowScreenshot: () => Promise.resolve(null),
    importChromeBrowserData: () =>
      Promise.resolve({
        success: false,
        cookies: { imported: 0, skipped: 0, failed: 0 },
        localStorage: {
          originsImported: 0,
          entriesImported: 0,
          originsSkipped: 0,
          originsFailed: 0,
        },
        error: "chrome_import_not_supported" as const,
      }),
    clearEmbeddedBrowserData: () =>
      Promise.resolve({ success: false, error: "Not supported in web mode" }),
    onUpdateReady: () => () => {},
    onUpdateCheckResult: () => () => {},
    onUpdateStateChanged: () => () => {},
    getUpdateState: () => Promise.resolve({ kind: "idle", enabled: true }),
    downloadUpdate: () => Promise.resolve(),
    cancelUpdateDownload: () => Promise.resolve(),
    getDesktopSessionActivity: () => Promise.resolve({ runningAgentSessionCount: 0 }),
    getDesktopZoomLevel: () => Promise.resolve({ zoomLevel: 0 }),
    onDesktopZoomLevelChanged: () => () => {},
    onPostUpdateReleaseNotes: () => () => {},
    acknowledgePostUpdateReleaseNotes: () => Promise.resolve(),
    skipUpdateVersion: () => Promise.resolve(),
    quitAndInstallUpdate: () => Promise.resolve(),
    getInstalledEditors: () => Promise.resolve([]),
    openInEditor: () => Promise.resolve({ success: false, error: "Not supported in web mode" }),
    executeDesktopCommand: () => Promise.resolve(),
    setApplicationLocale: () => Promise.resolve(),
    setTitleBarTheme: () => Promise.resolve(),
    getDeviceId: () => {
      const nav = globalThis.navigator as Navigator & { platform?: string };
      return [
        nav?.platform ?? "",
        globalThis.screen?.width,
        globalThis.screen?.height,
        globalThis.screen?.colorDepth,
      ]
        .filter((part) => part !== undefined && part !== "")
        .join("|");
    },
  };
}

function resolveDefaultWsOrigin(): string {
  return `${window.location.protocol === "https:" ? "wss:" : "ws:"}//${window.location.host}`;
}

async function resolveWebBootstrap(): Promise<WebBootstrapResult> {
  const params = new URLSearchParams(window.location.search);
  const remoteId = params.get("remote");
  const wsUrl = remoteId
    ? `${resolveDefaultWsOrigin()}/ws/remote/${remoteId}`
    : `${resolveDefaultWsOrigin()}/ws`;

  if (remoteId) {
    return { wsUrl };
  }

  try {
    const response = await fetch("/api/server-info", {
      cache: "no-store",
    });
    if (!response.ok) {
      return { wsUrl };
    }
    const serverInfo = (await response.json()) as Partial<ServerRemoteInfo>;
    const workspace = Array.isArray(serverInfo.workspaces) ? serverInfo.workspaces[0] : undefined;
    return {
      wsUrl,
      ...(workspace?.path ? { initialWorkspaceAbsPath: workspace.path } : {}),
      ...(workspace?.workspaceIdentity
        ? { initialWorkspaceIdentity: workspace.workspaceIdentity }
        : {}),
    };
  } catch {
    return { wsUrl };
  }
}

async function bootstrapWebApp(): Promise<void> {
  const params = new URLSearchParams(window.location.search);
  if (isWebOAuthCallback(params)) {
    renderWebAuthCallbackPage();
    return;
  }
  if (isConversationSharePath(window.location.pathname)) {
    await renderConversationSharePage();
    return;
  }
  // 移除原因：只允许实际 Web 页面；旧手机入口作为未知路由处理，不读取配对参数。
  const basePath = new URL(import.meta.env.BASE_URL, window.location.origin).pathname;
  if (
    ![basePath, basePath.replace(/\/$/u, ""), `${basePath}index.html`].includes(
      window.location.pathname,
    )
  ) {
    renderConnectionError(undefined, true);
    return;
  }
  try {
    const bootstrap = await resolveWebBootstrap();
    const services = await connectViaWebSocket(bootstrap.wsUrl, { onClose: () => {} });
    document.title = "CCbuddy - Web + Server";
    root.render(
      <AppErrorBoundary>
        <CCbuddyIntlProvider
          settingService={services.settingService}
          broadcastService={services.broadcastService}
        >
          <Root
            services={services}
            platform={createWebPlatform()}
            initialWorkspaceAbsPath={bootstrap.initialWorkspaceAbsPath}
            initialWorkspaceIdentity={bootstrap.initialWorkspaceIdentity}
            initialTaskId={bootstrap.initialTaskId}
            restoreSession={bootstrap.restoreSession}
            allowOpenWorkspace={bootstrap.allowOpenWorkspace}
            preferDirectoryBrowser
            supportsEmbeddedBrowser={false}
            allowRemoteWorkspace={false}
          />
        </CCbuddyIntlProvider>
      </AppErrorBoundary>,
    );
  } catch (error) {
    renderConnectionError(error);
  }
}

void bootstrapWebApp();
