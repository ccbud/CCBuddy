import { isAbsolute, resolve } from "node:path";
import type { SessionInfo, SessionId } from "@ccbuddy/contracts";
import type { CCbuddyWorkspaceRef } from "@ccbuddy/shared";
import { isTaskListSessionType } from "../ccbuddy-protocol-v4/task-list-session-membership.js";

export async function resolveSessionDirectorySource(input: {
  session: SessionInfo;
  workspace: CCbuddyWorkspaceRef;
  resolveOwner: boolean;
  getSession(id: SessionId): Promise<SessionInfo | null>;
  resolveLegacy(session: SessionInfo): { workspaceIdentity: string; workspacePath: string } | null;
}): Promise<SessionInfo | null> {
  const expectedKey = input.workspace.workspaceIdentity?.trim() || input.workspace.workspacePath;
  const visited = new Set<string>();
  let current: SessionInfo | null = input.session;
  while (current && current.time.deleted === undefined && !visited.has(current.id)) {
    visited.add(current.id);
    const legacy = input.resolveLegacy(current);
    const identity = current.workspaceID?.trim() || legacy?.workspaceIdentity;
    const path = legacy?.workspacePath ?? (current.path || current.directory);
    const auxiliary = !isTaskListSessionType(current.taskType);
    const samePath =
      path === input.workspace.workspacePath ||
      (isAbsolute(path) &&
        isAbsolute(input.workspace.workspacePath) &&
        resolve(path) === resolve(input.workspace.workspacePath));
    const sameIdentity =
      (identity || path) === expectedKey ||
      (!identity && !input.workspace.workspaceIdentity?.trim() && samePath);
    if (samePath && sameIdentity && (!input.resolveOwner || !auxiliary)) return current;
    // 历史 child 可在 worktree 执行，但显式身份冲突不能借父链越过隔离边界。
    if (!auxiliary || !current.parentID || (identity && (!sameIdentity || !samePath))) return null;
    current = await input.getSession(current.parentID);
  }
  return null;
}
