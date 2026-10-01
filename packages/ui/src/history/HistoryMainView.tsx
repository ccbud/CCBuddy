import { useMemo } from "react";
import { useCCbuddyIntl } from "../i18n/IntlProvider.js";
import { usePlatform } from "../hooks/usePlatform.js";
import { useServices } from "../hooks/useServices.js";
import { useSettings } from "../hooks/useSettingService.js";
import { useTabStoreApi } from "../store/TabStoreProvider.js";
import type { HistorySessionActions, HistorySessionSummary } from "./contract.js";
import { buildHistoryImportMessages } from "./history-import.js";
import { historyLabels } from "./labels.js";
import { HistoryReviewController, type HistoryReadBridge } from "./HistoryReviewController.js";
import type { HistoryRootsManagement } from "./HistoryRootsDialog.js";

export interface HistoryMainViewProps {
  view: "list" | "timeline";
  onViewChange: (view: "list" | "timeline") => void;
  /** Switches the workbench to the given task; provided by the shell that owns task navigation. */
  onOpenTask?: (workspacePath: string, taskId: string, workspaceIdentity?: string) => void;
}

// 设置里没有自定义目录时用同一个空数组，避免每次渲染都给对话框一份新引用。
const NO_CUSTOM_ROOTS: readonly HistoryRootsManagement["customRoots"][number][] = [];

function timestampOf(value: string): number | undefined {
  const time = Date.parse(value);
  return Number.isFinite(time) ? time : undefined;
}

export function HistoryMainView({ view, onViewChange, onOpenTask }: HistoryMainViewProps) {
  const { locale } = useCCbuddyIntl();
  const platform = usePlatform();
  const { ccbuddyTaskService } = useServices();
  const { settings, update } = useSettings();
  const tabStoreApi = useTabStoreApi();
  const bridge = platform.historyReview;
  const labels = historyLabels(locale);
  const customRoots = settings?.historyExtraRoots ?? NO_CUSTOM_ROOTS;

  const actions = useMemo<HistorySessionActions | undefined>(() => {
    if (!onOpenTask) return undefined;
    // 历史里的 cwd 优先；没有记录时落到当前打开的 workspace，仍然没有就明确报错而不是猜一个目录。
    const resolveWorkspace = (summary: HistorySessionSummary): string | null =>
      summary.cwd ?? tabStoreApi.getState().activeWorkspacePath ?? null;
    return {
      continueSession: async (detail) => {
        const summary = detail.summary;
        if (summary.source === "ccbuddy") {
          if (!summary.cwd) throw new Error(labels.continueNoWorkspace);
          onOpenTask(summary.cwd, summary.sessionId);
          return;
        }
        const workspacePath = resolveWorkspace(summary);
        if (!workspacePath) throw new Error(labels.continueNoWorkspace);
        const plan = buildHistoryImportMessages(detail, { locale });
        if (plan.messages.length === 0) throw new Error(labels.continueEmpty);
        const result = await ccbuddyTaskService.importHistorySession({
          workspacePath,
          producer: summary.source,
          producerSessionId: summary.sessionId,
          ...(summary.title ? { title: summary.title } : {}),
          ...(timestampOf(summary.createdAt) !== undefined
            ? { createdAt: timestampOf(summary.createdAt) }
            : {}),
          ...(timestampOf(summary.lastActivity) !== undefined
            ? { updatedAt: timestampOf(summary.lastActivity) }
            : {}),
          messages: plan.messages,
        });
        onOpenTask(result.workspacePath, result.taskId, result.workspaceIdentity);
      },
    };
  }, [ccbuddyTaskService, labels, locale, onOpenTask, tabStoreApi]);

  const rootsManagement = useMemo<HistoryRootsManagement>(
    () => ({
      customRoots,
      addRoot: async (root) => {
        if (customRoots.some((item) => item.path === root.path)) return;
        await update({ historyExtraRoots: [...customRoots, root] });
      },
      removeRoot: async (path) => {
        await update({ historyExtraRoots: customRoots.filter((item) => item.path !== path) });
      },
      chooseDirectory: () => platform.selectDirectory(),
    }),
    [customRoots, platform, update],
  );

  if (!bridge || bridge.protocolVersion !== 1) {
    return (
      <div
        className="flex h-full items-center justify-center bg-background text-foreground"
        role="alert"
      >
        {locale === "zh-CN" ? "此设备无法读取会话历史。" : "Session history is unavailable."}
      </div>
    );
  }
  return (
    <HistoryReviewController
      history={bridge as HistoryReadBridge}
      view={view}
      onViewChange={onViewChange}
      locale={locale}
      actions={actions}
      rootsManagement={rootsManagement}
    />
  );
}
