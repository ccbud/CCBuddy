import { describe, expect, it } from "vitest";
import { resolveDefaultEmbeddedSearchBackend } from "../src/app/embedded-search-backend.js";

describe("resolveDefaultEmbeddedSearchBackend", () => {
  it("uses bundled bfs, ugrep, and ripgrep paths by default", () => {
    expect(
      resolveDefaultEmbeddedSearchBackend({
        env: {
          CCBUDDY_BFS_BINARY: "/opt/ccbuddy/tools/bfs/bfs",
          CCBUDDY_RG_BINARY: "/opt/ccbuddy/tools/ripgrep/rg",
          CCBUDDY_UGREP_BINARY: "/opt/ccbuddy/tools/ugrep/ugrep",
        },
      }),
    ).toEqual({
      kind: "native-binaries",
      findCommand: "/opt/ccbuddy/tools/bfs/bfs",
      grepCommand: "/opt/ccbuddy/tools/ugrep/ugrep",
      rgCommand: "/opt/ccbuddy/tools/ripgrep/rg",
    });
  });

  it("falls back to bfs, ugrep, and rg command names when bundled paths are unavailable", () => {
    expect(resolveDefaultEmbeddedSearchBackend({ env: {} })).toEqual({
      kind: "native-binaries",
      findCommand: "bfs",
      grepCommand: "ugrep",
      rgCommand: "rg",
    });
  });

  it("preserves the explicit internal CLI compatibility override", () => {
    expect(
      resolveDefaultEmbeddedSearchBackend({
        env: { CCBUDDY_EMBEDDED_SEARCH_COMMAND: "/tmp/ccbuddy-test" },
      }),
    ).toEqual({
      kind: "internal-cli",
      command: "/tmp/ccbuddy-test",
      args: ["__internal-search"],
    });
  });
});
