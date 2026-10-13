import { randomUUID } from "node:crypto";
import { BrowserWindow, desktopCapturer, ipcMain, webContents } from "electron";
import type { WebContents, WebFrameMain } from "electron";
import { PlatformChannels, type EmbeddedBrowserPermissionResolveRequest } from "@ccbuddy/shared";
import type {
  EmbeddedBrowserPermissionLogger,
  EmbeddedBrowserPermissionPolicyOptions,
  EmbeddedBrowserPermissionPromptAction,
  EmbeddedBrowserPermissionPromptRequest,
} from "./embeddedBrowserPermissionPolicy.js";

/**
 * 内置浏览器权限弹窗的 main ↔ renderer 桥：
 * - promptPermission / devicePicker / onDisplayMediaRequest 把策略模块的决策点
 *   转成 EmbeddedBrowserPermissionPrompt 事件推送到 guest 宿主窗口；
 * - renderer 的用户决策经 EmbeddedBrowserPermissionResolve 回传；
 * - 20s 无响应按 dismiss/cancel 结算（面板不可见或 agent 后台场景自然拒绝）。
 */
export interface EmbeddedBrowserPermissionUiBridge {
  promptPermission(
    request: EmbeddedBrowserPermissionPromptRequest,
  ): Promise<EmbeddedBrowserPermissionPromptAction>;
  devicePicker: NonNullable<EmbeddedBrowserPermissionPolicyOptions["devicePicker"]>;
  onDisplayMediaRequest: NonNullable<
    EmbeddedBrowserPermissionPolicyOptions["onDisplayMediaRequest"]
  >;
  registerResolveListener(): void;
}

const ALLOWED_ACTIONS = new Set([
  "allow-always",
  "allow-session",
  "block-always",
  "dismiss",
  "cancel",
]);

/**
 * 模块级桥持有者（getPluginSandboxHost 同款模式）：index.ts 启动时装配，
 * desktopWindowChrome 等窗口层直接取用，避免多层 options 透传。
 */
let activeBridge: EmbeddedBrowserPermissionUiBridge | null = null;

export function setActiveEmbeddedBrowserPermissionUiBridge(
  bridge: EmbeddedBrowserPermissionUiBridge | null,
): void {
  activeBridge = bridge;
}

/** 蓝牙设备选择守卫用的设备选择器；桥未装配时返回 undefined（守卫回退为取消请求）。 */
export function getEmbeddedBrowserDevicePicker():
  | EmbeddedBrowserPermissionUiBridge["devicePicker"]
  | undefined {
  return activeBridge?.devicePicker.bind(activeBridge);
}

/** IPC 载荷的运行时校验：requestId 必须是待决请求，resolution 形状必须可识别。 */
export function parseEmbeddedBrowserPermissionResolveRequest(
  payload: unknown,
): EmbeddedBrowserPermissionResolveRequest | null {
  if (!payload || typeof payload !== "object") return null;
  const candidate = payload as {
    requestId?: unknown;
    resolution?: { action?: unknown; sourceId?: unknown; deviceId?: unknown };
  };
  if (typeof candidate.requestId !== "string" || !candidate.requestId) return null;
  const action = candidate.resolution?.action;
  if (typeof action !== "string") return null;
  if (action === "share-screen") {
    if (typeof candidate.resolution?.sourceId !== "string" || !candidate.resolution.sourceId) {
      return null;
    }
    return {
      requestId: candidate.requestId,
      resolution: { action, sourceId: candidate.resolution.sourceId },
    };
  }
  if (action === "select-device") {
    if (typeof candidate.resolution?.deviceId !== "string" || !candidate.resolution.deviceId) {
      return null;
    }
    return {
      requestId: candidate.requestId,
      resolution: { action, deviceId: candidate.resolution.deviceId },
    };
  }
  if (!ALLOWED_ACTIONS.has(action)) return null;
  return { requestId: candidate.requestId, resolution: { action } as { action: "allow-always" } };
}

export function createEmbeddedBrowserPermissionUiBridge(deps: {
  logger: EmbeddedBrowserPermissionLogger;
  /** 弹窗无响应结算时长；测试注入短值。 */
  promptTimeoutMs?: number;
}): EmbeddedBrowserPermissionUiBridge {
  const { logger } = deps;
  const timeoutMs = deps.promptTimeoutMs ?? 20_000;
  const pending = new Map<
    string,
    { host: WebContents; resolve: (resolution: unknown) => void; dismiss: () => void }
  >();

  const resolveHost = (hostWebContentsId: number | undefined): WebContents | undefined => {
    const host =
      hostWebContentsId !== undefined ? webContents.fromId(hostWebContentsId) : undefined;
    // 权限属于发起 guest 的宿主；旧的焦点/首窗 fallback 会把其他窗口的决定误用到此请求。
    return host &&
      !host.isDestroyed() &&
      host.getType() === "window" &&
      BrowserWindow.fromWebContents(host)
      ? host
      : undefined;
  };

  const resolveRequestHostId = (input: {
    hostWebContentsId?: number;
    frame?: WebFrameMain;
  }): number | undefined => {
    if (input.hostWebContentsId !== undefined) return input.hostWebContentsId;
    const guest = input.frame ? webContents.fromFrame(input.frame) : undefined;
    return guest?.hostWebContents?.id ?? guest?.id;
  };

  const sendPrompt = (
    host: WebContents,
    event: { requestId: string; kind: "permission" | "screen-share" | "device" } & Record<
      string,
      unknown
    >,
  ): boolean => {
    if (host.isDestroyed()) {
      logger.warn("[embedded-browser-permission] prompt target window unavailable");
      return false;
    }
    try {
      host.send(PlatformChannels.EmbeddedBrowserPermissionPrompt, event);
      return true;
    } catch (error) {
      logger.warn("[embedded-browser-permission] prompt delivery failed", error);
      return false;
    }
  };

  /** 建一个待决请求：renderer 决策经 resolver 回来，超时按 fallback 结算。 */
  const openPendingPrompt = <T>(
    hostWebContentsId: number | undefined,
    event: { requestId: string; kind: "permission" | "screen-share" | "device" } & Record<
      string,
      unknown
    >,
    settle: (resolution: unknown) => T,
    fallbackValue: T,
  ): Promise<T> => {
    const { requestId } = event;
    const host = resolveHost(hostWebContentsId);
    if (!host) {
      logger.warn("[embedded-browser-permission] prompt owner unavailable");
      return Promise.resolve(fallbackValue);
    }
    return new Promise<T>((resolve) => {
      let settled = false;
      const finish = (value: T) => {
        if (settled) return;
        settled = true;
        pending.delete(requestId);
        clearTimeout(timer);
        host.removeListener("destroyed", onOwnerUnavailable);
        host.removeListener("render-process-gone", onOwnerUnavailable);
        resolve(value);
      };
      const onOwnerUnavailable = () => finish(fallbackValue);
      const timer = setTimeout(() => {
        logger.info("[embedded-browser-permission] decision=denied", {
          requestId,
          source: "prompt-timeout",
        });
        finish(fallbackValue);
      }, timeoutMs);
      pending.set(requestId, {
        host,
        resolve: (resolution) => finish(settle(resolution)),
        dismiss: onOwnerUnavailable,
      });
      // 关闭/崩溃直接结算，不等超时，也不重新选择其他窗口。
      host.once("destroyed", onOwnerUnavailable);
      host.once("render-process-gone", onOwnerUnavailable);
      if (!sendPrompt(host, event)) finish(fallbackValue);
    });
  };

  return {
    promptPermission(request) {
      return openPendingPrompt(
        request.hostWebContentsId,
        {
          requestId: randomUUID(),
          kind: "permission",
          origin: request.origin,
          permission: request.permission,
          ...(request.mediaTypes ? { mediaTypes: [...request.mediaTypes] } : {}),
          ...(request.guestWebContentsId !== undefined
            ? { guestWebContentsId: request.guestWebContentsId }
            : {}),
        },
        (resolution) => {
          const action = (resolution as { action?: string })?.action;
          return (["allow-always", "allow-session", "block-always", "dismiss"] as const).includes(
            action as never,
          )
            ? (action as EmbeddedBrowserPermissionPromptAction)
            : "dismiss";
        },
        "dismiss" as const,
      );
    },

    devicePicker(input) {
      // requestId 显式生成并保留在闭包：设备发现过程中 select-* 会连续 fire，
      // 同 requestId 的后续推送被 renderer 当作列表热更新而不是新弹窗。
      const requestId = randomUUID();
      const result = openPendingPrompt(
        resolveRequestHostId(input),
        {
          requestId,
          kind: "device",
          origin: input.origin,
          permission: input.permission,
          devices: input.devices,
          ...(input.guestWebContentsId !== undefined
            ? { guestWebContentsId: input.guestWebContentsId }
            : {}),
        },
        (resolution) => {
          const candidate = resolution as { action?: string; deviceId?: string };
          return candidate?.action === "select-device" && candidate.deviceId
            ? { deviceId: candidate.deviceId }
            : null;
        },
        null,
      );
      return {
        result,
        updateDevices: (devices) => {
          const request = pending.get(requestId);
          if (!request) return;
          const delivered = sendPrompt(request.host, {
            requestId,
            kind: "device",
            origin: input.origin,
            permission: input.permission,
            devices,
            ...(input.guestWebContentsId !== undefined
              ? { guestWebContentsId: input.guestWebContentsId }
              : {}),
          });
          if (!delivered) request.dismiss();
        },
      };
    },

    onDisplayMediaRequest(input, callback) {
      const hostWebContentsId = resolveRequestHostId(input);
      if (!resolveHost(hostWebContentsId)) {
        invokeDisplayMediaCallback(callback, {});
        return;
      }
      void desktopCapturer
        .getSources({ types: ["screen", "window"], thumbnailSize: { width: 320, height: 180 } })
        .then(async (sources) => {
          const picked = await openPendingPrompt(
            hostWebContentsId,
            {
              requestId: randomUUID(),
              kind: "screen-share",
              origin: input.origin,
              screens: sources.map((source) => ({
                sourceId: source.id,
                name: source.name,
                // source.id 形如 "screen:0:0" / "window:12345:0"，据此在 UI 分组展示。
                kind: source.id.startsWith("screen:") ? ("screen" as const) : ("window" as const),
                thumbnailDataUrl: `data:image/jpeg;base64,${source.thumbnail.toJPEG(60).toString("base64")}`,
              })),
            },
            (resolution) => {
              const candidate = resolution as { action?: string; sourceId?: string };
              return candidate?.action === "share-screen" ? (candidate.sourceId ?? null) : null;
            },
            null,
          );
          const source = picked ? sources.find((candidate) => candidate.id === picked) : undefined;
          invokeDisplayMediaCallback(callback, source ? { video: source } : {});
        })
        .catch((error: unknown) => {
          logger.warn("[embedded-browser-permission] screen share sources unavailable:", error);
          invokeDisplayMediaCallback(callback, {});
        });
    },

    registerResolveListener() {
      ipcMain.on(PlatformChannels.EmbeddedBrowserPermissionResolve, (event, payload: unknown) => {
        const parsed = parseEmbeddedBrowserPermissionResolveRequest(payload);
        const request = parsed ? pending.get(parsed.requestId) : undefined;
        if (!parsed || !request) {
          logger.warn("[embedded-browser-permission] ignored malformed or unknown resolve payload");
          return;
        }
        // requestId 只负责关联；必须同时绑定宿主主 frame，其他窗口/子 frame 无权结算。
        if (
          request.host.isDestroyed() ||
          event.sender !== request.host ||
          event.senderFrame !== request.host.mainFrame
        ) {
          logger.warn("[embedded-browser-permission] ignored resolve from a different owner");
          return;
        }
        request.resolve(parsed.resolution);
      });
    },
  };
}

/**
 * Electron 41 在「页面请求了 video 但回调未提供流」时会从 callback 内部同步抛
 * TypeError（用户取消共享的正常路径）；直接在 promise 链里调用会被外层 catch 误记为
 * 源获取失败并二次回调。此处隔离后不再向外传播。
 */
function invokeDisplayMediaCallback(callback: (result: unknown) => void, result: unknown): void {
  try {
    callback(result);
  } catch {
    // 页面侧已按取消/拒绝路径收尾，无需处理。
  }
}
