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

    enum SortField: String, CaseIterable, Equatable {
        case updated
        case created
        case messages
    }

    @Published private(set) var selection: Selection = .all
    @Published var agentsExpanded = true
    @Published var projectsExpanded = true
    @Published var sortField: SortField = .updated
    @Published var sortAscending = false
    @Published private(set) var searchFocusRevision = 0

    func showAll() {
        selection = .all
    }

    func showStarred() {
        selection = .starred
    }

    func requestSearchFocus() {
        searchFocusRevision &+= 1
    }

    func select(agent: HistorySource) {
        selection = selection == .agent(agent) ? .all : .agent(agent)
    }

    func select(project: String) {
        selection = selection == .project(project) ? .all : .project(project)
    }

    /// A producer can disappear while the catalog is refreshing (CLI uninstall, directory move,
    /// or an emptied project). Wake treats those sidebar filters as projections of the live
    /// catalog, so never leave the workbench pinned to a projection which no longer exists.
    func reconcileSelection(
        projects: [HistoryProject],
        historyActive: String
    ) {
        guard historyActive == "all" else {
            if selection != .all { selection = .all }
            return
        }

        switch selection {
        case .agent(let source):
            if !projects.lazy.flatMap(\.sessions).contains(where: { $0.source == source }) {
                selection = .all
            }
        case .project(let cwd):
            if !projects.contains(where: { $0.cwd == cwd }) {
                selection = .all
            }
        case .all, .starred:
            break
        }
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
            return language.localized("已收藏")
        case .agent(let source):
            return ConversationPresentation.sourceName(rawValue: source.rawValue)
        case .project(let cwd):
            return projects.first(where: { $0.cwd == cwd })?.name
                ?? URL(fileURLWithPath: cwd).lastPathComponent
        }
    }

    func sorted(_ sessions: [HistorySessionMetadata]) -> [HistorySessionMetadata] {
        sessions.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }

            let ordered: Bool?
            switch sortField {
            case .updated:
                ordered = comparison(lhs.lastActivity, rhs.lastActivity)
            case .created:
                ordered = comparison(lhs.createdAt, rhs.createdAt)
            case .messages:
                ordered = comparison(lhs.messageCount, rhs.messageCount)
            }
            if let ordered { return ordered }
            if lhs.lastActivity != rhs.lastActivity {
                return lhs.lastActivity > rhs.lastActivity
            }
            return lhs.id < rhs.id
        }
    }

    private func comparison<T: Comparable>(_ lhs: T, _ rhs: T) -> Bool? {
        guard lhs != rhs else { return nil }
        return sortAscending ? lhs < rhs : lhs > rhs
    }
}

struct ConversationsView: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject var workbench: ConversationWorkbenchState
    @Environment(\.appLanguage) private var appLanguage
    var fontSize: Int?
    var historyDirectories: [String] = []
    var selectHistoryScope: (String) -> Void = { _ in }

    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: 0) {
            ConversationListPane(
                store: store,
                workbench: workbench
            )
            .frame(width: 336)

            ConversationTimelinePane(store: store, fontSize: fontSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.ccConversationBackground.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let message = store.actionMessage {
                ConversationNotice(
                    message: appLanguage.localized(message),
                    isError: store.actionIsError,
                    dismiss: store.clearActionMessage
                )
                .padding(.bottom, 18)
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.ccBrand, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(Color.ccBrandSoft.opacity(0.72))
                    .overlay {
                        Label("松开以导入 JSONL / ZIP", systemImage: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.ccBrandStrong)
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
        .onAppear {
            store.requestHistoryScope = selectHistoryScope
            workbench.reconcileSelection(
                projects: store.projects,
                historyActive: store.historyActive
            )
            store.activate()
        }
        .onChange(of: store.projects) { projects in
            workbench.reconcileSelection(
                projects: projects,
                historyActive: store.historyActive
            )
        }
        .onChange(of: store.historyActive) { active in
            workbench.reconcileSelection(projects: store.projects, historyActive: active)
        }
        .onDisappear {
            store.requestHistoryScope = nil
            store.deactivate()
        }
        .focusedSceneValue(
            \.conversationCommandActions,
            ConversationCommandActions(
                focusSearch: workbench.requestSearchFocus,
                refresh: store.retryIndexing
            )
        )
        .conversationAccessibilityContainerIdentifier("conversations.view", label: "会话")
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
                ConversationWorkbenchIcon(isError ? .circleX : .check, size: 14)
                Text(appLanguage.localized(message)).lineLimit(2)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isError ? Color.white : Color.ccElevated)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(isError ? Color.ccRed : Color.ccForeground)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
        }
        .buttonStyle(ConversationPressableButtonStyle())
        .accessibilityIdentifier("conversation.notice")
    }
}
