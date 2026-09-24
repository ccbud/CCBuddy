import { existsSync } from "node:fs";
import { access, readFile } from "node:fs/promises";
import { basename, dirname, resolve } from "node:path";
import { z } from "zod";

export const WORKSPACE_HOOK_DIGEST_SCHEMA_VERSION = 1 as const;
export const DEFAULT_WORKSPACE_HOOK_TIMEOUT_MS = 60_000;
export const DEFAULT_WORKSPACE_HOOK_MAX_OUTPUT_BYTES = 32_768;
export const WORKSPACE_HOOK_EVENT_NAMES = [
  "SessionStart",
  "UserPromptSubmit",
  "PreToolUse",
  "PermissionRequest",
  "PostToolUse",
  "PostToolUseFailure",
  "Stop",
] as const;

export type WorkspaceHookEventName = (typeof WORKSPACE_HOOK_EVENT_NAMES)[number];
export type WorkspaceHookConfigFileKind = "ccbuddy.json" | ".ccbuddy/config.json" | "explicit";

const positiveNumberSchema = z.number().finite().positive();

export const workspaceHookProcessConfigSchema = z
  .object({
    type: z.literal("process"),
    command: z.string().min(1),
    enabled: z.boolean().optional(),
    args: z.array(z.string()).optional(),
    timeoutMs: positiveNumberSchema.optional(),
    statusMessage: z.string().min(1).optional(),
  })
  .passthrough();

export const workspaceHookCommandConfigSchema = z
  .object({
    type: z.literal("command"),
    command: z.string().min(1),
    enabled: z.boolean().optional(),
    async: z.boolean().optional(),
    shell: z.union([z.literal(true), z.string().min(1)]).optional(),
    timeout: positiveNumberSchema.optional(),
    timeoutMs: positiveNumberSchema.optional(),
    statusMessage: z.string().min(1).optional(),
  })
  .passthrough();

export const workspaceHookMatcherConfigSchema = z
  .object({
    matcher: z.string().min(1).optional(),
    hooks: z
      .array(
        z.discriminatedUnion("type", [
          workspaceHookProcessConfigSchema,
          workspaceHookCommandConfigSchema,
        ]),
      )
      .min(1),
  })
  .strict();

export const workspaceHooksConfigSchema = z
  .object({
    enabled: z.boolean().optional(),
    timeoutMs: positiveNumberSchema.optional(),
    maxOutputBytes: positiveNumberSchema.optional(),
    events: z
      .object({
        SessionStart: z.array(workspaceHookMatcherConfigSchema).optional(),
        UserPromptSubmit: z.array(workspaceHookMatcherConfigSchema).optional(),
        PreToolUse: z.array(workspaceHookMatcherConfigSchema).optional(),
        PermissionRequest: z.array(workspaceHookMatcherConfigSchema).optional(),
        PostToolUse: z.array(workspaceHookMatcherConfigSchema).optional(),
        PostToolUseFailure: z.array(workspaceHookMatcherConfigSchema).optional(),
        Stop: z.array(workspaceHookMatcherConfigSchema).optional(),
      })
      .strict()
      .optional(),
  })
  .strict();

export type WorkspaceHookDefinition =
  | z.infer<typeof workspaceHookCommandConfigSchema>
  | z.infer<typeof workspaceHookProcessConfigSchema>;
export type WorkspaceHooksConfig = z.infer<typeof workspaceHooksConfigSchema>;

export interface WorkspaceHookSourceInput {
  canonicalPath: string;
  baseDir: string;
  discoveryOrder: number;
  configFileKind: WorkspaceHookConfigFileKind;
  explicitProjectConfig: boolean;
  editable: boolean;
  hooks: WorkspaceHooksConfig;
}

export interface WorkspaceHookRuntimeRoot {
  enabled: boolean;
  timeoutMs: number;
  maxOutputBytes: number;
}

export interface WorkspaceHookConfigPathRef {
  path: string;
  explicitProjectConfig: boolean;
}

export interface WorkspaceHookSourceReadError {
  path: string;
  error: unknown;
}

export function resolveWorkspaceHookTimeoutMs(
  hook: Pick<WorkspaceHookDefinition, "type" | "timeoutMs"> & { timeout?: number },
  defaultTimeoutMs: number,
): number {
  const timeoutMs =
    hook.timeoutMs ??
    (hook.type === "command" && hook.timeout !== undefined
      ? hook.timeout * 1000
      : defaultTimeoutMs);
  return Math.max(1, Math.round(timeoutMs));
}

export function resolveWorkspaceHookMaxOutputBytes(maxOutputBytes: number): number {
  return Math.max(1, Math.round(maxOutputBytes));
}

/** Mirrors config-merger's hooks root semantics without materializing any callback. */
export function resolveWorkspaceHookRuntimeRoot(
  roots: readonly (
    | Partial<Pick<WorkspaceHooksConfig, "enabled" | "timeoutMs" | "maxOutputBytes">>
    | undefined
  )[],
): WorkspaceHookRuntimeRoot {
  let enabled = false;
  let timeoutMs = DEFAULT_WORKSPACE_HOOK_TIMEOUT_MS;
  let maxOutputBytes = DEFAULT_WORKSPACE_HOOK_MAX_OUTPUT_BYTES;

  for (const root of roots) {
    if (!root) continue;
    if (root.enabled === true) enabled = true;
    if (root.timeoutMs !== undefined) timeoutMs = root.timeoutMs;
    if (root.maxOutputBytes !== undefined) maxOutputBytes = root.maxOutputBytes;
  }

  return {
    enabled,
    timeoutMs: Math.max(1, Math.round(timeoutMs)),
    maxOutputBytes: resolveWorkspaceHookMaxOutputBytes(maxOutputBytes),
  };
}

export function resolveWorkspaceHookConfiguredGates(input: {
  sourceEnabled?: boolean;
  declarationEnabled?: boolean;
  runtimeHooksEnabled: boolean;
}) {
  const sourceRootEnabled = input.sourceEnabled !== false;
  const declarationEnabled = input.declarationEnabled !== false;
  return {
    sourceRootEnabled,
    declarationEnabled,
    runtimeHooksEnabled: input.runtimeHooksEnabled,
    configuredEnabled: sourceRootEnabled && declarationEnabled && input.runtimeHooksEnabled,
  };
}

/**
 * 对已发现的 config refs 按规范化路径去重，保留首次出现的条目。
 *
 * 当 explicit projectConfigPath 恰好指向 auto-discovery 已发现的文件时，
 * 同一文件会以不同 explicitProjectConfig 标记出现两次，进入 snapshot 后产生重复
 * sourceFile 与重复 declaration，导致 bundleDigest 分叉。
 *
 * 去重策略：保留首次出现者（auto-discovered 条目在前、explicit 在后），丢弃后续重复。
 * 不得改变剩余条目的相对顺序——discoveryOrder 和 explicitProjectConfig 均为 digest 输入，
 * 任何重排都会使既有 trust 记录失效（用户被重新提示全部 Hook）。对于无 explicit path
 * 的 workspace，auto-discovery 本身不会产生重复，此函数为 no-op，bundleDigest 不变。
 */
function deduplicateWorkspaceHookConfigRefs(
  refs: readonly WorkspaceHookConfigPathRef[],
): WorkspaceHookConfigPathRef[] {
  const seen = new Set<string>();
  const result: WorkspaceHookConfigPathRef[] = [];
  for (const ref of refs) {
    const resolved = resolve(ref.path);
    if (seen.has(resolved)) continue;
    seen.add(resolved);
    result.push(ref);
  }
  return result;
}

export function discoverWorkspaceHookConfigPaths(input: {
  workingDirectory: string;
  explicitProjectConfigPath?: string;
}): WorkspaceHookConfigPathRef[] {
  // 项目文件只在用户明确传入路径时读取；默认项目状态由调用方定位在 CCbuddy 数据根。
  const refs: WorkspaceHookConfigPathRef[] = [];

  if (input.explicitProjectConfigPath) {
    const explicitPath = resolve(input.explicitProjectConfigPath);
    if (existsSync(explicitPath)) refs.push({ path: explicitPath, explicitProjectConfig: true });
  }
  return deduplicateWorkspaceHookConfigRefs(refs);
}

export function createWorkspaceHookSourceInput(input: {
  path: string;
  workingDirectory: string;
  hooks: WorkspaceHooksConfig;
  discoveryOrder: number;
  explicitProjectConfig?: boolean;
}): WorkspaceHookSourceInput {
  const canonicalPath = resolve(input.path);
  const explicitProjectConfig = input.explicitProjectConfig === true;
  const configDirectory = dirname(canonicalPath);
  return {
    canonicalPath,
    baseDir: basename(configDirectory) === ".ccbuddy" ? dirname(configDirectory) : configDirectory,
    discoveryOrder: input.discoveryOrder,
    configFileKind: explicitProjectConfig
      ? "explicit"
      : basename(canonicalPath) === "ccbuddy.json"
        ? "ccbuddy.json"
        : ".ccbuddy/config.json",
    explicitProjectConfig,
    editable: false,
    hooks: input.hooks,
  };
}

export async function readWorkspaceHookProjectSources(input: {
  workingDirectory: string;
  explicitProjectConfigPath?: string;
  ownedWorkspaceConfigPath?: string;
}): Promise<{ sources: WorkspaceHookSourceInput[]; errors: WorkspaceHookSourceReadError[] }> {
  const refs = input.ownedWorkspaceConfigPath
    ? (await pathExists(input.ownedWorkspaceConfigPath))
      ? [{ path: resolve(input.ownedWorkspaceConfigPath), explicitProjectConfig: true }]
      : []
    : await discoverWorkspaceHookConfigPathsAsync(input);
  const sources: WorkspaceHookSourceInput[] = [];
  const errors: WorkspaceHookSourceReadError[] = [];

  for (const [discoveryOrder, ref] of refs.entries()) {
    try {
      const value = JSON.parse(await readFile(ref.path, "utf8")) as unknown;
      if (!isRecord(value) || value.hooks === undefined) continue;
      const source = createWorkspaceHookSourceInput({
        path: ref.path,
        workingDirectory: input.workingDirectory,
        hooks: workspaceHooksConfigSchema.parse(value.hooks),
        discoveryOrder,
        explicitProjectConfig: ref.explicitProjectConfig,
      });
      sources.push(
        input.ownedWorkspaceConfigPath
          ? { ...source, baseDir: resolve(input.workingDirectory), editable: true }
          : source,
      );
    } catch (error) {
      errors.push({ path: ref.path, error });
    }
  }
  return { sources, errors };
}

async function discoverWorkspaceHookConfigPathsAsync(input: {
  workingDirectory: string;
  explicitProjectConfigPath?: string;
}): Promise<WorkspaceHookConfigPathRef[]> {
  const refs: WorkspaceHookConfigPathRef[] = [];
  if (input.explicitProjectConfigPath) {
    const explicitPath = resolve(input.explicitProjectConfigPath);
    if (await pathExists(explicitPath)) {
      refs.push({ path: explicitPath, explicitProjectConfig: true });
    }
  }
  return deduplicateWorkspaceHookConfigRefs(refs);
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
