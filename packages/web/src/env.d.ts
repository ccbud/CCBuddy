declare module "*.css";
declare module "@ccbuddy/ui/styles.css";

interface ImportMetaEnv {
  // 本文件手写声明了 Vite env 形状，内置 BASE_URL 也需要显式补上，
  // 普通入口根据 base 判断实际页面路径。
  readonly BASE_URL: string;
  readonly DEV: boolean;
  readonly PROD: boolean;
  readonly VITE_DEV_ORIGIN?: string;
  readonly VITE_CONVERSATION_SHARE_PREVIEW_MOCK?: string;
  readonly VITE_WEB_AUTH_ALLOW_DEV_RETURN_TO?: string;
  readonly VITE_CCBUDDY_BASE_URL?: string;
  readonly VITE_CCBUDDY_ENDPOINT_ORIGIN?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
