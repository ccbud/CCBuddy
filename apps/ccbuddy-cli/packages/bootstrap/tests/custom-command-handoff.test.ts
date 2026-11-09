import { describe, expect, it } from "vitest";
import {
  expandCustomCommandPrompt,
  handOffCustomCommandShellBlocks,
  type CustomCommandContent,
} from "@ccbuddy/contracts";
import { expandCliCustomCommandPrompt } from "../../cli/src/custom-command-expand.js";

const metadata = { name: "inspect", scope: "project", source: "agents" };

describe("custom command shell handoff", () => {
  it("keeps shell execution inside the visible Bash permission boundary", () => {
    const body = handOffCustomCommandShellBlocks(
      "Before !`git status` after\n```!\ngit diff\n```",
      { metadata },
    );
    expect(body).toContain("Run it with the Bash tool");
    expect(body).toContain("not from CCbuddy");
    expect(body).toContain("```bash\ngit status\n```\n after");
    expect(body).toContain("```bash\ngit diff\n```");
  });

  it("does not reinterpret argument text as shell blocks on either app or CLI", () => {
    const command = { content: "$ARGUMENTS", metadata } as CustomCommandContent;
    const input = { args: "!`do-not-run`", command };
    expect(expandCustomCommandPrompt(input).prompt).toContain("!`do-not-run`");
    expect(expandCustomCommandPrompt(input).prompt).not.toContain("Run it with");
    expect(expandCliCustomCommandPrompt(input).prompt).toEqual(
      expandCustomCommandPrompt(input).prompt,
    );
  });

  it("leaves punctuation and empty blocks harmless", () => {
    expect(handOffCustomCommandShellBlocks("Warning!`text` !` `", { metadata })).toBe(
      "Warning!`text` ",
    );
  });

  it("rejects unresolved plugin variables and shell modifiers", () => {
    for (const variable of [
      "$CCBUDDY_PLUGIN_ROOT",
      "${CLAUDE_PLUGIN_ROOT:-fallback}",
      "$CLAUDE_SKILL_DIR",
    ]) {
      const result = handOffCustomCommandShellBlocks(`!\`cat ${variable}/file\``, { metadata });
      expect(result).toContain("was not run");
      expect(result).not.toContain("```bash");
    }
  });

  it("resolves explicit plugin variables with Windows-compatible path text", () => {
    const plugin = {
      id: "plugin-id",
      name: "Plugin",
      rootPath: "C:\\Users\\Test\\plugin",
      dataPath: "\\\\server\\share\\data",
    };
    const result = handOffCustomCommandShellBlocks(
      '!`cat "$CLAUDE_PLUGIN_ROOT/file" "$CCBUDDY_PLUGIN_DATA/file"`',
      { metadata: { ...metadata, plugin } },
    );
    expect(result).toContain('"C:/Users/Test/plugin/file" "//server/share/data/file"');
    expect(result).not.toContain("was not run");
  });
});
