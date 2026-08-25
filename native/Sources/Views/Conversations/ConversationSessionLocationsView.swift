import AppKit
import SwiftUI

/// Wake-style manager for every producer root used by the conversation index.
///
/// The list sheet deliberately owns no persistence. `ConversationStore` publishes one snapshot
/// after the index has settled and performs each mutation as a single operation, keeping the
/// panel's counts and the scanner's active roster on the same generation.
struct ConversationSessionLocationsView: View {
    @ObservedObject var store: ConversationStore
    @Environment(\.appLanguage) private var appLanguage
    @Environment(\.dismiss) private var dismiss

    @State private var editorTarget: ConversationSessionLocationEditorTarget?

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(Color.ccBorder)
                .frame(height: 1)

            locations

            Rectangle()
                .fill(Color.ccBorder)
                .frame(height: 1)
                .padding(.horizontal, 10)

            footer
        }
        .frame(width: 620, height: 500)
        .background(Color.ccElevated)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.locations.sheet")
        .task {
            await store.refreshSessionLocations()
        }
        .sheet(item: $editorTarget) { target in
            ConversationSessionLocationEditor(
                target: target,
                isStoreBusy: store.isUpdatingSessionLocations,
                save: { source, path in
                    let error: String?
                    switch target.kind {
                    case .add:
                        error = await store.addSessionLocation(source: source, path: path)
                    case .edit(let row):
                        error = await store.replaceSessionLocation(
                            originalRow: row,
                            source: source,
                            path: path
                        )
                    }
                    if error != nil { store.clearActionMessage() }
                    return error
                },
                remove: { row in
                    let error = await store.removeSessionLocation(row)
                    if error != nil { store.clearActionMessage() }
                    return error
                }
            )
        }
        .interactiveDismissDisabled(store.isUpdatingSessionLocations)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(appLanguage.localized("会话位置"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.ccForeground)

            Spacer(minLength: 0)

            if store.isUpdatingSessionLocations {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(appLanguage.localized("正在更新会话位置"))
                    .accessibilityIdentifier("conversation.locations.progress")
            }

            Button { dismiss() } label: {
                ConversationWorkbenchIcon(.x, size: 12)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ccMuted)
            .help(appLanguage.localized("关闭"))
            .accessibilityLabel(appLanguage.localized("关闭"))
            .accessibilityIdentifier("conversation.locations.close")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .frame(height: 48)
    }

    @ViewBuilder private var locations: some View {
        if store.sessionLocationRows.isEmpty {
            VStack(spacing: 10) {
                if store.isUpdatingSessionLocations {
                    ProgressView().controlSize(.small)
                } else {
                    ConversationWorkbenchIcon(.hardDrive, size: 24)
                        .foregroundStyle(Color.ccCaption)
                }
                Text(appLanguage.localized(
                    store.isUpdatingSessionLocations ? "正在读取会话位置…" : "没有可用的会话位置"
                ))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ccMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(
                        Array(orderedLocationRows.enumerated()),
                        id: \.element.id
                    ) { index, row in
                        ConversationSessionLocationListRow(row: row, index: index) {
                            editorTarget = .edit(row)
                        }
                        .disabled(store.isUpdatingSessionLocations)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("conversation.locations.list")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                editorTarget = .add
            } label: {
                Label {
                    Text(appLanguage.localized("添加位置"))
                } icon: {
                    ConversationWorkbenchIcon(.plus, size: 13)
                }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ConversationSessionLocationGhostButtonStyle())
            .accessibilityIdentifier("conversation.locations.add")

            Spacer(minLength: 0)

            if !store.sessionLocationOverrides.isEmpty {
                Button {
                    Task { await store.restoreDefaultSessionLocations() }
                } label: {
                    Label {
                        Text(appLanguage.localized("恢复默认位置"))
                    } icon: {
                        ConversationWorkbenchIcon(.refreshCW, size: 13)
                    }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ConversationSessionLocationGhostButtonStyle())
                .accessibilityIdentifier("conversation.locations.restore")
            }
        }
        .foregroundStyle(Color.ccMuted)
        .padding(.horizontal, 14)
        .frame(height: 42)
        .disabled(store.isUpdatingSessionLocations)
    }

    /// Wake pins location groups to the AgentId declaration order instead of discovery order.
    /// Keep the repository's within-agent order intact so a default remains first and custom
    /// instances retain their persisted order; Qoder is CC Buddy's one additional producer.
    private var orderedLocationRows: [ConversationSessionLocationRow] {
        let ranks = Dictionary(uniqueKeysWithValues:
            ConversationPresentation.sourceOrder.enumerated().map {
                ($0.element, $0.offset)
            })
        return store.sessionLocationRows.enumerated().sorted { left, right in
            let leftRank = ranks[left.element.source] ?? Int.max
            let rightRank = ranks[right.element.source] ?? Int.max
            return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
        }.map(\.element)
    }
}

private struct ConversationSessionLocationListRow: View {
    @Environment(\.appLanguage) private var appLanguage
    @State private var hovering = false

    let row: ConversationSessionLocationRow
    let index: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ConversationSourceBrandIcon(source: row.source, size: 14)
                    .frame(width: 16)

                Text(ConversationPresentation.sourceName(rawValue: row.source.rawValue))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ccForeground)
                    .lineLimit(1)
                    .frame(width: 118, alignment: .leading)

                Text(ConversationSessionLocationPath.display(row.dataRoot))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ccMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(row.dataRoot.path)

                Text(row.exists ? "\(row.sessionCount)" : appLanguage.localized("未找到"))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(row.exists ? Color.ccMuted : Color.ccOrange)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 18)
                    .background(
                        row.exists
                            ? Color.ccForeground.opacity(0.055)
                            : Color.ccOrange.opacity(0.13)
                    )
                    .clipShape(Capsule())
                    .frame(width: 88, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(hovering ? Color.ccConversationListHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(row.exists
            ? appLanguage.localized("{n} 个会话").replacingOccurrences(
                of: "{n}",
                with: "\(row.sessionCount)"
            )
            : appLanguage.localized("未找到"))
        .accessibilityIdentifier(
            "conversation.locations.row.\(row.source.rawValue).\(index)"
        )
    }

    private var accessibilityLabel: String {
        [
            ConversationPresentation.sourceName(rawValue: row.source.rawValue),
            ConversationSessionLocationPath.display(row.dataRoot),
        ].joined(separator: ", ")
    }
}

private struct ConversationSessionLocationEditorTarget: Identifiable {
    enum Kind {
        case add
        case edit(ConversationSessionLocationRow)
    }

    let id = UUID()
    let kind: Kind

    static var add: Self { Self(kind: .add) }
    static func edit(_ row: ConversationSessionLocationRow) -> Self {
        Self(kind: .edit(row))
    }

    var initialSource: HistorySource {
        switch kind {
        case .add: .claude
        case .edit(let row): row.source
        }
    }

    var initialPath: String {
        switch kind {
        case .add:
            ""
        case .edit(let row):
            ConversationSessionLocationPath.display(editURL(for: row))
        }
    }

    var editedRow: ConversationSessionLocationRow? {
        if case .edit(let row) = kind { return row }
        return nil
    }

    private func editURL(for row: ConversationSessionLocationRow) -> URL {
        ConversationSessionLocationValidator.editingRoot(for: row)
    }
}

private struct ConversationSessionLocationEditor: View {
    @Environment(\.appLanguage) private var appLanguage
    @Environment(\.dismiss) private var dismiss

    let target: ConversationSessionLocationEditorTarget
    let isStoreBusy: Bool
    let save: (HistorySource, String) async -> String?
    let remove: (ConversationSessionLocationRow) async -> String?

    @State private var source: HistorySource
    @State private var path: String
    @State private var validationMessage: String?
    @State private var isWorking = false
    @FocusState private var pathFocused: Bool

    init(
        target: ConversationSessionLocationEditorTarget,
        isStoreBusy: Bool,
        save: @escaping (HistorySource, String) async -> String?,
        remove: @escaping (ConversationSessionLocationRow) async -> String?
    ) {
        self.target = target
        self.isStoreBusy = isStoreBusy
        self.save = save
        self.remove = remove
        _source = State(initialValue: target.initialSource)
        _path = State(initialValue: target.initialPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader

            Rectangle().fill(Color.ccBorder).frame(height: 1)

            VStack(spacing: 16) {
                formRow(appLanguage.localized("代理")) {
                    Picker("", selection: $source) {
                        ForEach(
                            ConversationPresentation.sourceOrder,
                            id: \.rawValue
                        ) { item in
                            HStack(spacing: 8) {
                                ConversationSourceBrandIcon(source: item, size: 14)
                                Text(ConversationPresentation.sourceName(rawValue: item.rawValue))
                            }
                            .tag(item)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190, alignment: .leading)
                    .accessibilityLabel(appLanguage.localized("代理"))
                    .accessibilityIdentifier("conversation.locations.editor.agent")

                    Spacer(minLength: 0)
                }

                formRow(appLanguage.localized("文件夹")) {
                    TextField(
                        appLanguage.localized("绝对文件夹路径或 ~/…"),
                        text: $path
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($pathFocused)
                    .onSubmit(commit)
                    .accessibilityIdentifier("conversation.locations.editor.path")

                    Button(action: chooseDirectory) {
                        ConversationWorkbenchIcon(.folder, size: 13)
                            .frame(width: 26, height: 22)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(appLanguage.localized("选择文件夹"))
                    .accessibilityLabel(appLanguage.localized("选择文件夹"))
                    .accessibilityIdentifier("conversation.locations.editor.choose")
                }

                if let validationMessage {
                    Label(appLanguage.localized(validationMessage), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ccOrange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 92)
                        .accessibilityIdentifier("conversation.locations.editor.validation")
                }

                if let row = target.editedRow {
                    HStack(spacing: 8) {
                        Button {
                            removeLocation(row)
                        } label: {
                            Label {
                                Text(appLanguage.localized("移除"))
                            } icon: {
                                ConversationWorkbenchIcon(.trash, size: 13)
                            }
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 8)
                                .frame(height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(ConversationSessionLocationDestructiveButtonStyle())
                        .accessibilityIdentifier("conversation.locations.editor.remove")

                        Spacer(minLength: 0)

                        if let revealURL, ConversationSessionLocationPath.exists(revealURL) {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                            } label: {
                                Label {
                                    Text(appLanguage.localized("在 Finder 中显示"))
                                } icon: {
                                    ConversationWorkbenchIcon(.folder, size: 13)
                                }
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 8)
                                    .frame(height: 30)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(ConversationSessionLocationGhostButtonStyle())
                            .accessibilityIdentifier("conversation.locations.editor.reveal")
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Spacer(minLength: 0)

            Rectangle().fill(Color.ccBorder).frame(height: 1)

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button(appLanguage.localized("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("conversation.locations.editor.cancel")

                Button(action: commit) {
                    if isWorking || isStoreBusy {
                        ProgressView()
                            .controlSize(.small)
                            .frame(minWidth: 38)
                    } else {
                        Text(appLanguage.localized(isAdd ? "添加" : "保存"))
                            .frame(minWidth: 38)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || isWorking || isStoreBusy)
                .accessibilityIdentifier("conversation.locations.editor.save")
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
        }
        .frame(width: 500, height: target.editedRow == nil ? 260 : 310)
        .background(Color.ccElevated)
        .interactiveDismissDisabled(isWorking || isStoreBusy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.locations.editor")
        .onAppear {
            if isAdd { pathFocused = true }
        }
        .onChange(of: path) { _ in
            validationMessage = nil
        }
        .onChange(of: source) { _ in
            validationMessage = nil
        }
    }

    private var editorHeader: some View {
        HStack {
            Text(appLanguage.localized(isAdd ? "添加位置" : "编辑位置"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.ccForeground)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(height: 54)
    }

    private func formRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.ccMuted)
                .frame(width: 72, alignment: .leading)
            content()
        }
    }

    private var isAdd: Bool {
        if case .add = target.kind { return true }
        return false
    }

    private var canSave: Bool {
        guard ConversationSessionLocationPath.isAbsolute(path) else { return false }
        if isAdd { return true }
        return source != target.initialSource
            || ConversationSessionLocationPath.normalized(path)
                != ConversationSessionLocationPath.normalized(target.initialPath)
    }

    private var revealURL: URL? {
        guard let row = target.editedRow else { return nil }
        return row.storedCustomRoot
            ?? ConversationSessionLocationPath.expanded(row.dataRoot.path)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = appLanguage.localized("选择")
        panel.message = appLanguage.localized("选择会话数据文件夹")

        let current = ConversationSessionLocationPath.expanded(path)
        if ConversationSessionLocationPath.exists(current) {
            panel.directoryURL = current
        }
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        path = ConversationSessionLocationPath.display(selected)
        pathFocused = true
    }

    private func commit() {
        guard canSave else {
            validationMessage = "请输入绝对文件夹路径"
            return
        }
        let submittedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        Task {
            let error = await save(source, submittedPath)
            isWorking = false
            validationMessage = error
            if error == nil { dismiss() }
        }
    }

    private func removeLocation(_ row: ConversationSessionLocationRow) {
        isWorking = true
        Task {
            let error = await remove(row)
            isWorking = false
            validationMessage = error
            if error == nil { dismiss() }
        }
    }
}

private enum ConversationSessionLocationPath {
    static func display(_ url: URL) -> String {
        display(url.standardizedFileURL.path)
    }

    static func display(_ rawPath: String) -> String {
        let path = expanded(rawPath).standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~/" + String(path.dropFirst(home.count + 1))
        }
        return path
    }

    static func expanded(_ rawPath: String) -> URL {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    static func isAbsolute(_ rawPath: String) -> Bool {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path == "~" || path.hasPrefix("~/") || path.hasPrefix("/")
    }

    static func normalized(_ rawPath: String) -> String {
        guard isAbsolute(rawPath) else { return rawPath }
        return expanded(rawPath).standardizedFileURL.path
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.standardizedFileURL.path)
    }
}

private struct ConversationSessionLocationGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.ccMuted)
            .background(configuration.isPressed
                ? Color.ccConversationSecondary
                : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct ConversationSessionLocationDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.ccRed)
            .background(configuration.isPressed ? Color.ccRedSoft : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
