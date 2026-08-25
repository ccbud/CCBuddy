import AppKit
import SwiftUI

struct MonitorRuntimeKey: Hashable {
    let port: Int
    let gatewayRunning: Bool
}

extension View {
    /// SwiftUI propagates a container identifier over nested AppKit controls on macOS. A separate
    /// marker preserves the container hook without erasing the identifiers of its descendants.
    func monitorAccessibilityContainerIdentifier(_ identifier: String, label: String) -> some View {
        overlay(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
                .allowsHitTesting(false)
        }
    }
}

enum MonitorFormat {
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let fullTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func clock(_ date: Date?) -> String {
        guard let date, date != .distantPast else { return "—" }
        return clock.string(from: date)
    }

    static func timestamp(_ date: Date?) -> String {
        guard let date, date != .distantPast else { return "—" }
        return fullTimestamp.string(from: date)
    }

    static func integer(_ value: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func milliseconds(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if value < 10 { return String(format: "%.1f", value) }
        return String(format: "%.0f", value)
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        // Bifrost's `success_rate` is already expressed as a percentage (for example, 99 == 99%).
        return String(format: "%.0f%%", min(max(value, 0), 100))
    }

    static func compactCost(_ value: Double?) -> String? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value < 0.01 ? String(format: "$%.4f", value) : String(format: "$%.2f", value)
    }

    static func prettyJSON(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func prettyRaw(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let string = String(data: pretty, encoding: .utf8)
        else { return raw }
        return string
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension BifrostLogStatus {
    func monitorLabel(language: AppLanguage) -> String {
        switch self {
        case .processing: language.localized("处理中")
        case .success: language.localized("成功")
        case .error: language.localized("错误")
        case .cancelled: language.localized("已取消")
        case .unknown(let value): value.isEmpty ? language.localized("未知") : value
        }
    }

    var monitorColor: Color {
        switch self {
        case .processing: Theme.warning
        case .success: Theme.success
        case .error: Theme.danger
        case .cancelled: Theme.mutedForeground
        case .unknown: Theme.mutedForeground
        }
    }

    var monitorBackground: Color {
        switch self {
        case .success: Theme.successSoft
        case .error: Theme.dangerSoft
        case .processing: Theme.warning.opacity(0.13)
        case .cancelled, .unknown: Theme.foreground.opacity(0.055)
        }
    }
}

struct MonitorPressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.1),
                value: configuration.isPressed
            )
    }
}

struct MonitorActionButton: View {
    @Environment(\.appLanguage) private var appLanguage

    let title: String
    let symbol: String
    var destructive = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(appLanguage.localized(title), systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(destructive ? Theme.danger : Theme.foreground)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .stroke(destructive ? Theme.danger.opacity(0.25) : Theme.separator)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(MonitorPressableButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

struct MonitorMaterialBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Theme.surface
        } else {
            Rectangle().fill(.ultraThickMaterial)
                .overlay(Theme.surface.opacity(0.58))
        }
    }
}
