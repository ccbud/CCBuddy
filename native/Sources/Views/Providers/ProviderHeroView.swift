import AppKit
import SwiftUI

struct ProviderHeroView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage
    @State private var range: UsageRange = .thirtyDays
    @State private var copiedEndpoint = false

    /// The gateway block is the page's masthead, not a floating card.
    ///
    /// It sits on the list material with a hairline below, the way the reading header sits above a
    /// transcript. A bordered, shadowed card here read as one dashboard tile among many and made the
    /// page look like a widget wall; as a masthead it simply states what the gateway is doing.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.md) {
                heroIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.ccHeading())
                        .tracking(-0.2)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.ccCaption())
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(1)
                }
                Spacer(minLength: Space.lg)
                Button(actionTitle) {
                    Task { await model.setGatewayEnabled(!model.gatewayState.isRunning) }
                }
                .buttonStyle(CCButtonStyle(role: model.gatewayState.isRunning ? .secondary : .primary))
                .disabled(isBusy)
                .accessibilityIdentifier("providers.connect")
            }

            if model.gatewayState.isRunning {
                ProviderHeroUsageView(
                    model: model,
                    port: model.gatewayState.runningPort ?? model.config.port,
                    range: $range,
                    copiedEndpoint: $copiedEndpoint,
                    copyEndpoint: copyEndpoint
                )
                .padding(.top, Space.lg)
            }
        }
        .padding(.top, Metrics.titleBarHeight)
        .padding(.horizontal, Space.xl)
        .padding(.bottom, Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The drag surface sits in front of the material and behind the controls, so empty parts of
        // the masthead move the window while its buttons keep their ordinary events.
        .background(WindowDragRegion())
        .background(Theme.list)
        .hairline(.bottom)
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityIdentifier("providers.hero")
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var heroIcon: some View {
        if model.gatewayState.isRunning, let provider = model.activeProvider {
            ProviderIconView(name: provider.name, icon: provider.icon, size: 34)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(Theme.fill)
                Image(systemName: "bolt.slash")
                    .font(.system(size: Typography.body))
                    .foregroundStyle(Theme.mutedForeground)
            }
            .frame(width: 34, height: 34)
        }
    }

    private var isBusy: Bool {
        if case .starting = model.gatewayState { return true }
        return false
    }

    private var title: String {
        switch model.gatewayState {
        case .running:
            return model.activeProvider?.name ?? appLanguage.localized("网关运行中")
        case .starting:
            return appLanguage.localized("正在启动网关")
        case .failed:
            return appLanguage.localized("网关启动失败")
        case .stopped:
            return appLanguage.localized("网关已停止")
        }
    }

    private var actionTitle: String {
        if isBusy { return appLanguage.localized("启动中…") }
        return appLanguage.localized(model.gatewayState.isRunning ? "停止服务" : "启动服务")
    }

    private var subtitle: String {
        switch model.gatewayState {
        case .running:
            if let name = model.activeProvider?.name {
                return appLanguage.localized("经 \(name) 转发 · 在下方选择其他服务商")
            }
            return "Bifrost · localhost:\(model.config.port)"
        case .starting:
            return appLanguage.localized("正在启动 Bifrost…")
        case .failed(let message):
            return appLanguage.localized(message)
        case .stopped:
            return appLanguage.localized("启动后，已接入的 CLI 会通过本机网关转发")
        }
    }

    private func copyEndpoint() {
        let endpoint = "http://localhost:\(model.gatewayState.runningPort ?? model.config.port)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpoint, forType: .string)
        copiedEndpoint = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copiedEndpoint = false
        }
    }
}

private struct ProviderHeroUsageView: View {
    @Environment(\.appLanguage) private var appLanguage
    @ObservedObject var model: AppModel
    let port: Int
    @Binding var range: UsageRange
    @Binding var copiedEndpoint: Bool
    let copyEndpoint: () -> Void

    private let availableRanges: [UsageRange] = [.sevenDays, .thirtyDays, .all]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                Button(action: copyEndpoint) {
                    HStack(spacing: Space.xs + 2) {
                        Circle().fill(Theme.success).frame(width: 6, height: 6)
                        Text(copiedEndpoint
                            ? appLanguage.localized("已复制 ✓")
                            : "localhost:\(port)")
                            .font(.ccMono(Typography.caption))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.mutedForeground)
                .help(appLanguage.localized("复制网关地址"))
                .accessibilityLabel(
                    "localhost:\(port) · \(appLanguage.localized("复制网关地址"))"
                )
                .accessibilityIdentifier("providers.endpoint")

                Spacer(minLength: 8)

                Picker(appLanguage.localized("用量范围"), selection: $range) {
                    ForEach(availableRanges) { item in
                        Text(rangeLabel(item)).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 168)
                .controlSize(.small)
                .accessibilityIdentifier("providers.usage.range")
            }

            usageContent
        }
        .task { await model.refreshUsageHistory() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("providers.usage")
    }

    @ViewBuilder private var usageContent: some View {
        switch model.usageHistoryState {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(appLanguage.localized("正在读取历史用量…"))
                    .font(.ccCaption())
                    .foregroundStyle(Theme.mutedForeground)
            }
            .frame(height: 62, alignment: .leading)
            .accessibilityIdentifier("providers.usage.loading")
        case .failed(let message):
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appLanguage.localized("历史用量读取失败"))
                        .font(.ccBody(.medium))
                    Text(message)
                        .font(.ccLabel())
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(appLanguage.localized("重试")) {
                    Task { await model.refreshUsageHistory(invalidate: true) }
                }
                    .buttonStyle(.ccQuiet)
            }
            .frame(height: 62, alignment: .leading)
            .accessibilityIdentifier("providers.usage.error")
        case .loaded:
            if let summary = model.usageHistorySummary(for: range) {
                summaryContent(summary)
            } else {
                Text(appLanguage.localized("历史用量暂不可用"))
                    .font(.ccCaption())
                    .foregroundStyle(Theme.mutedForeground)
                    .frame(height: 62, alignment: .leading)
                    .accessibilityIdentifier("providers.usage.unavailable")
            }
        }
    }

    private func summaryContent(_ summary: UsageHistorySummary) -> some View {
        let sparkValues = ProviderHeroUsage.sparkValues(summary: summary, range: range)
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(UsageFormat.compactTokens(summary.tokens))
                    .font(.ccTitle())
                    .tracking(-0.3)
                    .monospacedDigit()
                    .accessibilityLabel(UsageFormat.compactTokens(summary.tokens))
                    .accessibilityIdentifier("providers.usage.tokens")
                Text(appLanguage.localized("tokens"))
                    .font(.ccCaption())
                    .foregroundStyle(Theme.mutedForeground)
                Text(verbatim: "·").font(.ccCaption()).foregroundStyle(Theme.faintForeground)
                Text(appLanguage.localized(
                    "\(UsageFormat.integer(summary.requests)) 次请求"
                ))
                    .font(.ccCaption())
                    .foregroundStyle(Theme.mutedForeground)
                    .accessibilityLabel(appLanguage.localized(
                        "\(UsageFormat.integer(summary.requests)) 次请求"
                    ))
                    .accessibilityIdentifier("providers.usage.requests")
                if let favoriteModel = summary.favoriteModel {
                    Text(verbatim: "· \(favoriteModel)")
                        .font(.ccMono(Typography.caption))
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            ProviderUsageSparkline(values: sparkValues)
                .frame(height: 44)
                .accessibilityLabel(appLanguage.localized("用量趋势"))
                .accessibilityValue(sparkValues.map(String.init).joined(separator: ", "))
                .accessibilityIdentifier("providers.usage.sparkline")
        }
    }

    private func rangeLabel(_ value: UsageRange) -> String {
        switch value {
        case .sevenDays: appLanguage.localized("7天")
        case .thirtyDays: appLanguage.localized("30天")
        case .all: appLanguage.localized("全部")
        case .oneDay: appLanguage.localized("今日")
        }
    }
}

enum ProviderHeroUsage {
    static func sparkValues(summary: UsageHistorySummary, range: UsageRange) -> [Int] {
        let days = switch range {
        case .sevenDays: 7
        case .thirtyDays: 30
        case .all: 90
        case .oneDay: 1
        }
        return summary.heatmap.suffix(days).map(\.tokens)
    }
}

private struct ProviderUsageSparkline: View {
    let values: [Int]

    var body: some View {
        GeometryReader { proxy in
            let points = normalizedPoints(in: proxy.size)
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: proxy.size.height))
                    path.addLine(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                    if let last = points.last {
                        path.addLine(to: CGPoint(x: last.x, y: proxy.size.height))
                    }
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [Theme.accent.opacity(0.20), Theme.accent.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(
                    Theme.accent.opacity(0.85),
                    style: .init(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let maximum = max(1, values.max() ?? 0)
        let widthStep = values.count > 1 ? size.width / CGFloat(values.count - 1) : 0
        return values.enumerated().map { index, value in
            let ratio = CGFloat(max(0, value)) / CGFloat(maximum)
            return CGPoint(
                x: CGFloat(index) * widthStep,
                y: max(1, (size.height - 2) * (1 - ratio))
            )
        }
    }
}

private extension BifrostGatewayState {
    var runningPort: Int? {
        if case .running(let port) = self { return port }
        return nil
    }
}
