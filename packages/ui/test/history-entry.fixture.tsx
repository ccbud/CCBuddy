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
import type { HistorySessionDetail, HistorySnapshot } from "../src/history/contract.js";

declare global {
  interface Window {
    historyEntryHarness: {
      onHistoryRequested(listener: (view: "list" | "timeline") => void): () => void;
      requestHistory(view: "list" | "timeline"): Promise<void>;
    };
  }
}

const createdAt = new Date(Date.now() - 15 * 60_000).toISOString();
const summary = {
  id: "fixture-session",
  source: "claude" as const,
  sessionId: "fixture-session",
  title: "History entry fixture",
  project: "Fixture workspace",
  cwd: "/fixture/workspace",
  createdAt,
  lastActivity: new Date().toISOString(),
  messageCount: 1,
  model: null,
  parentSessionId: null,
  isSubagent: false,
  fingerprint: "fixture",
};
const snapshot: HistorySnapshot = {
  protocolVersion: 1,
  version: 1,
  sessions: [summary],
  diagnostics: [],
  roots: [],
  complete: true,
};
const detail: HistorySessionDetail = {
  summary,
  diagnostics: [],
  messages: [
    {
      id: "fixture-message",
      sequence: 0,
      role: "user",
      timestamp: createdAt,
      model: null,
      usage: null,
      blocks: [{ type: "text", text: "Read-only history content from the renderer fixture." }],
    },
  ],
};
const history: HistoryReadBridge = {
  protocolVersion: 1,
  list: async () => snapshot,
  load: async () => detail,
  refresh: async () => ({ type: "terminal", generation: 1, status: "success", snapshot }),
  onRefreshEvent: () => () => {},
};
const platform = { onOpenHistoryViewRequested: window.historyEntryHarness.onHistoryRequested };

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
        <HistorySidebarButton view="timeline" activeView={historyView} onOpen={openHistory} />
        <HistorySidebarButton view="list" activeView={historyView} onOpen={openHistory} />
        <button data-testid="fixture-open-settings" onClick={() => setWorkspaceVisible(false)}>
          Settings
        </button>
      </aside>
      <section
        id="workspace"
        className="min-h-0 min-w-0 flex-1"
        data-view={view}
        data-visible={workspaceVisible}
      >
        {!workspaceVisible ? (
          <h1>Settings fixture</h1>
        ) : historyView ? (
          <HistoryReviewController
            history={history}
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
