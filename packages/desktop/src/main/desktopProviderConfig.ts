import { app } from "electron";
import { join } from "node:path";

export function resolveCCbuddyBuiltinProviderConfigFilePath(options?: {
  readonly appPath?: string;
  readonly env?: Readonly<Record<string, string | undefined>>;
  readonly isPackaged?: boolean;
  readonly resourcesPath?: string;
}): string {
  const explicitPath = (options?.env ?? process.env)[
    "CCBUDDY_BUILTIN_PROVIDER_CONFIG_FILE"
  ]?.trim();
  if (explicitPath) return explicitPath;
  if (options?.isPackaged ?? app.isPackaged) {
    return join(
      options?.resourcesPath ?? process.resourcesPath,
      "config/provider/ccbuddy-builtin.json",
    );
  }
  // 修复：CCbuddy 只提供一份本地 BYOK 模板；按上游环境选 test 文件会使真实 Host 模型配置加载失败。
  // 与构建和正式包共用已有文件，环境身份不能改变配置来源。
  const filename = "ccbuddy-builtin.json";
  return join(options?.appPath ?? app.getAppPath(), "../../config/provider", filename);
}
