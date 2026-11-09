import { expect, it } from "vitest";
import { appToolSearchModeSchema } from "./app-runtime-preferences.js";
import { appSettingsSchema, appSettingsPatchSchema } from "./validationAppSettings.js";
import {
  ccbuddySessionRuntimePreferencesResultSchema,
  ccbuddyProtocolMcpServerSchema,
} from "./ccbuddy-protocol/index.js";
import { convertToCCbuddyAgentMcpServer } from "./mcp.js";

it("defaults legacy settings and Host preferences to off and validates available App modes", () => {
  expect(appSettingsSchema.parse({}).toolSearchMode).toBe("off");
  expect(
    ccbuddySessionRuntimePreferencesResultSchema.parse({ nativeSearchEnhancementsEnabled: true })
      .toolSearchMode,
  ).toBe("off");
  for (const mode of ["auto", "local", "off"]) {
    expect(appSettingsPatchSchema.parse({ toolSearchMode: mode }).toolSearchMode).toBe(mode);
  }
  expect(appToolSearchModeSchema.safeParse("native").success).toBe(false);
  expect(appSettingsPatchSchema.safeParse({ toolSearchMode: "invalid" }).success).toBe(false);
});

it.each([true, false, undefined])(
  "retains MCP alwaysLoad through DTO and wire schemas (%s)",
  (alwaysLoad) => {
    for (const config of [
      { command: "node", args: ["server.js"], alwaysLoad },
      { type: "http", url: "https://mcp.example.test", alwaysLoad },
    ]) {
      const dto = convertToCCbuddyAgentMcpServer("example", config);
      expect(dto?.alwaysLoad).toBe(alwaysLoad);
      expect(ccbuddyProtocolMcpServerSchema.parse(dto).alwaysLoad).toBe(alwaysLoad);
    }
  },
);
