/**
 * CCbuddy Agent Slash Commands 便捷 hook
 *
 * 返回当前 workspace 下 Agent 广播的可用 slash commands 列表。
 */
import {
  useCCbuddySessionStore,
  selectWorkspaceCCbuddyState,
} from "../store/ccbuddySessionStore.js";

export function useSlashCommands(workspacePath: string, workspaceIdentity?: string) {
  return useCCbuddySessionStore(
    (state) => selectWorkspaceCCbuddyState(state, workspacePath, workspaceIdentity).slashCommands,
  );
}
