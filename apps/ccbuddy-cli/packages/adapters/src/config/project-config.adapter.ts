import { existsSync } from "node:fs";
import { basename, dirname, isAbsolute, resolve } from "node:path";
import type { McpServerConfig, RuntimeConfigPatch } from "@ccbuddy/contracts";
import { resolveWorkspaceStateRoot } from "@ccbuddy/contracts/workspace-state";
import {
  createWorkspaceHookSourceInput,
  discoverWorkspaceHookConfigPaths,
  workspaceHooksConfigSchema,
  type WorkspaceHookSourceInput,
} from "@ccbuddy/shared/workspace-hook-discovery";
import { loadFileConfig, type LoadedConfig } from "./file-config.adapter.js";

const CURRENT_DIRECTORY = ".";

export interface ProjectConfigFile {
  baseDir: string;
  config: RuntimeConfigPatch;
  diagnostics: LoadedConfig["diagnostics"];
  hookCandidate?: WorkspaceHookSourceInput;
  loaded: boolean;
  path: string;
}

export interface ProjectConfigDiscovery {
  files: ProjectConfigFile[];
  diagnostics: LoadedConfig["diagnostics"];
  hookCandidates: WorkspaceHookSourceInput[];
  loaded: boolean;
  paths: string[];
  mcpServerNames: string[];
}

export function loadProjectConfigs(
  workingDirectory?: string,
  explicitProjectConfigPath?: string,
  workspaceIdentity?: string,
): ProjectConfigDiscovery {
  const resolvedWorkingDirectory = resolve(workingDirectory ?? process.cwd());
  const legacyFiles = discoverWorkspaceHookConfigPaths({
    workingDirectory: resolvedWorkingDirectory,
    ...(explicitProjectConfigPath ? { explicitProjectConfigPath } : {}),
  }).map((ref, discoveryOrder) =>
    loadProjectConfigFile(ref.path, {
      discoveryOrder,
      explicitProjectConfig: ref.explicitProjectConfig,
      includeHooks: false,
      workingDirectory: resolvedWorkingDirectory,
    }),
  );
  const ownedConfigPath = resolve(
    resolveWorkspaceStateRoot(resolvedWorkingDirectory, { workspaceIdentity }),
    "config.json",
  );
  const ownedConfig = existsSync(ownedConfigPath)
    ? loadProjectConfigFile(ownedConfigPath, {
        discoveryOrder: 0,
        explicitProjectConfig: true,
        projectBaseDir: resolvedWorkingDirectory,
        workingDirectory: resolvedWorkingDirectory,
      })
    : undefined;
  if (ownedConfig?.hookCandidate) {
    ownedConfig.hookCandidate = {
      ...ownedConfig.hookCandidate,
      baseDir: resolvedWorkingDirectory,
      editable: true,
    };
  }
  const files = ownedConfig ? [...legacyFiles, ownedConfig] : legacyFiles;
  return summarizeProjectConfigs(files);
}

export function loadProjectConfigFile(
  path: string,
  options: {
    discoveryOrder?: number;
    explicitProjectConfig?: boolean;
    includeHooks?: boolean;
    projectBaseDir?: string;
    workingDirectory?: string;
  } = {},
): ProjectConfigFile {
  // 项目配置可能来自旧 .ccbuddy：读取兼容配置时不能顺手回写插件 ID 迁移。
  const result = loadFileConfig(path, { persistMigration: false });
  const baseDir = options.projectBaseDir ?? getProjectConfigBaseDir(result.path);
  const diagnostics = [...result.diagnostics];
  const hooks = result.loaded && options.includeHooks !== false ? result.config.hooks : undefined;

  if (hooks) {
    diagnostics.push({
      code: "config_project_hooks_pending_trust",
      filePath: result.path,
      message: "Project hooks are pending workspace trust and remain blocked",
      path: "hooks",
      severity: "warning",
    });
  }

  return {
    baseDir,
    config: result.loaded ? normalizeProjectConfig(result.config, baseDir) : {},
    diagnostics,
    ...(hooks
      ? {
          hookCandidate: createWorkspaceHookSourceInput({
            path: result.path,
            workingDirectory: resolve(options.workingDirectory ?? baseDir),
            // hooks 字段已由 loadFileConfig 经 CCbuddyConfigFileSchema（shared 单源
            // schema）完成运行时校验；这里的 parse 仅做类型桥接——HooksRuntimeConfigPatch
            // 与 WorkspaceHooksConfig 是两个领域类型（执行 side vs 配置 side，字段语义有
            // 微差），不共享 TS 结构。禁止改成 as 断言绕过校验。
            hooks: workspaceHooksConfigSchema.parse(hooks),
            discoveryOrder: options.discoveryOrder ?? 0,
            explicitProjectConfig: options.explicitProjectConfig,
          }),
        }
      : {}),
    loaded: result.loaded,
    path: result.path,
  };
}

export function summarizeProjectConfigs(files: ProjectConfigFile[]): ProjectConfigDiscovery {
  const loadedFiles = files.filter((file) => file.loaded);
  const mcpServerNames = new Set<string>();

  for (const file of loadedFiles) {
    for (const name of Object.keys(file.config.mcp?.servers ?? {})) {
      mcpServerNames.add(name);
    }
  }

  return {
    diagnostics: files.flatMap((file) => file.diagnostics),
    files: loadedFiles,
    hookCandidates: loadedFiles.flatMap((file) => (file.hookCandidate ? [file.hookCandidate] : [])),
    loaded: loadedFiles.length > 0,
    paths: loadedFiles.map((file) => file.path),
    mcpServerNames: [...mcpServerNames],
  };
}

function getProjectConfigBaseDir(path: string): string {
  const configDirectory = dirname(path);
  return basename(configDirectory) === ".ccbuddy" ? dirname(configDirectory) : configDirectory;
}

function normalizeProjectConfig(config: RuntimeConfigPatch, baseDir: string): RuntimeConfigPatch {
  const normalized: RuntimeConfigPatch = config.hooks
    ? (() => {
        const { hooks: _hooks, ...safeConfig } = config;
        // Project Hook declarations are retained only in the immutable candidate side-channel.
        // The executable RuntimeConfigPatch remains hook-free until a later admission phase.
        return safeConfig;
      })()
    : { ...config };

  if (!normalized.mcp?.servers) return normalized;

  return {
    ...normalized,
    mcp: {
      ...normalized.mcp,
      servers: Object.fromEntries(
        Object.entries(normalized.mcp.servers).map(([name, server]) => [
          name,
          normalizeProjectMcpServer(server, baseDir),
        ]),
      ),
    },
  };
}

function normalizeProjectMcpServer(server: McpServerConfig, baseDir: string): McpServerConfig {
  if (server.type !== "stdio") return server;

  const cwd = server.cwd ?? CURRENT_DIRECTORY;
  return {
    ...server,
    cwd: isAbsolute(cwd) ? cwd : resolve(baseDir, cwd),
  };
}
