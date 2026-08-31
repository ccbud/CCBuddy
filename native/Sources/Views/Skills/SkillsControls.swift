import SwiftUI

struct SkillsFilterBar: View {
    @Binding var query: String
    @Binding var status: SkillsStatusFilter
    @Binding var tag: String
    @Binding var sort: SkillsSortOrder
    @Binding var displayMode: SkillsDisplayMode
    @Binding var bulkMode: Bool
    let tags: [String]

    @Environment(\.appLanguage) private var appLanguage
    @FocusState private var searchFocused: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.sm) {
                searchField.frame(minWidth: 220)
                statusPicker
                tagPicker
                sortPicker
                bulkButton
                displayPicker
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                searchField
                HStack(spacing: Space.sm) {
                    statusPicker
                    tagPicker
                    sortPicker
                    Spacer(minLength: 0)
                    bulkButton
                    displayPicker
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.mutedForeground)
            TextField(appLanguage.localized("搜索 Skills…"), text: $query)
                .textFieldStyle(.plain)
                .font(.ccBody())
                .focused($searchFocused)
                .accessibilityLabel(appLanguage.localized("搜索 Skills"))
                .accessibilityIdentifier("skills.search")
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(CCIconButtonStyle(size: 22, symbolSize: Typography.label))
                .help(appLanguage.localized("清除搜索"))
                .accessibilityLabel(appLanguage.localized("清除搜索"))
            }
        }
        .padding(.horizontal, Space.sm)
        .frame(height: Metrics.controlHeight + Space.xs)
        .background(Theme.fill)
        .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
    }

    private var statusPicker: some View {
        Picker(appLanguage.localized("全部状态"), selection: $status) {
            ForEach(SkillsStatusFilter.allCases) { item in
                Text(appLanguage.localized(item.title)).tag(item)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("skills.filter.status")
    }

    private var tagPicker: some View {
        Picker(appLanguage.localized("全部标签"), selection: $tag) {
            Text(appLanguage.localized("全部标签")).tag("")
            Text(appLanguage.localized("无标签")).tag("__untagged__")
            if !tags.isEmpty { Divider() }
            ForEach(tags, id: \.self) { item in Text(verbatim: item).tag(item) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("skills.filter.tag")
    }

    private var sortPicker: some View {
        Picker(appLanguage.localized("最近更新"), selection: $sort) {
            ForEach(SkillsSortOrder.allCases) { item in
                Text(appLanguage.localized(item.title)).tag(item)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("skills.filter.sort")
    }

    private var bulkButton: some View {
        Button {
            bulkMode.toggle()
        } label: {
            Label(appLanguage.localized("批量操作"), systemImage: "checklist")
        }
        .buttonStyle(bulkMode ? .ccPrimary : .ccSecondary)
        .accessibilityIdentifier("skills.bulk.toggle")
    }

    private var displayPicker: some View {
        HStack(spacing: 1) {
            ForEach(SkillsDisplayMode.allCases) { mode in
                Button {
                    displayMode = mode
                } label: {
                    Image(systemName: mode.symbol)
                }
                .buttonStyle(CCIconButtonStyle(
                    tint: displayMode == mode ? Theme.accentText : Theme.mutedForeground,
                    filled: displayMode == mode
                ))
                .help(appLanguage.localized(mode.title))
                .accessibilityLabel(appLanguage.localized(mode.title))
                .accessibilityValue(displayMode == mode ? appLanguage.localized("已选择") : "")
            }
        }
        .padding(2)
        .background(Theme.fill)
        .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.display-mode")
    }
}

struct SkillsSelectionBar: View {
    let count: Int
    let total: Int
    let selectAll: () -> Void
    let editTags: () -> Void
    let sync: () -> Void
    let delete: () -> Void
    let clear: () -> Void

    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(appLanguage.localized("已选择 \(count) 项"))
                .font(.ccBody(.medium))
                .monospacedDigit()
            Spacer(minLength: Space.md)
            Button(appLanguage.localized(count == total ? "取消全选" : "全选"), action: selectAll)
                .buttonStyle(.ccQuiet)
                .disabled(total == 0)
            Button(appLanguage.localized("编辑标签"), action: editTags)
                .buttonStyle(.ccSecondary)
                .disabled(count == 0)
            Button(appLanguage.localized("同步所选"), action: sync)
                .buttonStyle(.ccSecondary)
                .disabled(count == 0)
            Button(appLanguage.localized("删除所选"), action: delete)
                .buttonStyle(.ccDanger)
                .disabled(count == 0)
            Button(action: clear) { Image(systemName: "xmark") }
                .buttonStyle(.ccIcon)
                .help(appLanguage.localized("清除选择"))
                .accessibilityLabel(appLanguage.localized("清除选择"))
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(Theme.surface)
        .hairline(.top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.bulk.bar")
    }
}

struct SkillsToolMark: View {
    let label: String
    var active = true
    var issue = false

    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        Text(verbatim: initials)
            .font(.ccLabel(.semibold))
            .foregroundStyle(issue ? Theme.danger : active ? Theme.accentText : Theme.faintForeground)
            .frame(width: 24, height: 24)
            .background(issue ? Theme.dangerSoft : active ? Theme.accentSoft : Theme.fill)
            .clipShape(Circle())
            .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
            .help(label)
            .accessibilityLabel(label)
            .accessibilityValue(appLanguage.localized(issue ? "异常" : active ? "已同步" : "未同步"))
    }

    private var initials: String {
        let words = label.split(whereSeparator: { $0.isWhitespace })
        if words.count > 1 { return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
        return String(label.prefix(2)).uppercased()
    }
}
