import SwiftUI

struct SkillsRenameTagSheet: View {
    let original: String
    let rename: (String) -> Void

    @Environment(\.appLanguage) private var appLanguage
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(appLanguage.localized("重命名标签"))
                .font(.ccHeading())
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.list)
                .hairline(.bottom)
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(appLanguage.localized("标签")).font(.ccBody(.medium))
                TextField(appLanguage.localized("标签名称"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.ccBody())
                    .accessibilityIdentifier("skills.tags.rename.input")
            }
            .padding(Space.xl)
            HStack(spacing: Space.sm) {
                Spacer()
                Button(appLanguage.localized("取消")) { dismiss() }
                    .buttonStyle(.ccSecondary)
                Button(appLanguage.localized("保存")) {
                    rename(trimmedName)
                    dismiss()
                }
                .buttonStyle(.ccPrimary)
                .disabled(trimmedName.isEmpty || trimmedName == original)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.md)
            .background(Theme.list)
            .hairline(.top)
        }
        .frame(width: 420)
        .background(Theme.background)
        .onAppear { name = original }
        .accessibilityContainerIdentifier(
            "skills.tags.rename",
            label: appLanguage.localized("重命名标签")
        )
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
