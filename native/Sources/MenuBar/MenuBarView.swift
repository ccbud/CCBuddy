import SwiftUI

struct MenuBarView: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview
        case models

        var id: String { rawValue }
        var title: String { self == .overview ? "总览" : "模型" }
    }

    @ObservedObject var model: AppModel
    let onShowMain: () -> Void
    let onQuit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var section: Section = .overview
    @State private var range: UsageRange = .sevenDays

    init(
        model: AppModel,
        onShowMain: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.model = model
        self.onShowMain = onShowMain
        self.onQuit = onQuit
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: MenuBarPopoverLayout.headerHeight)
                .padding(.bottom, MenuBarPopoverLayout.headerToContentSpacing)

            Group {
                usageContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.99)))

            footer
                .frame(height: MenuBarPopoverLayout.footerHeight)
                .overlay(alignment: .top) {
                    Divider().overlay(Color.ccBorder)
                }
        }
        .padding(.horizontal, MenuBarPopoverLayout.horizontalInset)
        .padding(.top, MenuBarPopoverLayout.topInset)
        .frame(width: MenuBarPanelPositioner.defaultSize.width, height: MenuBarPanelPositioner.defaultSize.height)
        .background(panelBackground)
        .foregroundStyle(Color.ccForeground)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.ccBorderStrong.opacity(reduceTransparency ? 1 : 0.72), lineWidth: 1)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: section)
        .environment(\.locale, model.appLanguage.locale)
        .environment(\.appLanguage, model.appLanguage)
        .preferredColorScheme(model.themeMode.colorScheme)
        .task { await model.refreshUsageHistory() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menubar.content")
    }

    @ViewBuilder private var usageContent: some View {
        switch model.usageHistoryState {
        case .idle, .loading:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.appLanguage.localized("正在读取历史用量…"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.ccMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("menubar.usage.loading")
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Color.ccOrange)
                Text(model.appLanguage.localized("历史用量读取失败"))
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.ccCaption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Button(model.appLanguage.localized("重试")) {
                    Task { await model.refreshUsageHistory(invalidate: true) }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("menubar.usage.error")
        case .loaded:
            if let summary = model.usageHistorySummary(for: range) {
                switch section {
                case .overview: overview(summary)
                case .models: models(summary)
                }
            } else {
                Text(model.appLanguage.localized("历史用量暂不可用"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.ccMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("menubar.usage.unavailable")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            segmentedControl(
                Section.allCases,
                selection: $section,
                title: "内容",
                identifier: "menubar.section"
            ) { $0.title }

            Spacer(minLength: 8)

            segmentedControl(
                UsageRange.allCases,
                selection: $range,
                title: "用量范围",
                identifier: "menubar.range"
            ) { rangeLabel($0) }
        }
    }

    private func segmentedControl<Value: Identifiable & Equatable>(
        _ values: [Value],
        selection: Binding<Value>,
        title: String,
        identifier: String,
        label: @escaping (Value) -> String
    ) -> some View where Value.ID == String {
        HStack(spacing: 2) {
            ForEach(values) { item in
                let selected = selection.wrappedValue == item
                Button {
                    selection.wrappedValue = item
                } label: {
                    Text(model.appLanguage.localized(label(item)))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? Color.ccForeground : Color.ccMuted)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selected ? Color.ccElevated : .clear)
                                .shadow(
                                    color: selected ? Color.black.opacity(0.10) : .clear,
                                    radius: 1,
                                    y: 1
                                )
                        }
                        .overlay {
                            if selected {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(Color.ccBorderStrong.opacity(0.72), lineWidth: 0.75)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(MenuBarPressableButtonStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("\(identifier).\(item.id)")
            }
        }
        .padding(2)
        .background(Color.ccForeground.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.ccBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.appLanguage.localized(title))
        .accessibilityIdentifier(identifier)
    }

    private func rangeLabel(_ range: UsageRange) -> String {
        switch range {
        case .oneDay: "今日"
        case .sevenDays: "近 7 天"
        case .thirtyDays: "近 30 天"
        case .all: "全部"
        }
    }

    private func overview(_ summary: UsageHistorySummary) -> some View {
        VStack(spacing: MenuBarPopoverLayout.cardSpacing) {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: MenuBarPopoverLayout.cardSpacing),
                    count: 4
                ),
                spacing: MenuBarPopoverLayout.cardSpacing
            ) {
                usageCard(title: "用量", value: UsageFormat.compactTokens(summary.tokens))
                usageCard(title: "请求", value: UsageFormat.compactTokens(summary.requests))
                usageCard(title: "活跃天", value: UsageFormat.integer(summary.activeDays))
                usageCard(title: "服务", value: summary.favoriteProvider ?? "—", monospaced: false)
                usageCard(
                    title: "连续",
                    value: UsageFormat.integer(summary.currentStreak),
                    unit: model.appLanguage.localized("天")
                )
                usageCard(
                    title: "最长",
                    value: UsageFormat.integer(summary.longestStreak),
                    unit: model.appLanguage.localized("天")
                )
                usageCard(title: "峰值", value: hourLabel(summary.peakHour), monospaced: false)
                usageCard(title: "模型", value: summary.favoriteModel ?? "—", monospaced: false)
            }

            UsageHistoryHeatmapView(cells: summary.heatmap)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menubar.overview")
    }

    private func usageCard(
        title: String,
        value: String,
        unit: String? = nil,
        monospaced: Bool = true
    ) -> some View {
        let localizedTitle = model.appLanguage.localized(title)
        return VStack(alignment: .leading, spacing: 2) {
            Text(localizedTitle)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.3)
                .foregroundStyle(Color.ccCaption)
                .lineLimit(1)
            Group {
                if let unit {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(value)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                        Text(unit)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(Color.ccMuted)
                    }
                } else {
                    Text(value)
                        .font(.system(
                            size: monospaced ? 14 : 11,
                            weight: monospaced ? .bold : .semibold,
                            design: monospaced ? .monospaced : .default
                        ))
                        .monospacedDigit()
                }
            }
            .tracking(monospaced ? -0.14 : 0)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5.5)
        .frame(
            maxWidth: .infinity,
            minHeight: MenuBarPopoverLayout.cardHeight,
            maxHeight: MenuBarPopoverLayout.cardHeight,
            alignment: .leading
        )
        .background(Color.ccElevated)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.08), radius: 1.5, y: 1)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.ccBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.appLanguage.localized(
            "\(localizedTitle)，\(value)\(unit.map { " \($0)" } ?? "")"
        ))
    }

    private func models(_ summary: UsageHistorySummary) -> some View {
        Group {
            if summary.byModel.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Color.ccCaption)
                    Text(model.appLanguage.localized("暂无模型用量"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.ccMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(summary.byModel.prefix(12))) { item in
                            HStack(spacing: 8) {
                                Text(item.name)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .frame(width: 126, alignment: .leading)
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.ccForeground.opacity(0.055))
                                        Capsule()
                                            .fill(Color.ccBrandStrong)
                                            .frame(width: max(2, proxy.size.width * CGFloat(item.percentage)))
                                    }
                                }
                                .frame(height: 5)
                                Text(UsageFormat.compactTokens(item.tokens))
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.ccCaption)
                                    .frame(width: 50, alignment: .trailing)
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 34)
                            .background(Color.ccElevated.opacity(reduceTransparency ? 1 : 0.6))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(model.appLanguage.localized(
                                "\(item.name)，\(UsageFormat.integer(item.tokens)) Tokens"
                            ))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.ccBorder.opacity(0.9), lineWidth: 1)
                }
            }
        }
        .accessibilityIdentifier("menubar.models")
    }

    private func hourLabel(_ hour: Int?) -> String {
        guard let hour, (0...23).contains(hour) else { return "—" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = model.appLanguage.locale
        guard let date = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour))
        else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = model.appLanguage.locale
        formatter.setLocalizedDateFormatFromTemplate("j")
        return formatter.string(from: date)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.gatewayState.isRunning ? Color.ccGreen : Color.ccCaption)
                    .frame(width: 7, height: 7)
                Text(connectionLabel)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.ccMuted)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityConnectionLabel)
            .accessibilityIdentifier("menubar.connection")

            Spacer(minLength: 3)

            footerButton(
                model.appLanguage.localized(
                    model.gatewayState.isRunning ? "停止服务" : "启动服务"
                ),
                identifier: "menubar.gateway"
            ) {
                Task { await model.setGatewayEnabled(!model.gatewayState.isRunning) }
            }
            footerButton(
                model.appLanguage.localized("主界面"),
                identifier: "menubar.main",
                accessibilityTitle: model.appLanguage.localized("主窗口"),
                action: onShowMain
            )
            footerButton(
                model.appLanguage.localized("退出"),
                identifier: "menubar.quit",
                bordered: false,
                action: onQuit
            )
        }
    }

    private var connectionLabel: String {
        guard model.gatewayState.isRunning else {
            switch model.gatewayState {
            case .starting: return model.appLanguage.localized("网关启动中")
            case .failed: return model.appLanguage.localized("网关异常")
            case .stopped: return model.appLanguage.localized("已停止")
            case .running: return model.appLanguage.localized("运行中")
            }
        }
        return model.appLanguage.localized("运行中")
    }

    private var accessibilityConnectionLabel: String {
        guard model.gatewayState.isRunning else { return connectionLabel }
        return model.activeProvider.map {
            model.appLanguage.localized("网关运行中 · \($0.name)")
        } ?? model.appLanguage.localized("网关运行中")
    }

    private func footerButton(
        _ title: String,
        identifier: String,
        accessibilityTitle: String? = nil,
        bordered: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(bordered ? Color.ccForeground : Color.ccMuted)
                .padding(.horizontal, 9)
                .frame(height: 27)
                .background(bordered ? Color.ccElevated : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    if bordered {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.ccBorder, lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuBarPressableButtonStyle())
        .accessibilityLabel(accessibilityTitle ?? title)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var panelBackground: some View {
        let surface = colorScheme == .dark
            ? Color(red: 22 / 255, green: 23 / 255, blue: 28 / 255)
            : Color(red: 252 / 255, green: 252 / 255, blue: 254 / 255)
        if reduceTransparency {
            surface
        } else {
            Rectangle()
                .fill(.ultraThickMaterial)
                .overlay(surface.opacity(0.92))
        }
    }
}

private struct UsageHistoryHeatmapView: View {
    let cells: [UsageHistoryHeatmapCell]

    @Environment(\.appLanguage) private var appLanguage
    @Environment(\.colorScheme) private var colorScheme

    private let cellSize = MenuBarPopoverLayout.heatmapCellSize
    private let spacing = MenuBarPopoverLayout.heatmapSpacing

    var body: some View {
        LazyHGrid(
            rows: Array(
                repeating: GridItem(.fixed(cellSize), spacing: spacing),
                count: MenuBarPopoverLayout.heatmapRows
            ),
            spacing: spacing
        ) {
            ForEach(cells) { cell in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color(for: cell.level))
                    .frame(width: cellSize, height: cellSize)
                    .help(appLanguage.localized(
                        "\(cell.date) · \(UsageFormat.integer(cell.tokens)) Tokens"
                    ))
                    .accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: MenuBarPopoverLayout.heatmapHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(appLanguage.localized("26 周用量热力图"))
        .accessibilityValue(appLanguage.localized(
            "\(cells.filter { $0.tokens > 0 }.count) 个活跃日，"
                + "\(UsageFormat.integer(cells.reduce(0) { $0 + $1.tokens })) Tokens"
        ))
        .accessibilityIdentifier("menubar.heatmap")
    }

    private func color(for level: Int) -> Color {
        if colorScheme == .dark {
            let active = Color(red: 125 / 255, green: 122 / 255, blue: 255 / 255)
            switch level {
            case 1: return active.opacity(0.32)
            case 2: return active.opacity(0.54)
            case 3: return active.opacity(0.76)
            case 4...: return active
            default: return Color.white.opacity(0.14)
            }
        }
        switch level {
        case 1: return Color.ccBrand.opacity(0.34)
        case 2: return Color.ccBrand.opacity(0.55)
        case 3: return Color.ccBrand.opacity(0.76)
        case 4...: return Color.ccBrand
        default: return Color(red: 214 / 255, green: 209 / 255, blue: 196 / 255)
        }
    }
}

private struct MenuBarPressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
