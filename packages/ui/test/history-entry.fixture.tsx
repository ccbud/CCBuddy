import { useCallback, useState } from "react";
import { createRoot } from "react-dom/client";
import { CCbuddyIntlProvider } from "../src/i18n/IntlProvider.js";
import type { WorkspaceMainView } from "../src/app-shell/types.js";
import { useHistoryMainViewNavigation } from "../src/app-shell/useHistoryMainViewNavigation.js";
import { useWorkspaceMainViewSettingsExit } from "../src/app-shell/useWorkspaceMainViewSettingsExit.js";
import { HistorySidebarButton } from "../src/history/HistorySidebarButton.js";
import {
  HistoryReviewController,
  type HistoryReadBridge,
} from "../src/history/HistoryReviewController.js";
import { createDesktopPlatform } from "../../desktop/src/renderer/src/desktopPlatform.js";

declare global {
  interface Window {
    historyEntryHarness: {
      requestHistory(view: "list" | "timeline"): Promise<void>;
    };
  }
}

// 回归依据：必须经过生产平台装配；手造 history capability 会漏掉适配器丢失导致的入口消失。
const platform = createDesktopPlatform({ isLocalDevelopmentRuntime: true });
const history = platform.historyReview;

function HistoryEntryFixture() {
  const [view, setView] = useState<WorkspaceMainView>("chat");
  const [workspaceVisible, setWorkspaceVisible] = useState(true);
  const { preserveNextSettingsExit } = useWorkspaceMainViewSettingsExit({
    isWorkspaceVisible: workspaceVisible,
    workspaceMainView: view,
    onExitSettings: () => setView("chat"),
  });
  const runVisibleWorkspaceCommand = useCallback((command: () => void) => {
    setWorkspaceVisible(true);
    command();
  }, []);
  useHistoryMainViewNavigation({
    platform,
    preserveNextSettingsExit,
    runVisibleWorkspaceCommand,
    onWorkspaceMainViewChange: setView,
  });
  const openHistory = (next: "list" | "timeline") => {
    preserveNextSettingsExit();
    runVisibleWorkspaceCommand(() => setView(`history-${next}`));
  };
  const historyView =
    view === "history-list" ? "list" : view === "history-timeline" ? "timeline" : null;
  return (
    <div className="flex h-dvh bg-background text-foreground">
      <aside className="flex w-60 shrink-0 flex-col gap-3 border-r border-border p-3">
        {history ? (
          <>
            <HistorySidebarButton view="timeline" activeView={historyView} onOpen={openHistory} />
            <HistorySidebarButton view="list" activeView={historyView} onOpen={openHistory} />
          </>
        ) : null}
        <button data-testid="fixture-open-settings" onClick={() => setWorkspaceVisible(false)}>
          Settings
        </button>
      </aside>
      <section
        id="workspace"
        className="min-h-0 min-w-0 flex-1"
        data-view={view}
        data-visible={workspaceVisible}
        data-history-capable={Boolean(history)}
      >
        {!workspaceVisible ? (
          <h1>Settings fixture</h1>
        ) : historyView && history ? (
          <HistoryReviewController
            history={history as HistoryReadBridge}
            view={historyView}
            onViewChange={openHistory}
            locale="en-US"
          />
        ) : (
          <h1>Chat fixture</h1>
        )}
      </section>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(
  <CCbuddyIntlProvider initialLocale="en-US">
    <HistoryEntryFixture />
  </CCbuddyIntlProvider>,
);
