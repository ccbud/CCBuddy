import {
  buildRuntimeCCbuddyEndpointUrls,
  CCBUDDY_ENV,
  type RuntimeCCbuddyEndpointEnv,
} from "@ccbuddy/shared";

interface RendererImportMetaEnv {
  VITE_CCBUDDY_BASE_URL?: string;
  VITE_CCBUDDY_ENDPOINT_ORIGIN?: string;
}

function readRendererImportMetaEnv(): RendererImportMetaEnv {
  return ((import.meta as ImportMeta & { env?: RendererImportMetaEnv }).env ??
    {}) as RendererImportMetaEnv;
}

function createRendererCCbuddyEndpointEnv(
  env: RendererImportMetaEnv = readRendererImportMetaEnv(),
): RuntimeCCbuddyEndpointEnv {
  return {
    CCBUDDY_ENV,
    // UI 侧的 ccbuddy-plan 占位 provider 以前只看 CCBUDDY_ENV，
    // 没有消费 Vite 注入的 base url，导致自定义测试域名时 renderer 和 host/service 可能不一致。
    CCBUDDY_BASE_URL: env.VITE_CCBUDDY_BASE_URL,
    CCBUDDY_ENDPOINT_ORIGIN: env.VITE_CCBUDDY_ENDPOINT_ORIGIN,
  };
}

export const RENDERER_CCBUDDY_ENDPOINT_URLS = buildRuntimeCCbuddyEndpointUrls(
  createRendererCCbuddyEndpointEnv(),
);
