import SwiftUI

struct SettingsCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(LocalizedStringKey(title))
                .font(.ccBody(.medium))
            content
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(bordered: true)
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool
    var enabled = true

    init(
        _ title: String,
        detail: String? = nil,
        isOn: Binding<Bool>,
        enabled: Bool = true
    ) {
        self.title = title
        self.detail = detail
        _isOn = isOn
        self.enabled = enabled
    }

    var body: some View {
        HStack(spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(.ccBody())
                if let detail {
                    Text(LocalizedStringKey(detail))
                        .font(.ccCaption())
                        .foregroundStyle(Theme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!enabled)
        }
        .opacity(enabled ? 1 : 0.55)
    }
}

struct ConnectionBadge: View {
    let connected: Bool

    var body: some View {
        Text(LocalizedStringKey(connected ? "已接入" : "未接入"))
            .font(.ccLabel(.medium))
            .foregroundStyle(connected ? Theme.success : Theme.mutedForeground)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(connected ? Theme.successSoft : Theme.fill)
            .clipShape(RoundedRectangle(cornerRadius: Radius.badge, style: .continuous))
    }
}

struct SettingsDivider: View {
    var body: some View { Rectangle().fill(Theme.separator).frame(height: 1) }
}

struct CompactActionButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ccCaption(primary ? .semibold : .medium))
            .foregroundStyle(primary ? Theme.onAccent : Theme.foreground)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xs + 2)
            .background(primary ? Theme.accent : Theme.fillSubtle)
            .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .overlay {
                if !primary {
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 1)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
    }
}
