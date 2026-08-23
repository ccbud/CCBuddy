import SwiftUI

@MainActor
struct MonitorView: View {
    @StateObject private var store: MonitorStore
    private let port: Int
    private let gatewayRunning: Bool
    private let activeProvider: Provider?
    private let injectedLifecycleEvents: [MonitorLifecycleEvent]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appLanguage) private var appLanguage
    @State private var showingClearConfirmation = false
    @State private var revealsSensitiveData = false
    @State private var detailExpanded = false

    /// Preferred integration path. Keeping the store above the view lets AppModel collect gateway
    /// lifecycle events even before the user opens Monitor.
    init(
        store: MonitorStore,
        port: Int,
        gatewayRunning: Bool,
        activeProvider: Provider?,
        lifecycleEvents: [MonitorLifecycleEvent] = []
    ) {
        _store = StateObject(wrappedValue: store)
        self.port = port
        self.gatewayRunning = gatewayRunning
        self.activeProvider = activeProvider
        injectedLifecycleEvents = lifecycleEvents
    }

    /// Convenience injection for previews, focused UI tests, and other callers that do not need
    /// to retain lifecycle history while Monitor is off-screen.
    init(
        client: BifrostManagementClient,
        port: Int,
        gatewayRunning: Bool,
        activeProvider: Provider?,
        lifecycleEvents: [MonitorLifecycleEvent] = []
    ) {
        self.init(
            store: MonitorStore(client: client),
            port: port,
            gatewayRunning: gatewayRunning,
            activeProvider: activeProvider,
            lifecycleEvents: lifecycleEvents
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .trailing) {
                content
                    .allowsHitTesting(store.detailRequestID == nil)

                if store.detailRequestID != nil {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { closeDetail() }
                        .transition(.opacity)
                        .accessibilityHidden(true)

                    MonitorDetailDrawer(
                        store: store,
                        revealsSensitiveData: $revealsSensitiveData,
                        upstreamProtocol: activeProvider?.protocol,
                        width: detailExpanded
                            ? proxy.size.width
                            : min(640, max(480, proxy.size.width * 0.82)),
                        expanded: detailExpanded,
                        toggleExpanded: { toggleDetailExpanded() },
                        close: closeDetail
                    )
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .trailing).combined(with: .opacity)
                    )
                }
            }
            .animation(drawerAnimation, value: store.detailRequestID)
        }
        .task(id: MonitorRuntimeKey(port: port, gatewayRunning: gatewayRunning)) {
            store.configure(port: port, gatewayRunning: gatewayRunning)
        }
        .onAppear { store.ingestLifecycle(injectedLifecycleEvents) }
        .onChange(of: injectedLifecycleEvents) { store.ingestLifecycle($0) }
        .onDisappear {
            store.stopPolling()
            store.dismissDetail()
            detailExpanded = false
            revealsSensitiveData = false
        }
        .confirmationDialog(
            "清除监控日志？",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("永久清除", role: .destructive) {
                Task { _ = await store.clearAllLogs() }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将从 Bifrost 永久删除当前时间前的全部请求日志，并清除本机内存中的生命周期记录。清除期间产生的新请求会保留。")
        }
        .background(Color.ccAppBackground)
        .monitorAccessibilityContainerIdentifier(
            "view.monitor",
            label: appLanguage.localized("监控")
        )
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 24) {
                if revealsSensitiveData {
                    revealedDataWarning
                }
                metricGrid
                MonitorRequestStream(
                    store: store,
                    gatewayRunning: gatewayRunning,
                    openDetail: openDetail,
                    requestClear: { showingClearConfirmation = true }
                )
                MonitorLifecycleLog(
                    store: store,
                    port: port,
                    gatewayRunning: gatewayRunning,
                    revealsSensitiveData: revealsSensitiveData
                )
            }
            .frame(maxWidth: 1120)
            .padding(.horizontal, 40)
            .padding(.top, 16)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
    }

    /// The overview stays redacted by default, matching the legacy monitor's restrained hierarchy.
    /// Raw values can be revealed from the request drawer where they have context. If the drawer is
    /// then closed, this warning remains as an explicit, reversible escape hatch until page exit.
    private var revealedDataWarning: some View {
        HStack(spacing: 9) {
            Image(systemName: "eye")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.ccOrange)
            Text(appLanguage.localized("正在显示未经脱敏的监控内容；关闭页面后会自动恢复保护"))
            .font(.system(size: 11))
            .foregroundStyle(Color.ccCaption)
            Spacer(minLength: 10)
            MonitorActionButton(
                title: "隐藏敏感值",
                symbol: "eye.slash"
            ) {
                revealsSensitiveData = false
            }
            .accessibilityIdentifier("monitor.privacy.toggle")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color.ccElevated)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.ccBorder))
    }

    private var metricGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 120), spacing: 14), count: 4),
            spacing: 14
        ) {
            MonitorMetricCard(
                title: "网关",
                value: appLanguage.localized(gatewayRunning ? "已接入" : "未接入"),
                subtitle: "localhost:\(port)",
                accent: gatewayRunning ? .ccForeground : .ccMuted,
                showsStatusDot: true,
                statusActive: gatewayRunning
            )
            .accessibilityIdentifier("monitor.metric.gateway")

            MonitorMetricCard(
                title: "活跃服务",
                value: activeProvider?.name ?? "—",
                subtitle: activeProvider.map {
                    revealsSensitiveData
                        ? $0.baseUrl
                        : MonitorPrivacyRedactor.redact($0.baseUrl, language: appLanguage)
                } ?? appLanguage.localized("未选择服务"),
                accent: .ccForeground,
                subtitlePrivacySensitive: true
            )
            .accessibilityIdentifier("monitor.metric.provider")

            MonitorMetricCard(
                title: "总请求",
                value: MonitorFormat.integer(totalRequests, locale: appLanguage.locale),
                unit: nil,
                subtitle: appLanguage.localized(
                    "成功率 \(MonitorFormat.percent(store.stats?.rootSuccessRate))"
                ),
                accent: .ccForeground,
                prominentNumber: true
            )
            .accessibilityIdentifier("monitor.metric.total")

            MonitorMetricCard(
                title: "平均耗时",
                value: MonitorFormat.milliseconds(averageLatency),
                unit: "ms",
                subtitle: latestRequestText,
                accent: .ccForeground,
                prominentNumber: true
            )
            .accessibilityIdentifier("monitor.metric.latency")
        }
    }

    private var totalRequests: Int {
        store.stats?.rootRequestCount ?? store.requests.count
    }

    private var averageLatency: Double? {
        if let average = store.stats?.averageLatency { return average }
        let values = store.requests.compactMap(\.latency)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var latestRequestText: String {
        guard let date = store.requests.first?.monitorTimestamp, date != .distantPast else {
            return store.lastUpdatedAt.map {
                appLanguage.localized("刷新于 \(MonitorFormat.clock($0))")
            } ?? appLanguage.localized("最近 —")
        }
        return appLanguage.localized("最近 \(MonitorFormat.clock(date))")
    }

    private var drawerAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.15)
            : .interactiveSpring(response: 0.32, dampingFraction: 0.9, blendDuration: 0.08)
    }

    private func openDetail(_ id: String) {
        detailExpanded = false
        Task { await store.loadDetail(id: id) }
    }

    private func closeDetail() {
        detailExpanded = false
        if reduceMotion {
            store.dismissDetail()
        } else {
            withAnimation(drawerAnimation) { store.dismissDetail() }
        }
    }

    private func toggleDetailExpanded() {
        if reduceMotion {
            detailExpanded.toggle()
        } else {
            withAnimation(drawerAnimation) { detailExpanded.toggle() }
        }
    }
}
