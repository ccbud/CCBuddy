import type { CCbuddySessionStateSnapshot } from "@ccbuddy/shared";
import { createServiceLogger } from "#src/logger/serviceLogger.js";
import { repairImportedClaudeSessionSnapshot } from "#src/session/claude-native/importedClaudeHistoryRepair.js";
import type { ICCbuddyAgentService } from "#src/ccbuddy-agent/ccbuddyAgent.js";
import type {
  CCbuddySessionReadParams,
  CCbuddySessionResumeParams,
} from "#src/ccbuddy-session/ccbuddySession.js";

const logger = createServiceLogger("ccbuddy-session-service");

export async function repairEmptyImportedClaudeSessionSnapshot(params: {
  agentService: ICCbuddyAgentService;
  snapshot: CCbuddySessionStateSnapshot;
  target: CCbuddySessionResumeParams | CCbuddySessionReadParams;
}): Promise<CCbuddySessionStateSnapshot> {
  const repaired = await repairImportedClaudeSessionSnapshot({
    snapshot: params.snapshot,
    target: {
      workspacePath: params.target.workspacePath,
      workspaceIdentity: params.target.workspaceIdentity,
      taskId: params.target.sessionId,
      ...("mcpServers" in params.target && params.target.mcpServers
        ? { mcpServers: params.target.mcpServers }
        : {}),
    },
    createSession: (input) => params.agentService.createSession(input),
    onRepair: (history) => {
      logger.warn(
        undefined,
        `[ccbuddy-session-service] Claude 导入 session 历史异常，按 ${history.source} 回填 taskId=${params.target.sessionId}`,
      );
    },
  });
  return repaired ?? params.snapshot;
}
