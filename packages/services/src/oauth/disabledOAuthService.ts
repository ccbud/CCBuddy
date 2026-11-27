import type { OAuthAccountAvailability } from "@ccbuddy/shared";
import { Event } from "@ccbuddy/rpc";
import type { IOAuthService } from "./oauth.js";

const noAccountAvailability: OAuthAccountAvailability = {
  loginProvider: null,
  userId: null,
  sessionRevision: null,
  families: [],
};

const loginUnavailable = (): never => {
  throw new Error("CCbuddy uses only user-configured model services");
};

/** Kept at the RPC boundary so an old caller cannot start a cloud login. */
export function createDisabledOAuthService(): IOAuthService {
  return {
    // 没有可变更的会话，因此从不发布。
    onDidChangeSession: Event.None,
    async getAccountAvailability() {
      return noAccountAvailability;
    },
    async getWebsiteSession() {
      return null;
    },
    async refreshAccountProfile() {
      return noAccountAvailability;
    },
    async getProviders() {
      return [];
    },
    async getActiveProvider() {
      return null;
    },
    async restoreCachedSession() {
      return null;
    },
    async restoreCachedSessionState() {
      return { status: "signed-out" };
    },
    async restoreSession() {
      return null;
    },
    async startOAuth() {
      return loginUnavailable();
    },
    async startOAuthWithPolling() {
      return loginUnavailable();
    },
    async pollPendingOAuth() {
      return null;
    },
    async handleCallback() {
      return null;
    },
    async refreshToken() {
      return loginUnavailable();
    },
    async logout() {},
    async logoutAll() {},
    async cancelPending() {},
  };
}
