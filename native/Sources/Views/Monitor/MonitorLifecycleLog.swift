import SwiftUI

struct MonitorLifecycleLog: View {
    @ObservedObject var store: MonitorStore
    let port: Int
    let gatewayRunning: Bool
    let revealsSensitiveData: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appLanguage) private var appLanguage
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if reduceMotion {
                    expanded.toggle()
                } else {
                    withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
                }
            } label: {
                HStack(spacing: 8) {
                    Text("网关日志")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.mutedForeground)
                    if !store.lifecycleEvents.isEmpty {
                        Text("\(store.lifecycleEvents.count)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.mutedForeground)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.foreground.opacity(0.055))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(gatewayRunning ? Theme.success : Theme.mutedForeground)
                            .frame(width: 6, height: 6)
                        Text(gatewayStatusLabel)
                    }
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(gatewayRunning ? Theme.success : Theme.mutedForeground)
                }
                .padding(.horizontal, 14)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(MonitorPressableButtonStyle())
            .accessibilityLabel(lifecycleAccessibilityLabel)
            .accessibilityIdentifier("monitor.lifecycle.toggle")

            if expanded {
                Rectangle().fill(Theme.separator).frame(height: 1)
                lifecycleBody
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).stroke(Theme.separator))
    }

    @ViewBuilder private var lifecycleBody: some View {
        if store.lifecycleEvents.isEmpty {
            VStack(spacing: 5) {
                Text("暂无网关事件")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.mutedForeground)
                Text("启动、停止、重试与请求错误会显示在这里")
                    .font(.ccLabel())
                    .foregroundStyle(Theme.mutedForeground)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.lifecycleEvents.reversed()) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Text(event.level.rawValue.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(color(for: event.level))
                                .frame(width: 52, alignment: .leading)
                            Text(localizedMessage(event.message))
                                .font(.ccMono(Typography.label))
                                .foregroundStyle(Theme.mutedForeground)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .privacySensitive()
                            Text(MonitorFormat.clock(event.timestamp))
                                .font(.ccMono(Typography.label))
                                .foregroundStyle(Theme.mutedForeground)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
    }

    private func color(for level: MonitorLifecycleEvent.Level) -> Color {
        switch level {
        case .debug: Theme.mutedForeground
        case .info: Theme.accentText
        case .warning: Theme.warning
        case .error: Theme.danger
        }
    }

    private var gatewayStatusLabel: String {
        let state = appLanguage.localized(gatewayRunning ? "运行中" : "未运行")
        return appLanguage.localized("\(state) · localhost:\(port)")
    }

    private var lifecycleAccessibilityLabel: String {
        let state = appLanguage.localized(expanded ? "已展开" : "已折叠")
        return appLanguage.localized("网关日志，\(state)")
    }

    private func localizedMessage(_ message: String) -> String {
        let visible = revealsSensitiveData
            ? message
            : MonitorPrivacyRedactor.redact(message, language: appLanguage)
        return appLanguage.localized(visible)
    }
}
