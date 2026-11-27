import { describe, expect, it } from "vitest";
import {
  genUiReferenceSchema,
  genUiWidgetStateSchema,
  buildGenUiStateKey,
  genUiTweakSchema,
  GEN_UI_STYLE_CONTEXT_KEY,
  genUiStyleVariablesSchema,
} from "./contract.js";

describe("Gen UI boundaries", () => {
  it("isolates CCbuddy presentation variables from standard MCP styles", () => {
    expect(GEN_UI_STYLE_CONTEXT_KEY).toBe("ccbuddy/genUiStyles");
    expect(genUiStyleVariablesSchema.parse({ "--gen-ui-primary": "#000000" })).toEqual({
      "--gen-ui-primary": "#000000",
    });
    for (const variables of [
      { "--color-text-info": "red" },
      { "--gen-ui-primary": 12 },
      { "--gen-ui-primary; color": "red" },
    ]) {
      expect(genUiStyleVariablesSchema.safeParse(variables).success).toBe(false);
    }
  });
  it("accepts executor absolute paths but rejects URLs and document traversal", () => {
    for (const path of ["/project/example.html", "C:\\project\\example.html"]) {
      expect(genUiReferenceSchema.parse({ path }).path).toBe(path);
    }
    for (const path of [
      "https://example.test/x.html",
      "../x.html",
      "/project/../x.html",
      "/project/a.txt",
    ]) {
      expect(genUiReferenceSchema.safeParse({ path }).success).toBe(false);
    }
  });
  it("validates JSON and the complete state size before accepting it", () => {
    expect(genUiWidgetStateSchema.parse({ privateContent: { tab: 2 } })).toEqual({
      modelContent: null,
      privateContent: { tab: 2 },
    });
    for (const state of [
      { privateContent: "x".repeat(16384) },
      { modelContent: () => 1 },
      { privateContent: Infinity },
      { imageIds: ["image"] },
    ]) {
      expect(genUiWidgetStateSchema.safeParse(state).success).toBe(false);
    }
    const circular: Record<string, unknown> = {};
    circular.self = circular;
    expect(genUiWidgetStateSchema.safeParse({ privateContent: circular }).success).toBe(false);
  });
  it("isolates workspace identities and sessions even with the same executor path", () => {
    const a = {
      workspacePath: "/project",
      sessionId: "session",
      path: "/project/example.html",
    };
    expect(buildGenUiStateKey(a)).not.toBe(
      buildGenUiStateKey({ ...a, workspaceIdentity: "remote-example" }),
    );
    expect(buildGenUiStateKey(a)).not.toBe(buildGenUiStateKey({ ...a, sessionId: "other" }));
  });
  it("rejects invalid tweak ranges, duplicate IDs and excess controls", () => {
    const control = {
      id: "size",
      label: "Size",
      type: "slider",
      min: 0,
      max: 10,
      value: 5,
    };
    expect(genUiTweakSchema.safeParse({ title: "Design", controls: [control] }).success).toBe(true);
    for (const controls of [
      [{ ...control, value: 11 }],
      [control, control],
      Array.from({ length: 13 }, (_, i) => ({ ...control, id: `size${i}` })),
    ])
      expect(genUiTweakSchema.safeParse({ title: "Design", controls }).success).toBe(false);
  });
});
