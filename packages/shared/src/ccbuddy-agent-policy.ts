import { z } from "zod";
import type { CommandAgentSource } from "./command-types.js";
import type { CCbuddyProvider } from "./ccbuddy-task-types-core.js";

export const CCBUDDY_AGENT_PROVIDER = "glm" satisfies CCbuddyProvider;
export const CCBUDDY_AGENT_PROVIDER_LABEL = "CCbuddy Agent";
export const CCBUDDY_COMMAND_AGENT_SOURCE = "ccbuddyAgent" satisfies CommandAgentSource;

/**
 * 解析持久化/relay 数据时的 provider 归一 schema：
 * 已移除的第三方 provider 历史值仅作为归一化输入保留，统一收敛为 glm；
 * 其它非法值保持拒绝，与收窄前的校验边界一致。
 */
export const legacyCCbuddyProviderSchema = z
  .enum(["claude", "opencode", "gemini", "codex", "glm"])
  .transform((): typeof CCBUDDY_AGENT_PROVIDER => CCBUDDY_AGENT_PROVIDER);

export const CCBUDDY_ENABLED_AGENT_PROVIDERS = [
  CCBUDDY_AGENT_PROVIDER,
] as const satisfies readonly CCbuddyProvider[];

export const CCBUDDY_COMMAND_AGENT_SOURCES = [
  CCBUDDY_COMMAND_AGENT_SOURCE,
] as const satisfies readonly CommandAgentSource[];

export function normalizeAgentProviderToCCbuddyAgent(
  _provider?: CCbuddyProvider | null,
): CCbuddyProvider {
  return CCBUDDY_AGENT_PROVIDER;
}

export function normalizeAgentProvidersToCCbuddyAgent(
  _providers?: ReadonlyArray<CCbuddyProvider> | null,
): CCbuddyProvider[] {
  return [...CCBUDDY_ENABLED_AGENT_PROVIDERS];
}

export function normalizeCommandAgentSourceToCCbuddyAgent(
  _agentSource?: CommandAgentSource | null,
): CommandAgentSource {
  return CCBUDDY_COMMAND_AGENT_SOURCE;
}

export function isCCbuddyAgentProvider(
  provider: CCbuddyProvider | null | undefined,
): provider is typeof CCBUDDY_AGENT_PROVIDER {
  return provider === CCBUDDY_AGENT_PROVIDER;
}
