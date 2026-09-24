import { z } from "zod";
import type { CommandAgentSource } from "./command-types.js";
import type { CCbuddyProvider } from "./ccbuddy-task-types-core.js";

export const CCBUDDY_AGENT_PROVIDER = "glm" satisfies CCbuddyProvider;
export const CCBUDDY_AGENT_PROVIDER_LABEL = "CCbuddy Agent";
export const CCBUDDY_COMMAND_AGENT_SOURCE = "ccbuddyAgent" satisfies CommandAgentSource;

export const ccbuddyAgentProviderSchema = z.literal(CCBUDDY_AGENT_PROVIDER);

export const CCBUDDY_COMMAND_AGENT_SOURCES = [
  CCBUDDY_COMMAND_AGENT_SOURCE,
] as const satisfies readonly CommandAgentSource[];

export function normalizeAgentProviderToCCbuddyAgent(
  _provider?: CCbuddyProvider | null,
): CCbuddyProvider {
  return CCBUDDY_AGENT_PROVIDER;
}

export function isCCbuddyAgentProvider(
  provider: CCbuddyProvider | null | undefined,
): provider is typeof CCBUDDY_AGENT_PROVIDER {
  return provider === CCBUDDY_AGENT_PROVIDER;
}
