import Foundation
import SwiftUI

@MainActor
final class ConversationWorkbenchState: ObservableObject {
    enum Selection: Equatable {
        case all
        case starred
        case agent(HistorySource)
        case project(String)
    }

    @Published private(set) var selection: Selection = .all
    @Published private(set) var agentsExpanded = true
    @Published private(set) var projectsExpanded = true

    /// Collapsing a group hides the row that is doing the filtering. Leaving the filter on would
    /// leave the stream narrowed by a condition with nothing on screen to explain or undo it, so
    /// putting a group away also puts away the scope it held.
    func setAgentsExpanded(_ expanded: Bool) {
        agentsExpanded = expanded
        if !expanded, case .agent = selection { selection = .all }
    }

    func setProjectsExpanded(_ expanded: Bool) {
        projectsExpanded = expanded
        if !expanded, case .project = selection { selection = .all }
    }

    func showAll() {
        selection = .all
    }

    func showStarred() {
        selection = .starred
    }

    func select(agent: HistorySource) {
        selection = selection == .agent(agent) ? .all : .agent(agent)
    }

    func select(project: String) {
        selection = selection == .project(project) ? .all : .project(project)
    }

    func filteredProjects(
        _ projects: [HistoryProject],
        historyActive: String
    ) -> [HistoryProject] {
        guard historyActive == "all" else { return projects }

        switch selection {
        case .all:
            return projects
        case .starred:
            return projects.compactMap { project in
                let sessions = project.sessions.filter(\.starred)
                guard !sessions.isEmpty else { return nil }
                return HistoryProject(
                    cwd: project.cwd,
                    name: project.name,
                    sessions: sessions,
                    lastActivity: sessions.map(\.lastActivity).max() ?? project.lastActivity
                )
            }
        case .agent(let source):
            return projects.compactMap { project in
                let sessions = project.sessions.filter { $0.source == source }
                guard !sessions.isEmpty else { return nil }
                return HistoryProject(
                    cwd: project.cwd,
                    name: project.name,
                    sessions: sessions,
                    lastActivity: sessions.map(\.lastActivity).max() ?? project.lastActivity
                )
            }
        case .project(let cwd):
            return projects.filter { $0.cwd == cwd }
        }
    }

    func contextTitle(
        projects: [HistoryProject],
        historyActive: String,
        language: AppLanguage
    ) -> String {
        switch historyActive {
        case "all":
            break
        case "__imported__":
            return language.localized("已导入")
        case "__trash__":
            return language.localized("回收站")
        default:
            return URL(fileURLWithPath: historyActive).lastPathComponent
        }

        switch selection {
        case .all:
            return language.localized("全部会话")
        case .starred:
            return language.localized("收藏")
        case .agent(let source):
            return ConversationPresentation.sourceName(rawValue: source.rawValue)
        case .project(let cwd):
            let name = projects.first(where: { $0.cwd == cwd })?.name
                ?? URL(fileURLWithPath: cwd).lastPathComponent
            return ConversationPresentation.projectName(name, language: language)
        }
    }
}

struct ConversationsView: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject var workbench: ConversationWorkbenchState
    @ObservedObject var columns: ColumnLayout
    @Environment(\.appLanguage) private var appLanguage
    var fontSize: Int?
    var selectHistoryScope: (String) -> Void = { _ in }

    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: 0) {
            if columns.streamVisible {
                ConversationListPane(
                    store: store,
                    workbench: workbench,
                    columns: columns
                )
                .frame(width: columns.streamWidth)

                ColumnDivider(
                    column: ColumnLayout.stream,
                    width: $columns.streamWidth,
                    onCommit: { columns.resize(ColumnLayout.stream, to: $0) },
                    identifier: "layout.divider.stream"
                )
            }

            ConversationTimelinePane(store: store, columns: columns, fontSize: fontSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The stream's own control goes away with it, so the way back lives on the reading
                // column and appears exactly when the column it restores is missing.
                .overlay(alignment: .topLeading) {
                    if !columns.streamVisible {
                        ColumnToggle(
                            symbol: "sidebar.left",
                            help: appLanguage.localized("显示会话列表"),
                            identifier: "layout.toggle.stream"
                        ) {
                            columns.toggleStream()
                        }
                        .padding(
                            .leading,
                            columns.railVisible ? Space.md : Metrics.trafficLightClearance
                        )
                        .padding(.top, 5)
                    }
                }

            // The overview is a column again, not a popover: these are facts you read next to the
            // transcript, and a sheet over the transcript to show them was the wrong shape. It
            // takes space only while a session is open, so an empty library keeps its full width.
            if columns.inspectorVisible, store.selectedMetadata != nil {
                ColumnDivider(
                    column: ColumnLayout.inspector,
                    side: .trailing,
                    width: $columns.inspectorWidth,
                    onCommit: { columns.resize(ColumnLayout.inspector, to: $0) },
                    identifier: "layout.divider.inspector"
                )

                ConversationOverviewPane(
                    store: store,
                    collapsed: false,
                    toggleCollapsed: { columns.toggleInspector() }
                )
                .frame(width: columns.inspectorWidth)
                .frame(maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            if let message = store.actionMessage {
                ConversationNotice(
                    message: message,
                    isError: store.actionIsError,
                    dismiss: store.clearActionMessage
                )
                .padding(.bottom, 18)
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(Theme.accentSoft.opacity(0.72))
                    .overlay {
                        Label("松开以导入 JSONL / ZIP", systemImage: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accentText)
                    }
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { files, _ in
            let accepted = files.filter { ["jsonl", "zip"].contains($0.pathExtension.lowercased()) }
            guard !accepted.isEmpty else {
                store.reportActionError("仅支持导入 JSONL 或 ZIP")
                return false
            }
            Task { await store.importFiles(accepted) }
            return true
        } isTargeted: {
            isDropTarget = $0
        }
        .onAppear { store.requestHistoryScope = selectHistoryScope }
        .onDisappear { store.requestHistoryScope = nil }
        .accessibilityContainerIdentifier("conversations.view", label: "会话")
    }

}

private struct ConversationNotice: View {
    @Environment(\.appLanguage) private var appLanguage

    let message: String
    let isError: Bool
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                Text(appLanguage.localized(message)).lineLimit(2)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isError ? Color.white : Theme.surface)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(isError ? Theme.danger : Theme.foreground)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
        }
        .buttonStyle(ConversationPressableButtonStyle())
        .accessibilityIdentifier("conversation.notice")
    }
}
