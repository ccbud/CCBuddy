import SwiftUI

struct MonitorMetricCard: View {
    @Environment(\.appLanguage) private var appLanguage

    let title: String
    let value: String
    var unit: String?
    let subtitle: String
    var accent: Color = Theme.foreground
    var prominentNumber = false
    var showsStatusDot = false
    var statusActive = false
    var subtitlePrivacySensitive = false

    /// A cell in the metric strip, not a tile.
    ///
    /// These were four shadowed, individually bordered cards, which is exactly the dashboard tile
    /// wall the design system rules out — four boxes competing for attention above the request list
    /// that actually matters. They now share one panel and are separated by hairlines.
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs + 2) {
            Text(appLanguage.localized(title))
                .font(.ccLabel())
                .foregroundStyle(Theme.mutedForeground)
                .lineLimit(1)

            HStack(spacing: Space.xs + 2) {
                if showsStatusDot {
                    MonitorStatusDot(active: statusActive)
                }
                Text(value)
                    .font(.system(
                        size: prominentNumber ? Typography.heading : Typography.body,
                        weight: .medium,
                        design: prominentNumber ? .monospaced : .default
                    ))
                    .tracking(-0.2)
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                if let unit {
                    Text(unit)
                        .font(.ccMono(Typography.label))
                        .foregroundStyle(Theme.mutedForeground)
                        .padding(.top, 2)
                }
            }
            .frame(height: 21, alignment: .leading)

            Text(subtitle)
                .font(.ccLabel())
                .foregroundStyle(Theme.mutedForeground)
                .lineLimit(1)
                .truncationMode(.middle)
                .privacySensitive(subtitlePrivacySensitive)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }
}

private struct MonitorStatusDot: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            if active && !reduceMotion {
                Circle()
                    .stroke(Theme.success.opacity(0.5), lineWidth: 1)
                    .scaleEffect(pulse ? 2.1 : 1)
                    .opacity(pulse ? 0 : 0.48)
            }
            Circle()
                .fill(active ? Theme.success : Theme.mutedForeground)
        }
        .frame(width: 8, height: 8)
        .task(id: active && !reduceMotion) {
            pulse = false
            guard active, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.25).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
        .accessibilityHidden(true)
    }
}
