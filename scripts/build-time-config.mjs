import { normalizeCCbuddyUpdateManifestUrl } from "../packages/desktop/scripts/ccbuddy-update-policy.mjs";

/** Explicit CCbuddy build inputs; absent telemetry and update ports stay closed. */
export async function resolveBuildTimeConfig(env = process.env) {
  // 修复：上游配置装配遗漏本地模块，还删除了自有更新源 define；
  // 从显式构建输入恢复同一策略，不能用上游账号或内部默认配置补齐。
  const updateManifestUrl = normalizeCCbuddyUpdateManifestUrl(env.CCBUDDY_UPDATE_MANIFEST_URL);
  return {
    armsRumEndpoint: env.CCBUDDY_ARMS_RUM_ENDPOINT?.trim() ?? "",
    telemetryReportEndpoint: env.CCBUDDY_TELEMETRY_REPORT_ENDPOINT?.trim() ?? "",
    autoUpdateEnabled: updateManifestUrl !== null,
    updateManifestUrl: updateManifestUrl ?? "",
    cdnBaseUrl: env.CCBUDDY_CDN_BASE_URL?.trim() ?? "",
  };
}

export function createBuildTimeConfigDefines(config) {
  return {
    __CCBUDDY_ARMS_RUM_ENDPOINT__: JSON.stringify(config.armsRumEndpoint),
    __CCBUDDY_TELEMETRY_REPORT_ENDPOINT__: JSON.stringify(config.telemetryReportEndpoint),
    __CCBUDDY_AUTO_UPDATE_ENABLED__: JSON.stringify(config.autoUpdateEnabled),
    __CCBUDDY_UPDATE_MANIFEST_URL__: JSON.stringify(config.updateManifestUrl),
    __CCBUDDY_CDN_BASE_URL__: JSON.stringify(config.cdnBaseUrl),
  };
}
