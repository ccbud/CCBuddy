export const CLI_COMMAND_NAME = "ccbuddy";
export const CLI_PROCESS_NAME = "ccbuddy-cli";
const MCP_PROCESS_NAME = "ccbuddy-mcp";
const PLUGIN_NAME_PATTERN = /^[a-z0-9][a-z0-9._-]{0,127}$/;

interface ProcessTitleTarget {
  title: string;
}

export const setCliProcessTitle = (target: ProcessTitleTarget = process): void => {
  target.title = CLI_PROCESS_NAME;
};

export const setPluginHostProcessTitle = (
  pluginId: string | undefined,
  target: ProcessTitleTarget = process,
): void => {
  const pluginName = pluginId?.split("@", 1)[0]?.trim().toLowerCase();
  target.title =
    pluginName && PLUGIN_NAME_PATTERN.test(pluginName)
      ? `${MCP_PROCESS_NAME}-${pluginName}`
      : MCP_PROCESS_NAME;
};
