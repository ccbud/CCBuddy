import type { CCbuddyRuntimeEnv } from "./runtimeEnv.js";

export type CCbuddyEnv = "test" | "production";
/** 安装包身份：决定应用名、app id、Electron 数据目录与更新策略；与后端环境 `CCbuddyEnv` 是两个轴。 */
export type CCbuddyProductFlavor = "production" | "preview";
export type ArmsRumEnv = "local" | "prod";

// 非构建环境（如 e2e 测试的 mocha）下 define 不存在，用 typeof 检查 + fallback 避免 ReferenceError
declare const __CCBUDDY_ENV__: string;
declare const __CCBUDDY_PRODUCT_FLAVOR__: string;
declare const __CCBUDDY_ARMS_RUM_ENDPOINT__: string;
declare const __CCBUDDY_TELEMETRY_REPORT_ENDPOINT__: string;
declare const __CCBUDDY_AUTO_UPDATE_ENABLED__: boolean;

export function normalizeCCbuddyEnv(value: string | undefined): CCbuddyEnv {
  return value?.trim().toLowerCase() === "production" ? "production" : "test";
}

export const CCBUDDY_ENV = normalizeCCbuddyEnv(
  typeof __CCBUDDY_ENV__ !== "undefined" ? __CCBUDDY_ENV__ : undefined,
);

/**
 * 身份缺省跟随后端环境（test → preview，production → production）。
 * 桌面构建通过 `CCBUDDY_PREVIEW_IDENTITY=1` 显式注入 preview，得到连接生产后端的 Preview 包；
 * 未注入 define 的 bundle（web、CLI、测试）沿用旧的单轴语义。
 */
export function normalizeCCbuddyProductFlavor(
  value: string | undefined,
  ccbuddyEnv: CCbuddyEnv,
): CCbuddyProductFlavor {
  const normalized = value?.trim().toLowerCase();
  if (normalized === "production" || normalized === "preview") {
    return normalized;
  }
  return ccbuddyEnv === "production" ? "production" : "preview";
}

export const CCBUDDY_PRODUCT_FLAVOR = normalizeCCbuddyProductFlavor(
  typeof __CCBUDDY_PRODUCT_FLAVOR__ !== "undefined" ? __CCBUDDY_PRODUCT_FLAVOR__ : undefined,
  CCBUDDY_ENV,
);
export const CCBUDDY_APP_VERSION_ENV = "CCBUDDY_APP_VERSION" as const;
export const CCBUDDY_BUILD_COMMIT_ID_ENV = "CCBUDDY_BUILD_COMMIT_ID" as const;

// ── 运行时环境变量（不经过编译打包，启动时从 process.env 读取） ──
// 启用调试模式，值为 inspect-brk 的端口号，如 CCBUDDY_DEBUG=9230
export const RUNTIME_CCBUDDY_DEBUG =
  typeof process !== "undefined" ? process.env.CCBUDDY_DEBUG : undefined;

// ── 构建期可选能力（见 docs/desktop/build-time-optional-capabilities.md），未注入时一律关闭 ──
/** ARMS RUM 上报地址；为空时 SDK 以 enable=false 初始化，不产生上报。 */
export const CCBUDDY_ARMS_RUM_ENDPOINT: string =
  typeof __CCBUDDY_ARMS_RUM_ENDPOINT__ !== "undefined" ? __CCBUDDY_ARMS_RUM_ENDPOINT__ : "";
/** 事件上报（数仓）地址；为空时不上报。 */
export const CCBUDDY_TELEMETRY_REPORT_ENDPOINT: string =
  typeof __CCBUDDY_TELEMETRY_REPORT_ENDPOINT__ !== "undefined"
    ? __CCBUDDY_TELEMETRY_REPORT_ENDPOINT__
    : "";
/** 桌面自动更新是否启用。 */
export const CCBUDDY_AUTO_UPDATE_ENABLED: boolean =
  typeof __CCBUDDY_AUTO_UPDATE_ENABLED__ !== "undefined" ? __CCBUDDY_AUTO_UPDATE_ENABLED__ : false;

/** 将本地运行态与编译期 CCBUDDY_ENV 映射为 ARMS 控制台识别的上报环境标签 */
export function mapCCbuddyEnvToArmsRumEnv(runtimeEnv: CCbuddyRuntimeEnv): ArmsRumEnv {
  return runtimeEnv !== "development" && CCBUDDY_ENV === "production" ? "prod" : "local";
}
