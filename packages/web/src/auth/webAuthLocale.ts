import type { WebOAuthProviderId } from "./browserOAuthCredentialRepo.js";

type WebAuthLocale = "zh-CN" | "en-US";

interface WebAuthPageCopy {
  defaultRegion: "zai_cn" | "zai";
  regionLabel: string;
  authorizeAction: string;
  waiting: string;
  authorizationHint: string;
  cancelAction: string;
  brand: string;

  callbackTitle: string;
  callbackDescription: string;
  callbackErrorTitle: string;
  callbackErrorDescription: string;
  retryAction: string;
}

const WEB_AUTH_COPY = {
  "zh-CN": {
    defaultRegion: "zai_cn",
    regionLabel: "账号区域",
    authorizeAction: "通过浏览器授权登录",
    waiting: "等待授权完成",
    authorizationHint: "正在前往授权页面，授权完成后会自动返回。",
    cancelAction: "取消",
    brand: "CCbuddy",

    callbackTitle: "正在完成登录",
    callbackDescription: "请稍候，正在校验账号身份。",
    callbackErrorTitle: "登录失败",
    callbackErrorDescription: "授权流程未完成，请重新登录。",
    retryAction: "重新登录",
  },
  "en-US": {
    defaultRegion: "zai",
    regionLabel: "Account region",
    authorizeAction: "Authorize in browser",
    waiting: "Waiting for authorization",
    authorizationHint:
      "Opening the authorization page. You will return here automatically after authorizing.",
    cancelAction: "Cancel",
    brand: "CCbuddy",

    callbackTitle: "Finishing Sign-In",
    callbackDescription: "Verifying your account identity.",
    callbackErrorTitle: "Sign-In Failed",
    callbackErrorDescription: "The authorization flow did not complete. Sign in again.",
    retryAction: "Sign In Again",
  },
} satisfies Record<WebAuthLocale, WebAuthPageCopy>;

function resolveWebAuthLocale(language?: string): WebAuthLocale {
  const candidate =
    language ??
    document.documentElement.lang ??
    navigator.language ??
    navigator.languages?.[0] ??
    "";

  return candidate.toLowerCase().startsWith("zh") ? "zh-CN" : "en-US";
}

export function getWebAuthCopy(locale: WebAuthLocale = resolveWebAuthLocale()): WebAuthPageCopy {
  return WEB_AUTH_COPY[locale];
}
