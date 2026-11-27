import {
  CCBUDDY_AGENT_PROVIDER,
  CCBUDDY_COMMAND_AGENT_SOURCES,
  type CCbuddyProvider,
  type CommandAgentSource,
} from "@ccbuddy/shared";

export const COMMAND_AGENT_SOURCES = [
  ...CCBUDDY_COMMAND_AGENT_SOURCES,
] as const satisfies readonly CommandAgentSource[];

export const COMMAND_AGENT_SOURCE_META: Record<
  CommandAgentSource,
  {
    labelId: string;
    provider: CCbuddyProvider;
    pathHint: string;
  }
> = {
  ccbuddyAgent: {
    labelId: "settings.commands.source.ccbuddyAgent",
    pathHint: "~/.ccbuddy/commands",
    provider: CCBUDDY_AGENT_PROVIDER,
  },
};
