import { BIGMODEL_PROVIDER_ID, ZAI_PROVIDER_ID } from "@ccbuddy/shared";

/** 本仓支持的登录 provider。private 分享的 owner 身份是 provider 特定的，两边都要能登。 */
export type WebOAuthProviderId = typeof ZAI_PROVIDER_ID | typeof BIGMODEL_PROVIDER_ID;

export function isWebOAuthProviderId(value: unknown): value is WebOAuthProviderId {
  return value === ZAI_PROVIDER_ID || value === BIGMODEL_PROVIDER_ID;
}
