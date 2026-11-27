export const pluginDiscoveryModule = {
  id: "plugin-discovery",
  requires: ["ccbuddy-cli", "shared"],
  provides: ["plugin-discovery"],
  publicEntrypoints: ["index.ts", "contract.ts"],
} as const;
