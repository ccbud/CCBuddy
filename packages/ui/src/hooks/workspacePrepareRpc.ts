/**
 * workspace prepare 的协议 RPC 收口。
 *
 * 拆出原因：useWorkspacePrepare.ts 只保留可单测的轻量判定入口；
 * 这里只读取 workspace presentation（mode/slash commands）；模型选择事实由目标 Host View 提供。
 */
import type { ICCbuddySessionService } from "@ccbuddy/services";
import { type CCbuddyProvider, type CCbuddyWorkspacePrepareResult } from "@ccbuddy/shared";
import { getChatErrorMessage } from "@/lib/chatPrepareError.js";
import { logger } from "@/logger.js";
import { ccbuddyWorkspacePresentationToConfigOptions } from "@/lib/ccbuddySessionProjection.js";

export async function prepareWorkspaceWithCCbuddySessionService(params: {
  workspacePath: string;
  workspaceIdentity?: string;
  provider: CCbuddyProvider;
  ccbuddySessionService: Pick<ICCbuddySessionService, "readWorkspacePresentation">;
}): Promise<CCbuddyWorkspacePrepareResult> {
  const startedAt = Date.now();
  logger.info("[ccbuddy-workspace-presentation] workspace prepare start", {
    workspacePath: params.workspacePath,
    workspaceIdentity: params.workspaceIdentity ?? null,
    provider: params.provider,
  });

  let presentation: Awaited<ReturnType<ICCbuddySessionService["readWorkspacePresentation"]>>;
  try {
    presentation = await params.ccbuddySessionService.readWorkspacePresentation({
      workspacePath: params.workspacePath,
      workspaceIdentity: params.workspaceIdentity,
    });
  } catch (error) {
    logger.warn("[ccbuddy-workspace-presentation] readWorkspacePresentation failed", {
      workspacePath: params.workspacePath,
      workspaceIdentity: params.workspaceIdentity ?? null,
      provider: params.provider,
      durationMs: Date.now() - startedAt,
      error: getChatErrorMessage(error),
    });
    throw error;
  }

  const readPresentationDurationMs = Date.now() - startedAt;
  const configOptions = ccbuddyWorkspacePresentationToConfigOptions(presentation.mode);
  const totalDurationMs = Date.now() - startedAt;
  logger.info("[ccbuddy-workspace-presentation] readWorkspacePresentation done", {
    workspacePath: params.workspacePath,
    workspaceIdentity: params.workspaceIdentity ?? null,
    provider: params.provider,
    readPresentationDurationMs,
    totalDurationMs,
    configOptionsCount: configOptions.length,
    modeCurrent: presentation.mode,
  });

  return {
    workspacePath: params.workspacePath,
    preparedSessionId: "",
    version: "CCbuddy Protocol/1",
    provider: params.provider,
    configOptions,
    slashCommands: presentation.slashCommands,
  };
}
