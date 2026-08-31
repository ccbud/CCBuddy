import SwiftUI

enum SkillsPage: String, CaseIterable, Identifiable {
    case library
    case add
    case tags
    case tools
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "我的 Skills"
        case .add: "添加"
        case .tags: "标签"
        case .tools: "skills.nav.tools"
        case .updates: "更新"
        }
    }

    var symbol: String {
        switch self {
        case .library: "square.stack.3d.up"
        case .add: "plus.circle"
        case .tags: "tag"
        case .tools: "wrench.and.screwdriver"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

enum SkillsDisplayMode: String, CaseIterable, Identifiable {
    case list
    case cards

    var id: String { rawValue }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
    var title: String { self == .list ? "列表视图" : "卡片视图" }
}

enum SkillsStatusFilter: String, CaseIterable, Identifiable {
    case all
    case synced
    case unsynced
    case partial
    case issue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部状态"
        case .synced: "已同步"
        case .unsynced: "未同步"
        case .partial: "部分同步"
        case .issue: "异常"
        }
    }
}

enum SkillsSortOrder: String, CaseIterable, Identifiable {
    case updated
    case name
    case source

    var id: String { rawValue }

    var title: String {
        switch self {
        case .updated: "最近更新"
        case .name: "名称"
        case .source: "来源"
        }
    }
}

struct SkillsStatusStyle {
    let title: String
    let tint: Color
    let backing: Color

    static func resolve(skillStatus: String, targetStatuses: [String]) -> SkillsStatusStyle {
        let issueWords = ["missing", "invalid", "error", "broken", "fail", "unavailable"]
        let skillIssue = issueWords.contains { skillStatus.lowercased().contains($0) }
        let targetIssue = targetStatuses.contains { status in
            issueWords.contains { status.lowercased().contains($0) }
        }
        if skillIssue || targetIssue {
            return .init(title: "异常", tint: Theme.danger, backing: Theme.dangerSoft)
        }
        if targetStatuses.isEmpty {
            return .init(title: "未同步", tint: Theme.mutedForeground, backing: Theme.fill)
        }
        let healthy = targetStatuses.allSatisfy {
            let value = $0.lowercased()
            return value.contains("sync") || value.contains("ok") || value.contains("healthy")
        }
        if healthy {
            return .init(title: "已同步", tint: Theme.success, backing: Theme.successSoft)
        }
        return .init(title: "部分同步", tint: Theme.warning, backing: Theme.warningSoft)
    }
}

struct SkillsPagePicker: View {
    @Binding var selection: SkillsPage
    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        Picker(appLanguage.localized("Skills 页面"), selection: $selection) {
            ForEach(SkillsPage.allCases) { page in
                Label(appLanguage.localized(page.title), systemImage: page.symbol).tag(page)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 540)
        .accessibilityIdentifier("skills.page-picker")
    }
}

struct SkillsMetricCard: View {
    let title: String
    let value: String
    var status: SkillsStatusStyle?
    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(appLanguage.localized(title))
                .font(.ccCaption())
                .foregroundStyle(Theme.mutedForeground)
                .lineLimit(1)
            if let status {
                CCStatusLabel(text: appLanguage.localized(status.title), tint: status.tint)
                    .frame(maxHeight: .infinity, alignment: .center)
            } else {
                Text(value)
                    .font(.ccTitle())
                    .foregroundStyle(Theme.foreground)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .panelSurface()
        .accessibilityElement(children: .combine)
    }
}

struct SkillsStatusBadge: View {
    let style: SkillsStatusStyle
    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        Text(appLanguage.localized(style.title))
            .font(.ccLabel(.medium))
            .foregroundStyle(style.tint)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .background(style.backing)
            .clipShape(RoundedRectangle(cornerRadius: Radius.badge, style: .continuous))
            .lineLimit(1)
    }
}

struct SkillsErrorBanner: View {
    let message: String
    let retry: () -> Void
    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.ccCaption())
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
            Button(appLanguage.localized("重试"), action: retry)
                .buttonStyle(.ccQuiet)
        }
        .foregroundStyle(Theme.danger)
        .padding(.horizontal, Space.md)
        .frame(minHeight: 38)
        .background(Theme.dangerSoft)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.error")
    }
}

struct SkillsLoadingState: View {
    let title: String
    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        CCEmptyState(
            symbol: "square.stack.3d.up",
            title: appLanguage.localized(title),
            showsProgress: true,
            compact: true
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("skills.loading")
    }
}
