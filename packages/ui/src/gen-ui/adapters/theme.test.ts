import { afterEach, describe, expect, it, vi } from "vitest";
import { McpUiHostStylesSchema } from "@modelcontextprotocol/ext-apps";
import { GEN_UI_STYLE_CONTEXT_KEY } from "@ccbuddy/shared/gen-ui";
import { readPluginUiStyleVariables } from "@/plugin-ui/hostPrimitives.js";
import { readGenUiStyleContext } from "./theme.js";

afterEach(() => vi.unstubAllGlobals());

function installTokens(tokens: Record<string, string>) {
  vi.stubGlobal("document", { documentElement: {} });
  vi.stubGlobal("getComputedStyle", () => ({
    getPropertyValue: (name: string) => tokens[name] ?? "",
  }));
}

describe("Gen UI style projection", () => {
  it.each([14, 18])("projects the complete typography scale at %ipx", (size) => {
    installTokens({ "--ui-font-size": `${size}px` });
    const context = readGenUiStyleContext();
    expect(context.styles.variables).toMatchObject({
      "--font-text-md-size": `${size}px`,
      "--font-text-sm-size": `${size - 2}px`,
      "--font-heading-xs-size": `${size}px`,
      "--font-heading-sm-size": `${size + 2}px`,
      "--font-heading-md-size": `${size + 4}px`,
      "--border-radius-sm": "4px",
      "--border-radius-md": "6px",
      "--border-radius-lg": "8px",
      "--border-radius-xl": "12px",
    });
    expect(McpUiHostStylesSchema.safeParse(context.styles).success).toBe(true);
  });

  it("keeps control colors outside standard MCP variables and preserves third-party mapping", () => {
    installTokens({
      "--color-primary": " #000000 ",
      "--color-brand": "#38bdf8",
      "--color-input-border-focused": "#0088ff",
      "--color-selected": "#eeeeee",
    });
    const standard = readPluginUiStyleVariables();
    const context = readGenUiStyleContext();
    expect(context[GEN_UI_STYLE_CONTEXT_KEY]).toEqual({
      "--gen-ui-primary": "#000000",
      "--gen-ui-input-border-focused": "#0088ff",
      "--gen-ui-selected": "#eeeeee",
    });
    expect(context.styles.variables).toMatchObject({ "--color-text-info": "#38bdf8" });
    expect(Object.keys(context.styles.variables).some((name) => name.startsWith("--gen-ui-"))).toBe(
      false,
    );
    expect(readPluginUiStyleVariables()).toEqual(standard);
    expect(McpUiHostStylesSchema.safeParse(context.styles).success).toBe(true);
  });

  it("uses fallback typography and does not cache colors across theme updates", () => {
    const tokens: Record<string, string> = { "--color-primary": "#000000" };
    installTokens(tokens);
    expect(readGenUiStyleContext().styles.variables["--font-text-md-size"]).toBe("14px");
    tokens["--color-primary"] = "#ffffff";
    tokens["--ui-font-size"] = "18px";
    const next = readGenUiStyleContext();
    expect(next[GEN_UI_STYLE_CONTEXT_KEY]["--gen-ui-primary"]).toBe("#ffffff");
    expect(next.styles.variables["--font-text-md-size"]).toBe("18px");
    delete tokens["--color-primary"];
    expect(readGenUiStyleContext()[GEN_UI_STYLE_CONTEXT_KEY]).toEqual({});
  });
});
