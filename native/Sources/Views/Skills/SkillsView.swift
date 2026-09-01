import AppKit
import SwiftUI

struct SkillsDetailSelection: Identifiable {
    let id: String
}

struct SkillsTagsContext: Identifiable {
    let id = UUID()
    let skills: [ManagedSkill]
}

struct SkillsSyncContext: Identifiable {
    let id = UUID()
    let skills: [ManagedSkill]
}

struct SkillsSyncPlan {
    let skill: ManagedSkill
    let syncKeys: [String]
    let removeKeys: [String]
    let mode: SkillSyncMode
}

struct SkillsOverwriteContext: Identifiable {
    let id = UUID()
    let plans: [SkillsSyncPlan]
    let conflicts: [SkillSyncConflict]
}

struct SkillsDeferredBulkSync {
    let skills: [ManagedSkill]
    let keys: [String]
    let mode: SkillSyncMode
}

struct SkillsDeleteContext: Identifiable {
    let id = UUID()
    let skills: [ManagedSkill]
}

enum SkillsDeferredDetailAction {
    case editTags(ManagedSkill)
    case delete(ManagedSkill)
}

@MainActor
struct SkillsView: View {
    @StateObject var store: SkillsStore
    @Environment(\.appLanguage) var appLanguage

    @State var page = SkillsPage.library
    @State var query = ""
    @State var statusFilter = SkillsStatusFilter.all
    @State var tagFilter = ""
    @State var sortOrder = SkillsSortOrder.updated
    @State var displayMode = SkillsDisplayMode.list
    @State var bulkMode = false
    @State var selectedIDs = Set<String>()
    @State var loaded = false
    @State var detailSelection: SkillsDetailSelection?
    @State var tagsContext: SkillsTagsContext?
    @State var syncContext: SkillsSyncContext?
    @State var overwriteContext: SkillsOverwriteContext?
    @State var deferredBulkSync: SkillsDeferredBulkSync?
    @State var deleteContext: SkillsDeleteContext?
    @State var batchErrorMessage: String?
    @State var deferredDetailAction: SkillsDeferredDetailAction?

    init() {
        _store = StateObject(wrappedValue: SkillsStore())
    }

    init(store: SkillsStore) {
        _store = StateObject(wrappedValue: store)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            pageNavigation
            if let message = batchErrorMessage ?? store.errorMessage {
                SkillsErrorBanner(message: message) {
                    batchErrorMessage = nil
                    store.clearError()
                    Task { await store.refresh() }
                }
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.md)
            }
            if !loaded {
                SkillsLoadingState(title: "正在加载…")
            } else {
                pageContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .task {
            guard !loaded else { return }
            await store.refresh()
            loaded = true
        }
        .sheet(item: $detailSelection, onDismiss: clearDetail) { selection in
            SkillsDetailView(
                detail: store.selectedDetail?.skill.id == selection.id ? store.selectedDetail : nil,
                tools: store.snapshot.tools,
                busy: store.isBusy,
                close: { detailSelection = nil },
                readFile: { try await store.readFile(id: $0, path: $1) },
                editTags: deferTagEditingFromDetail,
                update: update,
                applySyncSettings: applyDetailSyncSettings,
                unsync: unsync,
                delete: deferDeletionFromDetail
            )
            .modifier(SkillsOverwriteConfirmationModifier(
                context: $overwriteContext,
                active: true,
                confirm: confirmOverwrite,
                cancel: cancelOverwrite
            ))
        }
        .sheet(item: $tagsContext) { context in
            SkillsTagEditorSheet(
                title: context.skills.count == 1 ? "编辑标签" : "批量编辑标签",
                initialTags: commonTags(context.skills),
                suggestions: store.snapshot.skills.allSkillTags,
                apply: { setTags($0, for: context.skills) }
            )
        }
        .sheet(item: $syncContext, onDismiss: performDeferredBulkSync) { context in
            SkillsBulkSyncSheet(skills: context.skills, tools: store.snapshot.tools) {
                queueBulkSync(context.skills, keys: $0, mode: $1)
            }
        }
        .confirmationDialog(
            appLanguage.localized("删除 Skill？"),
            isPresented: Binding(
                get: { deleteContext != nil },
                set: { if !$0 { deleteContext = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(appLanguage.localized("删除"), role: .destructive) { confirmDelete() }
            Button(appLanguage.localized("取消"), role: .cancel) { deleteContext = nil }
        } message: {
            Text(deleteMessage)
        }
        .modifier(SkillsOverwriteConfirmationModifier(
            context: $overwriteContext,
            active: detailSelection == nil && tagsContext == nil && syncContext == nil,
            confirm: confirmOverwrite,
            cancel: cancelOverwrite
        ))
        .overlay(alignment: .topTrailing) {
            if store.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .padding(Space.md)
                    .accessibilityLabel(appLanguage.localized("正在处理…"))
            }
        }
        .accessibilityContainerIdentifier("view.skills", label: "Skills")
    }

    var header: some View {
        DestinationHeader(
            title: "Skills",
            subtitle: store.snapshot.root.path
        ) {
            Button {
                Task { NSWorkspace.shared.open(await store.rootURL()) }
            } label: {
                Label(appLanguage.localized("打开目录"), systemImage: "folder")
            }
            .buttonStyle(.ccSecondary)
            .accessibilityIdentifier("skills.open-root")
        }
        .background(Theme.list)
        .hairline(.bottom)
    }

    var pageNavigation: some View {
        HStack {
            SkillsPagePicker(selection: $page)
            Spacer(minLength: Space.md)
            if page == .library {
                Text(appLanguage.localized("\(store.snapshot.skills.count) 个 Skills"))
                    .font(.ccCaption())
                    .foregroundStyle(Theme.mutedForeground)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.sm)
        .background(Theme.list)
        .hairline(.bottom)
    }

    @ViewBuilder var pageContent: some View {
        switch page {
        case .library: library
        case .add: add
        case .tags: tags
        case .tools: tools
        case .updates: updates
        }
    }
}

private struct SkillsOverwriteConfirmationModifier: ViewModifier {
    @Binding var context: SkillsOverwriteContext?
    let active: Bool
    let confirm: () -> Void
    let cancel: () -> Void

    @Environment(\.appLanguage) private var appLanguage

    func body(content: Content) -> some View {
        content.confirmationDialog(
            appLanguage.localized("覆盖现有 Skill？"),
            isPresented: Binding(
                get: { active && context != nil },
                set: { if !$0 { cancel() } }
            ),
            titleVisibility: .visible
        ) {
            Button(appLanguage.localized("覆盖并同步"), role: .destructive, action: confirm)
            Button(appLanguage.localized("取消"), role: .cancel, action: cancel)
        } message: {
            Text(overwriteMessage)
        }
    }

    private var overwriteMessage: String {
        guard let context else { return "" }
        let paths = uniquePaths(context.conflicts).joined(separator: "\n")
        if context.conflicts.count == 1 {
            return appLanguage.localized(
                "目标位置已存在同名 Skill，覆盖后原内容将被替换：\n\(paths)"
            )
        }
        return appLanguage.localized(
            "发现 \(context.conflicts.count) 个未受管理的同名 Skills，覆盖后原内容将被替换：\n\(paths)"
        )
    }

    private func uniquePaths(_ conflicts: [SkillSyncConflict]) -> [String] {
        var seen = Set<String>()
        return conflicts.compactMap { conflict in
            let path = conflict.path.standardizedFileURL.path
            return seen.insert(path).inserted ? path : nil
        }
    }
}
