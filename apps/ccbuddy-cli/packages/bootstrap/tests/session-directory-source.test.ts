import { expect, it } from "vitest";
import type { SessionId, SessionInfo, SessionTaskType } from "@ccbuddy/contracts";
import { resolveSessionDirectorySource } from "../src/ccbuddy-protocol/session-directory-source.js";
import { ccbuddySessionRequestRuntimePreferencesParamsSchema } from "@ccbuddy/shared";

function entry(
  id: string,
  taskType: SessionTaskType = "interactive",
  parentID?: string,
): SessionInfo {
  return {
    id,
    taskType,
    parentID,
    path: "/project",
    directory: "/project",
    time: {},
  } as SessionInfo;
}

async function resolveSource(session: SessionInfo, entries: SessionInfo[] = [], identity?: string) {
  return resolveSessionDirectorySource({
    session,
    workspace: {
      workspaceKey: identity ?? "/project",
      workspacePath: "/project",
      workspaceIdentity: identity,
    },
    resolveOwner: true,
    getSession: async (id: SessionId) => entries.find((candidate) => candidate.id === id) ?? null,
    resolveLegacy: () => null,
  });
}

it("inherits directories from the durable root despite a historical child worktree cwd", async () => {
  const root = entry("root");
  const parent = entry("parent", "workflow_child", "root");
  const child = { ...entry("child", "subagent_child", "parent"), path: "/worktree" };
  expect(await resolveSource(child, [parent, root])).toBe(root);
});

it("does not follow a fork's parent into a different project", async () => {
  const fork = entry("fork", "fork", "original");
  expect(await resolveSource(fork, [entry("original")])).toBe(fork);
  expect(await resolveSource({ ...fork, path: "/other" }, [entry("original")])).toBeNull();
});

it("rejects missing parents, deleted nodes, cycles, and explicit identity conflicts", async () => {
  expect(await resolveSource(entry("child", "subagent_child", "missing"))).toBeNull();
  expect(
    await resolveSource(entry("child", "workflow_child", "root"), [
      { ...entry("root"), time: { deleted: 1 } } as SessionInfo,
    ]),
  ).toBeNull();
  const child = entry("child", "subagent_child", "child");
  expect(await resolveSource(child, [child])).toBeNull();
  expect(
    await resolveSource({ ...child, workspaceID: "foreign" } as SessionInfo, [entry("root")]),
  ).toBeNull();
  expect(await resolveSource(entry("root"), [], "remote:ssh:host:/project")).toBeNull();
});

it("keeps directory owner explicit through strict reverse preferences validation", () => {
  expect(
    ccbuddySessionRequestRuntimePreferencesParamsSchema.parse({
      sessionId: "child",
      directorySessionId: "root",
      scope: "runtime-materialization",
    }).directorySessionId,
  ).toBe("root");
  expect(
    ccbuddySessionRequestRuntimePreferencesParamsSchema.safeParse({
      sessionId: "child",
      directorySessionId: "",
      scope: "runtime-materialization",
    }).success,
  ).toBe(false);
});
