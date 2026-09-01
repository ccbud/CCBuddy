import AppKit
import SwiftUI

struct SkillsFilePreview: View {
    let detail: SkillDetail
    let readFile: (String) async throws -> String

    @Environment(\.appLanguage) private var appLanguage
    @State private var selectedPath = ""
    @State private var content = ""
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var generation = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(appLanguage.localized("skills.detail.files")).font(.ccBody(.medium))
            GeometryReader { proxy in
                if proxy.size.width >= 680 {
                    HStack(spacing: 0) {
                        fileList.frame(width: 230)
                        Divider()
                        preview
                    }
                } else {
                    VStack(spacing: 0) {
                        fileList.frame(height: 150)
                        Divider()
                        preview
                    }
                }
            }
            .frame(minHeight: 380)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        }
        .onAppear(perform: selectInitialFile)
        .onChange(of: detail) { _ in refreshSelection() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.detail.files")
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if sortedFiles.isEmpty {
                    Text(appLanguage.localized("此 Skill 中没有文件。"))
                        .font(.ccCaption())
                        .foregroundStyle(Theme.mutedForeground)
                        .padding(Space.lg)
                } else {
                    ForEach(sortedFiles) { file in fileRow(file) }
                }
            }
            .padding(Space.sm)
        }
        .background(Theme.list)
    }

    private func fileRow(_ file: SkillFile) -> some View {
        let selected = selectedPath == file.path
        return Button { select(file.path) } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: file.path.lowercased().hasSuffix("skill.md")
                    ? "doc.text.fill" : "doc")
                    .foregroundStyle(selected ? Theme.accentText : Theme.mutedForeground)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: file.path)
                        .font(.ccCaption(selected ? .medium : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: file.sizeDescription)
                        .font(.ccLabel())
                        .foregroundStyle(Theme.faintForeground)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.foreground)
            .padding(.horizontal, Space.sm)
            .frame(minHeight: 38)
            .background(selected ? Theme.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? appLanguage.localized("已选择") : "")
        .accessibilityIdentifier("skills.file.\(file.path)")
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.sm) {
                Text(verbatim: selectedPath.isEmpty
                    ? appLanguage.localized("选择一个文件进行预览。")
                    : selectedPath)
                    .font(.ccMono(Typography.caption, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Space.sm)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selectedPath, forType: .string)
                } label: {
                    Label(appLanguage.localized("复制路径"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.ccQuiet)
                .disabled(selectedPath.isEmpty)
            }
            .padding(.horizontal, Space.md)
            .frame(minHeight: 40)
            .background(Theme.list)
            Divider()
            Group {
                if loading {
                    SkillsLoadingState(title: "正在加载…")
                } else if let errorMessage {
                    CCEmptyState(
                        symbol: "exclamationmark.triangle",
                        title: appLanguage.localized("无法读取此文件。"),
                        message: errorMessage,
                        compact: true
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if selectedPath.isEmpty {
                    CCEmptyState(
                        symbol: "doc.text",
                        title: appLanguage.localized("选择一个文件进行预览。"),
                        compact: true
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: content)
                            .font(.ccMono())
                            .foregroundStyle(Theme.foreground)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(Space.lg)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sortedFiles: [SkillFile] {
        detail.files.sorted { left, right in
            let leftManifest = left.path.lowercased().hasSuffix("skill.md")
            let rightManifest = right.path.lowercased().hasSuffix("skill.md")
            if leftManifest != rightManifest { return leftManifest }
            return left.path.localizedCaseInsensitiveCompare(right.path) == .orderedAscending
        }
    }

    private func selectInitialFile() {
        guard let first = sortedFiles.first else {
            generation = UUID()
            selectedPath = ""; content = ""; errorMessage = nil; loading = false
            return
        }
        select(first.path)
    }

    private func refreshSelection() {
        if !selectedPath.isEmpty, sortedFiles.contains(where: { $0.path == selectedPath }) {
            select(selectedPath)
        } else {
            selectInitialFile()
        }
    }

    private func select(_ path: String) {
        selectedPath = path; content = ""; errorMessage = nil; loading = true
        let token = UUID(); generation = token
        Task {
            do {
                let value = try await readFile(path)
                guard generation == token else { return }
                content = value
            } catch {
                guard generation == token else { return }
                errorMessage = error.localizedDescription
            }
            if generation == token { loading = false }
        }
    }
}
