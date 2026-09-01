import SwiftUI

struct SkillsTagEditorSheet: View {
    let title: String
    let initialTags: [String]
    let suggestions: [String]
    let apply: ([String]) -> Void

    @Environment(\.appLanguage) private var appLanguage
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(appLanguage.localized(title))
                .font(.ccHeading())
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.list)
                .hairline(.bottom)

            VStack(alignment: .leading, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(appLanguage.localized("标签"))
                        .font(.ccBody(.medium))
                    TextField(appLanguage.localized("例如：开发、写作、效率…"), text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.ccBody())
                        .accessibilityIdentifier("skills.tags.editor")
                    Text(appLanguage.localized("使用逗号分隔多个标签。"))
                        .font(.ccCaption())
                        .foregroundStyle(Theme.mutedForeground)
                }

                if !remainingSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text(appLanguage.localized("现有标签"))
                            .font(.ccCaption(.medium))
                            .foregroundStyle(Theme.mutedForeground)
                        FlowLayout(spacing: Space.sm) {
                            ForEach(remainingSuggestions, id: \.self) { tag in
                                Button {
                                    append(tag)
                                } label: {
                                    Label(tag, systemImage: "plus")
                                }
                                .buttonStyle(.ccSecondary)
                                .accessibilityLabel(appLanguage.localized("添加标签 \(tag)"))
                            }
                        }
                    }
                }
            }
            .padding(Space.xl)

            HStack(spacing: Space.sm) {
                Spacer()
                Button(appLanguage.localized("取消")) { dismiss() }
                    .buttonStyle(.ccSecondary)
                Button(appLanguage.localized("保存")) {
                    apply(tags)
                    dismiss()
                }
                .buttonStyle(.ccPrimary)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.md)
            .background(Theme.list)
            .hairline(.top)
        }
        .frame(width: 480)
        .background(Theme.background)
        .onAppear { draft = initialTags.joined(separator: ", ") }
        .accessibilityContainerIdentifier(
            "skills.tags.sheet",
            label: appLanguage.localized(title)
        )
    }

    private var tags: [String] {
        var seen = Set<String>()
        return draft
            .components(separatedBy: CharacterSet(charactersIn: ",，"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var remainingSuggestions: [String] {
        let selected = Set(tags)
        return suggestions.filter { !selected.contains($0) }
    }

    private func append(_ tag: String) {
        let separator = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : ", "
        draft += separator + tag
    }
}

/// A compact wrapping layout for tags and tool choices. SwiftUI's standard stacks either clip
/// dynamic content or reserve a full row per badge; this keeps the visual rhythm at any locale.
struct FlowLayout: Layout {
    var spacing: CGFloat = Space.sm

    struct Cache {
        var sizes: [CGSize] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let width = proposal.width ?? cache.sizes.reduce(0) { $0 + $1.width + spacing }
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var height: CGFloat = 0
        for size in cache.sizes {
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                height += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: height + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = cache.sizes[index]
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
