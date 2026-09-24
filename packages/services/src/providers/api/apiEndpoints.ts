import { buildRuntimeCCbuddyApiUrl, resolveZaiBusinessBaseUrl } from "@ccbuddy/shared";

export const CCBUDDY_CLIENT_SCENES_URL = buildRuntimeCCbuddyApiUrl(
  process.env,
  "/api/v1/client/scenes",
);

export const ZAI_API_HOST = resolveZaiBusinessBaseUrl(process.env);
