import { materializeCCbuddyBuiltinProviderConfig } from "@ccbuddy/services/node";

declare const __CCBUDDY_BUILTIN_PROVIDER_CONFIG_JSON__: string | undefined;

interface MaterializeBundledCCbuddyBuiltinProviderConfigOptions {
  readonly environmentConfigRoot: string;
  readonly content: string;
}

/** 返回构建时嵌入远端 Server 的 CCbuddy Built-in Provider Config。 */
export function readBundledCCbuddyBuiltinProviderConfig(): string {
  if (typeof __CCBUDDY_BUILTIN_PROVIDER_CONFIG_JSON__ !== "string") {
    throw new Error("当前构建未嵌入 CCbuddy Built-in Provider Config");
  }
  return __CCBUDDY_BUILTIN_PROVIDER_CONFIG_JSON__;
}

/**
 * 将 CCbuddy Built-in Config 原子物化到所属环境的固定资源副本。
 * 升级前退出旧进程；不保留按内容 hash 增长的历史文件。
 */
export async function materializeBundledCCbuddyBuiltinProviderConfig(
  options: MaterializeBundledCCbuddyBuiltinProviderConfigOptions,
): Promise<string> {
  return materializeCCbuddyBuiltinProviderConfig(options);
}
