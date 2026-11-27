// S08：skills/referenceCatalog 的 workspace/session authority 契约。
// session 直读 runtime 冻结目录；draft 重新扫描 workspace；未知 session fail closed。
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ccbuddySkillsReferenceCatalogResultSchema } from "@ccbuddy/shared";
import type { SkillLoadOutcome } from "@ccbuddy/contracts";
import { getSkillReferenceCatalog } from "../src/ccbuddy-protocol/skill-reference-catalog.js";
import type {
  CCbuddyProtocolAgentServerContext,
  CCbuddyProtocolSessionRecord,
} from "../src/ccbuddy-protocol/server-types.js";

const SESSION_CATALOG: SkillLoadOutcome = {
  skills: [
    {
      name: "frozen",
      description: "Frozen session skill",
      path: "/workspace/.ccbuddy/skills/frozen/SKILL.md",
      directory: "/workspace/.ccbuddy/skills/frozen",
      rootPath: "/workspace/.ccbuddy/skills",
      scope: "project",
      source: "ccbuddy",
      safeToAutoLoad: true,
      frontmatterKeys: ["name", "description"],
    },
  ],
  diagnostics: [],
  totalDiscovered: 1,
};

function contextWithSession(sessionId: string): CCbuddyProtocolAgentServerContext {
  const record = {
    app: {
      getSkillCatalog: async () => SESSION_CATALOG,
    },
  } as unknown as CCbuddyProtocolSessionRecord;
  return {
    deps: { env: {} },
    sessions: new Map([[sessionId, record]]),
  } as unknown as CCbuddyProtocolAgentServerContext;
}

describe("skills/referenceCatalog protocol", () => {
  it("serves the Session runtime frozen catalog", async () => {
    const result = await getSkillReferenceCatalog(contextWithSession("session-a"), {
      workspace: { workspacePath: "/workspace", workspaceKey: "/workspace" },
      sessionId: "session-a",
    });

    expect(result).toEqual({
      authority: "session",
      skills: [
        {
          id: "glm:workspace:/workspace/.ccbuddy/skills/frozen/SKILL.md",
          name: "frozen",
          description: "Frozen session skill",
          path: "/workspace/.ccbuddy/skills/frozen/SKILL.md",
          scope: "workspace",
          enabled: true,
        },
      ],
    });
    expect(() => ccbuddySkillsReferenceCatalogResultSchema.parse(result)).not.toThrow();
  });

  it("fails closed for an unknown Session instead of falling back to workspace discovery", async () => {
    await expect(
      getSkillReferenceCatalog(contextWithSession("session-a"), {
        workspace: { workspacePath: "/workspace", workspaceKey: "/workspace" },
        sessionId: "missing",
      }),
    ).rejects.toThrow(/Session is not active/);
  });

  it("rescans the current workspace catalog for a draft request", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccbuddy-skill-reference-workspace-"));
    const skillDirectory = join(root, ".ccbuddy", "skills", "manual-added");
    await mkdir(skillDirectory, { recursive: true });
    await writeFile(
      join(skillDirectory, "SKILL.md"),
      ["---", "name: manual-added", "description: Added outside the app.", "---"].join("\n"),
    );
    try {
      const result = await getSkillReferenceCatalog(
        {
          deps: {
            env: {
              HOME: root,
              CCBUDDY_STORAGE_DIR: join(root, "cli"),
            },
          },
          sessions: new Map(),
        } as unknown as CCbuddyProtocolAgentServerContext,
        { workspace: { workspacePath: root, workspaceKey: root } },
      );

      expect(result.authority).toBe("workspace");
      expect(result.skills).toContainEqual(
        expect.objectContaining({
          name: "manual-added",
          description: "Added outside the app.",
          scope: "workspace",
          enabled: true,
        }),
      );
      expect(() => ccbuddySkillsReferenceCatalogResultSchema.parse(result)).not.toThrow();
    } finally {
      await rm(root, { force: true, recursive: true });
    }
  });
});
