import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { resolveDefaultSkillRoots } from "../src/skills/roots.js";
import { resolveDefaultCustomCommandRoots } from "../src/commands/roots.js";
import {
  describeMarketplacePlugin,
  getMarketplaceManifestPath,
} from "../src/plugins/marketplace.js";

describe("project discovery and cached plugin reads", () => {
  it("namespaces and deduplicates additional roots without reviving product-local state", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccbuddy-discovery-"));
    try {
      const cwd = join(root, "primary");
      const extra = join(root, "secondary");
      await mkdir(cwd);
      await mkdir(extra);
      const options = { homeDirectory: root, additionalDirectories: [cwd, extra, extra] };
      const skills = await resolveDefaultSkillRoots(cwd, options);
      const commands = await resolveDefaultCustomCommandRoots(cwd, options);
      expect(skills.filter((entry) => entry.namespace)).toMatchObject([
        { namespace: "secondary", path: join(extra, ".agents", "skills") },
      ]);
      expect(commands.filter((entry) => entry.namespace)).toMatchObject([
        { namespace: "secondary", path: join(extra, ".agents", "commands") },
      ]);
      expect(
        [...skills, ...commands].some((entry) => entry.path.startsWith(join(extra, ".ccbuddy"))),
      ).toBe(false);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("does not wait for the write lock when the manifest is already cached", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccbuddy-plugin-read-"));
    try {
      const path = getMarketplaceManifestPath(root, "test-market");
      await mkdir(dirname(path), { recursive: true });
      await writeFile(path, JSON.stringify({ name: "test-market", plugins: [] }));
      const lock = vi.fn(async () => {
        throw new Error("must not enter write lock");
      });
      const result = await describeMarketplacePlugin({
        storageRoot: root,
        marketplace: "test-market",
        name: "missing",
        withWriteLock: lock,
      });
      expect(lock).not.toHaveBeenCalled();
      expect(result.diagnostics).toEqual(
        expect.arrayContaining([expect.objectContaining({ code: "plugin_not_found" })]),
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("keeps missing-manifest writes inside the injected lock", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccbuddy-plugin-write-"));
    try {
      const lock = vi.fn(async () => {
        throw new Error("blocked write");
      });
      const result = await describeMarketplacePlugin({
        storageRoot: root,
        marketplace: "test-market",
        name: "missing",
        withWriteLock: lock,
      });
      expect(lock).toHaveBeenCalledOnce();
      expect(result.diagnostics[0]?.message).toContain("blocked write");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
