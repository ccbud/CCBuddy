import type { IOAuthService } from "./oauth.js";

const loginUnavailable = (): never => {
  throw new Error("CCbuddy uses only user-configured model services");
};

/** Kept at the RPC boundary so an old caller cannot start a cloud login. */
export function createDisabledOAuthService(): IOAuthService {
  return {
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
