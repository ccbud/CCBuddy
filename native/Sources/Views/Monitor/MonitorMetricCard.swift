import SwiftUI

struct MonitorMetricCard: View {
    @Environment(\.appLanguage) private var appLanguage

    let title: String
    let value: String
    var unit: String?
    let subtitle: String
    var accent: Color = .ccForeground
    var prominentNumber = false
    var showsStatusDot = false
    var statusActive = false
    var subtitlePrivacySensitive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appLanguage.localized(title).uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.45)
                .foregroundStyle(Color.ccCaption)
                .lineLimit(1)

            HStack(spacing: 7) {
                if showsStatusDot {
                    MonitorStatusDot(active: statusActive)
                }
                Text(value)
                    .font(.system(
                        size: prominentNumber ? 20 : 15,
                        weight: .bold,
                        design: prominentNumber ? .monospaced : .default
                    ))
                    .tracking(-0.25)
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                if let unit {
                    Text(unit)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.ccCaption)
                        .padding(.top, 4)
                }
            }
            .frame(height: 23, alignment: .leading)

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Color.ccMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .privacySensitive(subtitlePrivacySensitive)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .padding(18)
        .background(Color.ccElevated)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(statusActive && showsStatusDot ? Color.ccGreen.opacity(0.32) : Color.ccBorder)
        }
        .shadow(color: .black.opacity(0.065), radius: 10, y: 4)
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
                    .stroke(Color.ccGreen.opacity(0.5), lineWidth: 1)
                    .scaleEffect(pulse ? 2.1 : 1)
                    .opacity(pulse ? 0 : 0.48)
            }
            Circle()
                .fill(active ? Color.ccGreen : Color.ccMuted)
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
