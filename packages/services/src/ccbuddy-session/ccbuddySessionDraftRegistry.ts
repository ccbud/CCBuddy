import type { CCbuddySessionStateSnapshot } from "@ccbuddy/shared";
import type {
  CCbuddySessionWorkspaceTarget,
  CCbuddyTaskTarget,
} from "#src/ccbuddy-session/ccbuddySession.js";

function getWorkspaceKey(target: CCbuddySessionWorkspaceTarget): string {
  return target.workspaceIdentity?.trim() || target.workspacePath;
}

function getSessionScopedKey(target: CCbuddyTaskTarget): string {
  return `${getWorkspaceKey(target)}\0${target.sessionId}`;
}

export function createCCbuddyDeferredDraftRegistry() {
  const sessionKeys = new Set<string>();

  return {
    remember(params: CCbuddySessionWorkspaceTarget, snapshot: CCbuddySessionStateSnapshot): void {
      sessionKeys.add(
        getSessionScopedKey({
          workspacePath: snapshot.session.workspace.workspacePath,
          workspaceIdentity:
            snapshot.session.workspace.workspaceIdentity ?? params.workspaceIdentity,
          sessionId: snapshot.session.sessionId,
        }),
      );
    },

    has(target: CCbuddyTaskTarget): boolean {
      return sessionKeys.has(getSessionScopedKey(target));
    },

    forget(target: CCbuddyTaskTarget): void {
      sessionKeys.delete(getSessionScopedKey(target));
    },
  };
}
