import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, vi } from "vitest";
import { createNodeFileSystemAdapter } from "../../adapters/src/fs/index.js";
import { createRootTraceContext, createSessionId, type SessionStorePort } from "@ccbuddy/contracts";
import { PermissionService } from "../src/permission/service.js";
import { createToolExecutor } from "../src/tool/executor.js";
import { readToolEntry } from "../src/tool/handlers/read.js";
import { createToolRegistry } from "../src/tool/registry.js";
import { setReadFileStateEntry } from "../src/tool/read-file-state.js";
import type { ReadFileStateMap } from "../src/tool/types.js";
import type { AgentRuntimeInternal } from "../src/runtime/internal.js";
import { restorePostCompactFiles } from "../src/runtime/helpers/compact-post-reminders.js";

it("applies original and absolute deny rules before restoring actual disk content without prompting", async () => {
  const root = await mkdtemp(join(tmpdir(), "ccbuddy-compact-deny-"));
  try {
    const files = [".env", "absolute.txt", "allowed.txt"];
    await Promise.all(files.map((name) => writeFile(join(root, name), `current ${name}`)));
    const readFileState: ReadFileStateMap = new Map();
    for (const name of files)
      setReadFileStateEntry(readFileState, {
        path: join(root, name),
        requestedPath: name,
        content: "outdated",
        isPartialView: false,
        readAt: new Date(),
        sourceTool: "Read",
        revisionId: "old",
      });
    const registry = createToolRegistry();
    registry.register(readToolEntry);
    const prompt = vi.fn();
    const getProjectPermission = vi.fn(async () => ({
      version: 1 as const,
      deny: [
        { toolName: "Read", ruleContent: ".env" },
        { toolName: "Read", ruleContent: join(root, "absolute.txt") },
      ],
      ask: [{ toolName: "Read", ruleContent: join(root, "allowed.txt") }],
    }));
    const store = {
      getSession: async () => ({ projectID: "project" }),
      getProjectPermission,
    } as unknown as SessionStorePort;
    const fileSystemPort = createNodeFileSystemAdapter();
    const read = vi.spyOn(fileSystemPort, "readTextFileRange");
    const sessionId = createSessionId("compact-deny");
    const traceContext = createRootTraceContext({ sessionId });
    const executor = createToolExecutor({
      registry,
      permissionService: new PermissionService(),
      permissionBroker: { requestPermission: prompt },
      sessionStore: store,
      sessionId,
      fileSystemPort,
      readFileState,
      workingDirectory: root,
      workspaceRoot: root,
      emitEvent: async () => {},
    });
    const runtime = {
      executor,
      fileSystemPort,
      readFileState,
      sessionId,
      workspaceRoot: root,
      workingDirectory: root,
    } as AgentRuntimeInternal;
    const restored = await restorePostCompactFiles(runtime, { preservedEntries: [], traceContext });
    expect(restored.readFileStateEntries.map((entry) => entry.path)).toEqual([
      join(root, "allowed.txt"),
    ]);
    expect(restored.readFileStateEntries[0]?.content).toBe("current allowed.txt");
    expect(JSON.stringify(restored.entries)).not.toContain("current .env");
    expect(read).toHaveBeenCalledOnce();
    expect(getProjectPermission).toHaveBeenCalledOnce();
    expect(prompt).not.toHaveBeenCalled();
    expect(readFileState.size).toBe(3);
    getProjectPermission.mockRejectedValueOnce(new Error("rules unavailable"));
    expect(
      (await restorePostCompactFiles(runtime, { preservedEntries: [], traceContext })).entries,
    ).toEqual([]);
    expect(read).toHaveBeenCalledOnce();
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
