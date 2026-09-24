export const CCBUDDY_BUILTIN_PROVIDER_CONFIG_FILE_ENV = "CCBUDDY_BUILTIN_PROVIDER_CONFIG_FILE";
export const CCBUDDY_BUILTIN_PROVIDER_BUNDLED_CONFIG_FILE_ENV =
  "CCBUDDY_BUILTIN_PROVIDER_BUNDLED_CONFIG_FILE";
export const CCBUDDY_PERSONAL_PROVIDER_CONFIG_FILE_ENV = "CCBUDDY_PERSONAL_PROVIDER_CONFIG_FILE";
export const PERSONAL_PROVIDER_CONFIG_FILE_NAME = "provider_config.json";

export interface NodeProviderRuntimePaths {
  readonly ccbuddyBuiltinFilePath: string;
  readonly personalFilePath: string;
}

export function createNodeProviderRuntimePathEnv(
  paths: NodeProviderRuntimePaths,
): Record<string, string> {
  return {
    [CCBUDDY_BUILTIN_PROVIDER_CONFIG_FILE_ENV]: paths.ccbuddyBuiltinFilePath,
    [CCBUDDY_PERSONAL_PROVIDER_CONFIG_FILE_ENV]: paths.personalFilePath,
  };
}

export function resolveNodeProviderRuntimePaths(
  env: Readonly<Record<string, string | undefined>>,
): NodeProviderRuntimePaths | null {
  const ccbuddyBuiltinFilePath = env[CCBUDDY_BUILTIN_PROVIDER_CONFIG_FILE_ENV]?.trim();
  const personalFilePath = env[CCBUDDY_PERSONAL_PROVIDER_CONFIG_FILE_ENV]?.trim();
  if (!ccbuddyBuiltinFilePath && !personalFilePath) return null;
  if (!ccbuddyBuiltinFilePath || !personalFilePath) {
    throw new Error("CCbuddy Built-in 与 Personal Provider Config 路径必须同时提供");
  }
  return Object.freeze({ ccbuddyBuiltinFilePath, personalFilePath });
}
