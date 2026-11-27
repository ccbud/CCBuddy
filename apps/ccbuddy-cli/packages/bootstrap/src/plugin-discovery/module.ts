export const agentPluginDiscoveryModule = {
  id: "agent-plugin-discovery",
  requires: ["shared", "ccbuddy-cli", "plugin-install-interaction"],
  provides: ["agent-plugin-discovery"],
  publicEntrypoints: ["contract.ts", "subscription.ts"],
} as const;
