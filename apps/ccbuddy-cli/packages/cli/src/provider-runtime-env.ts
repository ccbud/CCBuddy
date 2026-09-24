import { existsSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import {
  materializeCCbuddyBuiltinProviderConfig,
  PERSONAL_PROVIDER_CONFIG_FILE_NAME,
  CCBUDDY_BUILTIN_PROVIDER_CONFIG_FILE_ENV,
  CCBUDDY_PERSONAL_PROVIDER_CONFIG_FILE_ENV,
} from "@ccbuddy/provider-node";
import type { CliEnv } from "./env.js";

export const SEA_CCBUDDY_BUILTIN_PROVIDER_CONFIG_ASSET_KEY = "ccbuddy-provider/ccbuddy-builtin.json";

type SeaProviderConfigAssets = Pick<typeof import("node:sea"), "getAsset" | "isSea">;

interface PrepareCliProviderRuntimeEnvOptions {
  readonly argv: readonly string[];
  readonly env: CliEnv;
  readonly dataBaseDir?: string;
  readonly entrypoint?: string;
  readonly sea?: SeaProviderConfigAssets;
  readonly appVersion?: string;
  readonly platform?: string;
}

/** 为运行 Core 或写入模型选择的 CLI Entry 定位同一 Environment 的 Provider Config。 */
export async function prepareCliProviderRuntimeEnv(
  options: PrepareCliProviderRuntimeEnvOptions,
): Promise<Record<string, string>> {
  if (!requiresProviderRuntime(options.argv)) return {};

  const explicitCCbuddyBuiltin = options.env[CCBUDDY_BUILTIN_PROVIDER_CONFIG_FILE_ENV]?.trim();
  const explicitPersonal = options.env[CCBUDDY_PERSONAL_PROVIDER_CONFIG_FILE_ENV]?.trim();
  const dataBaseDir = options.dataBaseDir ?? options.env.CCBUDDY_DATA_BASE_DIR?.trim() ?? homedir();
  if (explicitCCbuddyBuiltin && explicitPersonal) {
    return {
      [CCBUDDY_BUILTIN_PROVIDER_CONFIG_FILE_ENV]: explicitCCbuddyBuiltin,
      [CCBUDDY_PERSONAL_PROVIDER_CONFIG_FILE_ENV]: explicitPersonal,
    };
  }

  const ccbuddyBuiltinFilePath =
    explicitCCbuddyBuiltin ??
    (await resolveBundledCCbuddyBuiltinProviderConfig({
      dataBaseDir,
      entrypoint: options.entrypoint ?? process.argv[1],
      sea: options.sea ?? getSeaProviderConfigAssets(),
    }));
  const personalFilePath =
    explicitPersonal ?? join(dataBaseDir, ".ccbuddy", "v2", PERSONAL_PROVIDER_CONFIG_FILE_NAME);
  return {
    // 直接读取随包静态模板；不物化远端可刷新的 active cache。
    [CCBUDDY_BUILTIN_PROVIDER_CONFIG_FILE_ENV]: ccbuddyBuiltinFilePath,
    [CCBUDDY_PERSONAL_PROVIDER_CONFIG_FILE_ENV]: personalFilePath,
  };
}

function requiresProviderRuntime(argv: readonly string[]): boolean {
  if (argv.some((arg) => arg === "--help" || arg === "-h" || arg === "--version" || arg === "-v")) {
    return false;
  }
  if (
    argv.some(
      (arg) =>
        arg === "--prompt" ||
        arg.startsWith("--prompt=") ||
        arg === "--target" ||
        arg.startsWith("--target="),
    )
  ) {
    return true;
  }

  const command = argv[0];
  if (command === undefined || command.startsWith("-")) return true;
  return (
    command === "tui" ||
    command === "app-server" ||
    command === "agent-server"
  );
}

async function resolveBundledCCbuddyBuiltinProviderConfig(input: {
  readonly dataBaseDir: string;
  readonly entrypoint: string | undefined;
  readonly sea: SeaProviderConfigAssets | undefined;
}): Promise<string> {
  if (input.sea?.isSea()) {
    const content = input.sea.getAsset(SEA_CCBUDDY_BUILTIN_PROVIDER_CONFIG_ASSET_KEY, "utf8");
    return materializeCCbuddyBuiltinProviderConfig({
      environmentConfigRoot: join(input.dataBaseDir, ".ccbuddy", "v2"),
      content,
    });
  }

  const entrypoint = input.entrypoint?.trim();
  if (!entrypoint) throw new Error("无法定位 CCbuddy 内置模型服务模板：缺少入口路径");
  // 全局 bin 可以是软链接，随包配置必须相对真实入口定位。
  const entryDirectory = dirname(realpathSync(resolve(entrypoint)));
  const candidates = [
    join(entryDirectory, "provider", "ccbuddy-builtin.json"),
    resolve(entryDirectory, "../../../../../config/provider/ccbuddy-builtin.json"),
  ];
  const candidate = candidates.find((filePath) => existsSync(filePath));
  if (candidate) return candidate;
  throw new Error(`无法定位 CCbuddy 内置模型服务模板：${candidates.join(", ")}`);
}

function getSeaProviderConfigAssets(): SeaProviderConfigAssets | undefined {
  const getBuiltinModule = process.getBuiltinModule as
    | ((id: "node:sea") => typeof import("node:sea"))
    | undefined;
  return getBuiltinModule?.("node:sea");
}
