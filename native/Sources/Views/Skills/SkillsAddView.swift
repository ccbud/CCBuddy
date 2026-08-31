import AppKit
import SwiftUI

struct SkillsAddView: View {
    enum Source: String, CaseIterable, Identifiable {
        case git
        case local
        var id: String { rawValue }
        var title: String { self == .git ? "Git 仓库" : "本地文件夹" }
    }

    let snapshot: SkillsSnapshot
    let globallyBusy: Bool
    let scanLocal: (URL) async throws -> [SkillLocalCandidate]
    let installGit: (String, [String], [String], SkillSyncMode) async -> Bool
    let installLocal: ([URL], [String], [String], SkillSyncMode) async -> Bool
    let completed: () -> Void

    @Environment(\.appLanguage) private var appLanguage
    @State private var source = Source.git
    @State private var gitURL = ""
    @State private var localRoot: URL?
    @State private var candidates: [SkillLocalCandidate] = []
    @State private var selectedCandidates = Set<String>()
    @State private var tags = ""
    @State private var selectedToolKeys = Set<String>()
    @State private var syncMode = SkillSyncMode.auto
    @State private var working = false
    @State private var errorMessage: String?
    @State private var initializedTools = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                Picker(appLanguage.localized("添加来源"), selection: $source) {
                    ForEach(Source.allCases) { item in
                        Text(appLanguage.localized(item.title)).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 440)
                .accessibilityIdentifier("skills.add.source")

                VStack(alignment: .leading, spacing: 0) {
                    sourceHeader
                    Divider()
                    VStack(alignment: .leading, spacing: Space.xl) {
                        if source == .git { gitFields } else { localFields }
                        Divider()
                        SkillsInstallOptionsView(
                            tools: snapshot.tools,
                            tags: $tags,
                            selectedToolKeys: $selectedToolKeys,
                            syncMode: $syncMode
                        )
                    }
                    .padding(Space.xl)
                    Divider()
                    footer
                }
                .panelSurface()
            }
            .pageContent(measure: 980)
        }
        .onAppear { initializeTools() }
        .onChange(of: snapshot.tools.map(\.key)) { _ in initializeTools() }
        .onChange(of: source) { _ in errorMessage = nil }
    }

    private var sourceHeader: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: source == .git ? "arrow.triangle.branch" : "folder")
                .font(.ccHeading())
                .foregroundStyle(Theme.accentText)
                .frame(width: 40, height: 40)
                .background(Theme.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(appLanguage.localized(source.title)).font(.ccHeading())
                Text(appLanguage.localized(source == .git
                    ? "从仓库读取 SKILL.md，可一次导入一个或多个 Skills。"
                    : "选择含 SKILL.md 的文件夹，自动发现其中的 Skills。"))
                    .font(.ccCaption())
                    .foregroundStyle(Theme.mutedForeground)
            }
        }
        .padding(Space.xl)
    }

    private var gitFields: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(appLanguage.localized("仓库地址")).font(.ccBody(.medium))
            TextField("https://github.com/owner/repo…", text: $gitURL)
                .textFieldStyle(.roundedBorder)
                .font(.ccMono())
                .accessibilityIdentifier("skills.add.git-url")
            Text(appLanguage.localized("单 Skill 仓库会直接安装；多 Skill 仓库会一并导入。"))
                .font(.ccCaption())
                .foregroundStyle(Theme.mutedForeground)
        }
    }

    private var localFields: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(appLanguage.localized("所选路径")).font(.ccBody(.medium))
                    Text(verbatim: localRoot?.path ?? appLanguage.localized("尚未选择文件夹"))
                        .font(.ccMono(Typography.caption))
                        .foregroundStyle(localRoot == nil ? Theme.faintForeground : Theme.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: Space.md)
                Button(appLanguage.localized("选择…"), action: chooseLocalFolder)
                    .buttonStyle(.ccSecondary)
                    .disabled(working || globallyBusy)
                    .accessibilityIdentifier("skills.add.choose-local")
            }
            if !candidates.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack {
                        Text(appLanguage.localized("发现候选 Skills"))
                            .font(.ccBody(.medium))
                        Spacer()
                        Button(appLanguage.localized("全选")) {
                            selectedCandidates = Set(candidates.map { $0.id })
                        }
                        .buttonStyle(.ccQuiet)
                    }
                    ForEach(candidates) { candidate in candidateRow(candidate) }
                }
            } else if localRoot != nil, !working {
                Text(appLanguage.localized("所选文件夹中没有可导入的 Skill。"))
                    .font(.ccCaption())
                    .foregroundStyle(Theme.mutedForeground)
            }
        }
    }

    private func candidateRow(_ candidate: SkillLocalCandidate) -> some View {
        let selected = selectedCandidates.contains(candidate.id)
        return Button {
            if !selectedCandidates.insert(candidate.id).inserted { selectedCandidates.remove(candidate.id) }
        } label: {
            HStack(spacing: Space.md) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? Theme.accentText : Theme.mutedForeground)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(verbatim: candidate.name).font(.ccBody(.medium)).lineLimit(1)
                    Text(verbatim: candidate.description ?? candidate.path.path)
                        .font(.ccCaption()).foregroundStyle(Theme.mutedForeground).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.md)
            .background(selected ? Theme.selection : Theme.fillSubtle)
            .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? appLanguage.localized("已选择") : "")
    }

    private var footer: some View {
        HStack(spacing: Space.sm) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.ccCaption()).foregroundStyle(Theme.danger).lineLimit(2)
            } else {
                Text(summary).font(.ccCaption()).foregroundStyle(Theme.mutedForeground)
            }
            Spacer(minLength: Space.md)
            if working { ProgressView().controlSize(.small) }
            Button(appLanguage.localized(source == .git ? "安装" : "导入所选"), action: submit)
                .buttonStyle(.ccPrimary)
                .disabled(!canSubmit || working || globallyBusy)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("skills.add.submit")
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.md)
    }

    private var canSubmit: Bool {
        source == .git ? validGitURL : !selectedCandidates.isEmpty
    }

    private var validGitURL: Bool {
        let value = gitURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("https://") || value.hasPrefix("ssh://")
            || value.hasPrefix("git@")
    }

    private var summary: String {
        let toolCount = selectedToolKeys.count
        let tagCount = tags.parsedSkillTags.count
        return appLanguage.localized("已选择 \(toolCount) 个工具 · \(tagCount) 个标签")
    }

    private func initializeTools() {
        guard !initializedTools else { return }
        selectedToolKeys = Set(snapshot.tools.filter { $0.detected && $0.enabled }.map(\.key))
        initializedTools = true
    }

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        localRoot = url
        candidates = []
        selectedCandidates = []
        working = true
        errorMessage = nil
        Task {
            do {
                candidates = try await scanLocal(url)
                selectedCandidates = Set(candidates.map(\.id))
            } catch { errorMessage = error.localizedDescription }
            working = false
        }
    }

    private func submit() {
        working = true
        errorMessage = nil
        let toolKeys = Array(selectedToolKeys)
        let parsedTags = tags.parsedSkillTags
        Task {
            let succeeded: Bool
            if source == .git {
                succeeded = await installGit(gitURL, parsedTags, toolKeys, syncMode)
            } else {
                let paths = candidates.filter { selectedCandidates.contains($0.id) }.map(\.path)
                succeeded = await installLocal(paths, parsedTags, toolKeys, syncMode)
            }
            working = false
            if succeeded { reset(); completed() }
        }
    }

    private func reset() {
        gitURL = ""; localRoot = nil; candidates = []; selectedCandidates = []; tags = ""
    }
}
