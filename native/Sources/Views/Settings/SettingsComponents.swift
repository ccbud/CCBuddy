import SwiftUI

struct SettingsCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 13, weight: .semibold))
            content
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevatedCard(radius: 12)
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
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(.system(size: 12.5, weight: .medium))
                if let detail {
                    Text(LocalizedStringKey(detail))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.ccCaption)
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
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(connected ? Color.ccGreen : Color.ccMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(connected ? Color.ccGreenSoft : Color.ccForeground.opacity(0.05))
            .clipShape(Capsule())
    }
}

struct SettingsDivider: View {
    var body: some View { Rectangle().fill(Color.ccBorder).frame(height: 1) }
}

struct CompactActionButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: primary ? .semibold : .medium))
            .foregroundStyle(primary ? Color.white : Color.ccForeground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(primary ? Color.ccBrandStrong : Color.ccElevated)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                if !primary {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.ccBorder)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
    }
}
