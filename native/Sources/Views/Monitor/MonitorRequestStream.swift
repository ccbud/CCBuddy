import SwiftUI

struct MonitorRequestStream: View {
    @ObservedObject var store: MonitorStore
    @Environment(\.appLanguage) private var appLanguage
    let gatewayRunning: Bool
    let openDetail: (String) -> Void
    let requestClear: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            toolbar
            if let error = store.refreshError, !error.isEmpty {
                errorBanner(error)
            }
            stream
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("请求流")
                .font(.ccBody(.medium))
                .tracking(0.5)
                .foregroundStyle(Theme.mutedForeground)

            Spacer(minLength: 12)

            Text(streamHint)
                .font(.ccCaption())
                .foregroundStyle(Theme.mutedForeground)
                .lineLimit(1)

            Button(appLanguage.localized(store.isClearing ? "清除中" : "清空")) {
                requestClear()
            }
            .buttonStyle(.plain)
            .font(.ccCaption(.medium))
            .foregroundStyle(Theme.foreground)
            .padding(.horizontal, 9)
            .frame(height: 23)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.button).stroke(Theme.separator))
            .disabled(!gatewayRunning || store.isRefreshing || store.isClearing)
            .opacity(!gatewayRunning || store.isRefreshing || store.isClearing ? 0.5 : 1)
            .accessibilityIdentifier("monitor.clear")
        }
        .padding(.horizontal, 2)
    }

    private var streamHint: String {
        if !gatewayRunning { return appLanguage.localized("网关未运行") }
        if store.requests.isEmpty {
            return appLanguage.localized(store.isRefreshing ? "正在读取 Bifrost…" : "等待请求")
        }
        return appLanguage.localized("最近 \(store.requests.count) 条 · 每 10 秒自动刷新")
    }

    @ViewBuilder private var stream: some View {
        if store.requests.isEmpty {
            Text(appLanguage.localized(
                gatewayRunning
                    ? "接入网关后，转发记录将实时显示"
                    : "启动网关以读取请求记录"
            ))
                .font(.ccCaption())
                .foregroundStyle(Theme.mutedForeground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).stroke(Theme.separator))
        } else {
            LazyVStack(spacing: 0) {
                ForEach(store.requests) { request in
                    MonitorRequestRow(
                        request: request,
                        selected: store.detailRequestID == request.id,
                        loadingDetail: store.isLoadingDetail && store.detailRequestID == request.id,
                        action: { openDetail(request.id) }
                    )
                    if request.id != store.requests.last?.id {
                        Rectangle().fill(Theme.separator).frame(height: 1)
                    }
                }
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).stroke(Theme.separator))
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            Text(appLanguage.localized(message))
                .font(.ccCaption())
                .foregroundStyle(Theme.mutedForeground)
                .lineLimit(2)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .stroke(Theme.warning.opacity(0.22))
        }
        .accessibilityLabel(appLanguage.localized("刷新失败：\(message)"))
    }
}

private struct MonitorRequestRow: View {
    @Environment(\.appLanguage) private var appLanguage

    let request: BifrostLog
    let selected: Bool
    let loadingDetail: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Circle()
                    .fill(request.status.monitorColor)
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(requestedModelLabel)
                            .foregroundStyle(Theme.foreground)
                            .lineLimit(1)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.accentText.opacity(0.62))
                        Text(outgoingModelLabel)
                            .foregroundStyle(Theme.mutedForeground)
                            .lineLimit(1)
                    }
                    .font(.ccMono(Typography.caption, weight: .medium))
                    HStack(spacing: 5) {
                        if let object = request.object, !object.isEmpty {
                            Text(object)
                        }
                        Text(String(request.id.prefix(8)))
                    }
                    .font(.ccMono(Typography.label))
                    .foregroundStyle(Theme.mutedForeground)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(request.displayProvider.isEmpty ? "—" : request.displayProvider)
                    .font(.ccLabel())
                    .foregroundStyle(Theme.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 92, alignment: .trailing)

                Text(MonitorFormat.compactCost(request.cost) ?? "")
                    .font(.ccMono(Typography.label))
                    .foregroundStyle(Theme.mutedForeground)
                    .frame(width: 52, alignment: .trailing)

                Text(rowStatusLabel)
                    .font(.ccLabel(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .foregroundStyle(request.status.monitorColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(request.status.monitorBackground)
                    .clipShape(Capsule())
                    .frame(width: 76)

                Text("\(MonitorFormat.milliseconds(request.latency)) ms")
                    .font(.ccMono(Typography.label))
                    .foregroundStyle(Theme.mutedForeground)
                    .frame(width: 68, alignment: .trailing)

                Text(MonitorFormat.clock(request.monitorTimestamp))
                    .font(.ccMono(Typography.label))
                    .foregroundStyle(Theme.mutedForeground)
                    .frame(width: 56, alignment: .trailing)

                if loadingDetail {
                    ProgressView().controlSize(.small).frame(width: 12)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.mutedForeground)
                        .frame(width: 12)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(MonitorPressableButtonStyle())
        .onHover { hovering = $0 }
        .help(appLanguage.localized("查看 Bifrost 保存的规范化内容与上游原始正文"))
        .accessibilityLabel(requestAccessibilityLabel)
        .accessibilityIdentifier("monitor.request.\(request.id)")
    }

    private var rowBackground: Color {
        if selected { return Theme.accentSoft.opacity(0.72) }
        if hovering { return Theme.foreground.opacity(0.035) }
        return .clear
    }

    private var rowStatusLabel: String {
        if request.isError, let code = request.errorStatusCode { return "HTTP \(code)" }
        return request.status.monitorLabel(language: appLanguage)
    }

    private var rowStatusAccessibility: String {
        if request.isError, let code = request.errorStatusCode {
            return appLanguage.localized("错误，真实上游 HTTP 状态码 \(code)")
        }
        return request.status.monitorLabel(language: appLanguage)
    }

    private var requestedModelLabel: String {
        request.requestedModel.isEmpty
            ? appLanguage.localized("未标注模型")
            : request.requestedModel
    }

    private var outgoingModelLabel: String {
        request.outgoingModel.isEmpty
            ? appLanguage.localized("未标注模型")
            : request.outgoingModel
    }

    private var requestAccessibilityLabel: String {
        let provider = request.displayProvider.isEmpty ? "—" : request.displayProvider
        let latency = MonitorFormat.milliseconds(request.latency)
        return appLanguage.localized(
            "请求模型 \(requestedModelLabel)，上游模型 \(outgoingModelLabel)，\(provider)，\(rowStatusAccessibility)，耗时 \(latency) 毫秒"
        )
    }
}
