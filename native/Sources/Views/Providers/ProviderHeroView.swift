import AppKit
import SwiftUI

struct ProviderHeroView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage
    @State private var range: UsageRange = .thirtyDays
    @State private var copiedEndpoint = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                heroIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16.5, weight: .semibold))
                        .tracking(-0.25)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.ccMuted)
                }
                Spacer(minLength: 16)
                Button(actionTitle) {
                    Task { await model.setGatewayEnabled(!model.gatewayState.isRunning) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.gatewayState.isRunning ? Color.ccRed : .white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(model.gatewayState.isRunning ? Color.ccRedSoft : Color.ccBrandStrong)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .disabled(isBusy)
                .opacity(isBusy ? 0.58 : 1)
                .accessibilityIdentifier("providers.connect")
            }

            if model.gatewayState.isRunning {
                Divider()
                    .overlay(Color.ccBorder)
                    .padding(.top, 20)
                    .padding(.bottom, 11)

                ProviderHeroUsageView(
                    model: model,
                    port: model.gatewayState.runningPort ?? model.config.port,
                    range: $range,
                    copiedEndpoint: $copiedEndpoint,
                    copyEndpoint: copyEndpoint
                )
            }
        }
        .padding(24)
        .elevatedCard(
            radius: 18,
            border: model.gatewayState.isRunning ? .ccGreen.opacity(0.45) : .ccBorder
        )
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
            ProviderIconView(name: provider.name, icon: provider.icon, size: 38)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(model.gatewayState.isRunning ? Color.ccGreenSoft : Color.ccForeground.opacity(0.05))
                Image(systemName: model.gatewayState.isRunning ? "bolt.fill" : "bolt.slash")
                    .foregroundStyle(model.gatewayState.isRunning ? Color.ccGreen : Color.ccMuted)
            }
            .frame(width: 38, height: 38)
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
                return appLanguage.localized("经 \(name) 转发 · 点卡片切换")
            }
            return "Gateway · localhost:\(model.config.port)"
        case .starting:
            return appLanguage.localized("正在启动网关…")
        case .failed(let message):
            return appLanguage.localized(message)
        case .stopped:
            return appLanguage.localized("在设置中开启网关服务；启动服务会保留此选择")
        }
    }

    private func copyEndpoint() {
        let endpoint = "http://localhost:\(model.gatewayState.runningPort ?? model.config.port)"
        AppClipboard.write(endpoint)
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Button(action: copyEndpoint) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.ccGreen).frame(width: 6, height: 6)
                        Text(copiedEndpoint
                            ? appLanguage.localized("已复制 ✓")
                            : "localhost:\(port)")
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ccMuted)
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
                .frame(width: 156)
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
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ccMuted)
            }
            .frame(height: 69, alignment: .leading)
            .accessibilityIdentifier("providers.usage.loading")
        case .failed(let message):
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color.ccOrange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appLanguage.localized("历史用量读取失败"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.ccCaption)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(appLanguage.localized("重试")) {
                    Task { await model.refreshUsageHistory(invalidate: true) }
                }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
            }
            .frame(height: 69, alignment: .leading)
            .accessibilityIdentifier("providers.usage.error")
        case .loaded:
            if let summary = model.usageHistorySummary(for: range) {
                summaryContent(summary)
            } else {
                Text(appLanguage.localized("历史用量暂不可用"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ccMuted)
                    .frame(height: 69, alignment: .leading)
                    .accessibilityIdentifier("providers.usage.unavailable")
            }
        }
    }

    private func summaryContent(_ summary: UsageHistorySummary) -> some View {
        let sparkValues = ProviderHeroUsage.sparkValues(summary: summary, range: range)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(UsageFormat.compactTokens(summary.tokens))
                    .font(.system(size: 23, weight: .bold, design: .monospaced))
                    .tracking(-0.3)
                    .monospacedDigit()
                    .accessibilityLabel(UsageFormat.compactTokens(summary.tokens))
                    .accessibilityIdentifier("providers.usage.tokens")
                Text(appLanguage.localized("tokens"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ccMuted)
                Text("·").foregroundStyle(Color.ccBorderStrong)
                Text(appLanguage.localized(
                    "\(UsageFormat.integer(summary.requests)) 次请求"
                ))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ccCaption)
                    .accessibilityLabel(appLanguage.localized(
                        "\(UsageFormat.integer(summary.requests)) 次请求"
                    ))
                    .accessibilityIdentifier("providers.usage.requests")
                if let favoriteModel = summary.favoriteModel {
                    Text("· \(favoriteModel)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.ccCaption)
                        .lineLimit(1)
                }
            }

            ProviderUsageSparkline(values: sparkValues)
                .frame(height: 46)
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
                        colors: [Color.ccBrandStrong.opacity(0.18), Color.ccBrandStrong.opacity(0.015)],
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
                    Color.ccBrandStrong.opacity(0.72),
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

private extension GatewayState {
    var runningPort: Int? {
        if case .running(let port) = self { return port }
        return nil
    }
}
