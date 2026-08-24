import SwiftUI

struct MonitorDetailDrawer: View {
    @ObservedObject var store: MonitorStore
    @Binding var revealsSensitiveData: Bool
    let width: CGFloat
    let expanded: Bool
    let toggleExpanded: () -> Void
    let close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appLanguage) private var appLanguage
    @State private var section: MonitorDetailSection = .clientRequest
    @State private var presentation: MonitorPayloadPresentation = .pretty
    @State private var copied = false
    @State private var searchQuery = ""
    @State private var search = MonitorPayloadSearchState()

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.ccBorder).frame(height: 1)

            if let detail = store.selectedDetail {
                let document = MonitorInspectorDocument(log: detail)
                meta(for: detail, document: document)
                Rectangle().fill(Color.ccBorder).frame(height: 1)
                tabs(document)
                Rectangle().fill(Color.ccBorder).frame(height: 1)
                payloadBody(detail, document: document)
            } else if store.isLoadingDetail {
                loadingBody
            } else {
                errorBody
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(MonitorMaterialBackground())
        .overlay(alignment: .leading) { Rectangle().fill(Color.ccBorder).frame(width: 1) }
        .shadow(color: .black.opacity(0.18), radius: 30, x: -10)
        .onChange(of: store.detailRequestID) { _ in resetInspector() }
        .onChange(of: presentation) { _ in refreshSearch() }
        .onChange(of: revealsSensitiveData) { _ in
            copied = false
            refreshSearch()
        }
        .onChange(of: appLanguage) { _ in
            copied = false
            refreshSearch()
        }
        .onChange(of: searchQuery) { _ in refreshSearch() }
        .monitorAccessibilityContainerIdentifier(
            "monitor.detail.drawer",
            label: appLanguage.localized("请求详情")
        )
    }

    private var header: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text("请求详情")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ccForeground)
                if let id = store.detailRequestID {
                    Text(id)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color.ccCaption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if let record = headerRecord {
                Text(headerStatus(for: record))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(record.status.monitorColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(record.status.monitorBackground)
                    .clipShape(Capsule())
            }

            headerButton(
                symbol: revealsSensitiveData ? "eye" : "eye.slash",
                help: revealsSensitiveData ? "隐藏敏感值" : "显示未经脱敏的原文",
                identifier: "monitor.detail.privacy"
            ) {
                revealsSensitiveData.toggle()
            }

            headerButton(
                symbol: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                help: expanded ? "恢复抽屉宽度" : "展开详情",
                identifier: "monitor.detail.expand",
                action: toggleExpanded
            )

            headerButton(
                symbol: "xmark",
                help: "关闭详情",
                identifier: "monitor.detail.close",
                action: close
            )
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 14)
    }

    private func headerButton(
        symbol: String,
        help: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        let localizedHelp = appLanguage.localized(help)
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.ccMuted)
                .frame(width: 28, height: 28)
                .background(Color.ccElevated.opacity(0.86))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.ccBorder))
        }
        .buttonStyle(MonitorPressableButtonStyle())
        .help(localizedHelp)
        .accessibilityLabel(localizedHelp)
        .accessibilityIdentifier(identifier)
    }

    private var headerRecord: GatewayLog? {
        if let detail = store.selectedDetail { return detail }
        guard let id = store.detailRequestID else { return nil }
        return store.requests.first { $0.id == id }
    }

    private func meta(for detail: GatewayLog, document: MonitorInspectorDocument) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(
                    label: "模型",
                    value: modelRouteLabel(detail)
                )
                chip(label: "Provider", value: detail.displayProvider.isEmpty ? "—" : detail.displayProvider)
                if let translationLabel = document.protocolDisposition.translationLabel {
                    chip(label: "协议转换", value: translationLabel)
                }
                if !detail.routeLabel.isEmpty { chip(label: "路由", value: detail.routeLabel) }
                if detail.attempts > 0 { chip(label: "尝试", value: String(detail.attempts)) }
                chip(label: "耗时", value: "\(MonitorFormat.milliseconds(detail.latency)) ms")
                chip(label: "时间", value: MonitorFormat.timestamp(detail.monitorTimestamp))
                if detail.stream == true {
                    chip(label: "模式", value: appLanguage.localized("流式"))
                }
                if detail.isError, let code = detail.errorStatusCode {
                    chip(label: "真实上游 HTTP", value: String(code))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
    }

    private func chip(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(appLanguage.localized(label)).foregroundStyle(Color.ccCaption)
            Text(value).foregroundStyle(Color.ccForeground)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.ccForeground.opacity(0.052))
        .clipShape(Capsule())
    }

    private func headerStatus(for record: GatewayLog) -> String {
        if record.isError, let code = record.errorStatusCode {
            return appLanguage.localized("网关 · 错误 · 上游 HTTP \(code)")
        }
        let status = record.status.monitorLabel(language: appLanguage)
        return appLanguage.localized("网关 · \(status)")
    }

    private func tabs(_ document: MonitorInspectorDocument) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(document.sections) { item in
                    Button {
                        select(item)
                    } label: {
                        VStack(spacing: 6) {
                            Text(appLanguage.localized(item.shortTitle))
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(activeSection(in: document) == item ? Color.ccBrandStrong : Color.ccMuted)
                            Rectangle()
                                .fill(activeSection(in: document) == item ? Color.ccBrandStrong : Color.clear)
                                .frame(height: 2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MonitorPressableButtonStyle())
                    .help(appLanguage.localized(item.title))
                    .accessibilityLabel(sectionAccessibilityLabel(item))
                    .accessibilityIdentifier("monitor.detail.tab.\(item.rawValue)")
                }
            }
            .padding(.horizontal, 7)
        }
        .background(Color.ccElevated.opacity(0.32))
    }

    @ViewBuilder
    private func payloadBody(_ detail: GatewayLog, document: MonitorInspectorDocument) -> some View {
        let selectedSection = activeSection(in: document)
        let payload = document.payload(for: selectedSection)
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(appLanguage.localized(selectedSection.title))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.ccForeground)
                        if let payload {
                            Text(appLanguage.localized(
                                payload.isTruncated
                                    ? "截断预览"
                                    : "捕获内容"
                            ))
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Color.ccCaption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.ccForeground.opacity(0.05))
                                .clipShape(Capsule())
                        }
                    }
                    Text(appLanguage.localized(selectedSection.explanation))
                        .font(.system(size: 10.5))
                        .foregroundStyle(selectedSection.isProviderWirePayload ? Color.ccBrandStrong : Color.ccCaption)
                }
                Spacer(minLength: 8)
                if let payload {
                    presentationControl
                    copyButton(payload)
                }
            }

            if let payload {
                if payload.copyIsPartial {
                    Text(appLanguage.localized(truncationNotice(for: payload)))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.ccOrange)
                        .accessibilityIdentifier("monitor.detail.truncation")
                }

                searchBar

                MonitorPayloadTextView(text: visibleText(payload), search: search)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.ccInput.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.ccBorder))
                    .privacySensitive()
                    .accessibilityIdentifier("monitor.detail.payload")
            } else {
                VStack(spacing: 7) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(Color.ccCaption)
                    Text("网关未捕获此字段")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.ccMuted)
                    Text("界面不会从其他字段猜测或拼装内容")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.ccCaption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            sourceNotice
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var presentationControl: some View {
        HStack(spacing: 0) {
            ForEach(MonitorPayloadPresentation.allCases) { item in
                Button {
                    presentation = item
                    copied = false
                } label: {
                    Text(appLanguage.localized(item.title))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(presentation == item ? Color.ccForeground : Color.ccCaption)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(presentation == item ? Color.ccForeground.opacity(0.07) : Color.clear)
                }
                .buttonStyle(MonitorPressableButtonStyle())
                .accessibilityIdentifier("monitor.detail.presentation.\(item.rawValue)")
            }
        }
        .background(Color.ccElevated)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.ccBorder))
    }

    private func copyButton(_ payload: MonitorInspectorPayload) -> some View {
        Button {
            let original = payload.rawText
            MonitorFormat.copyToPasteboard(
                revealsSensitiveData
                    ? original
                    : MonitorPrivacyRedactor.redact(original, language: appLanguage)
            )
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
        } label: {
            Label(copyLabel(for: payload), systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(copied ? Color.ccGreen : Color.ccMuted)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Color.ccElevated)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.ccBorder))
        }
        .buttonStyle(MonitorPressableButtonStyle())
        .help("复制当前标签的原始正文")
        .accessibilityIdentifier("monitor.detail.copy")
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            MonitorPayloadSearchField(
                text: $searchQuery,
                placeholder: appLanguage.localized("搜索正文…"),
                next: { search.move(by: 1) },
                previous: { search.move(by: -1) },
                clear: { search.update(query: "", in: selectedVisibleText ?? "") }
            )
            .frame(width: 158, height: 24)

            Text(search.countLabel)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Color.ccCaption)
                .frame(width: 46)
                .accessibilityIdentifier("monitor.detail.search.count")

            searchButton(symbol: "arrow.up", label: "上一个", offset: -1)
            searchButton(symbol: "arrow.down", label: "下一个", offset: 1)
        }
    }

    private func searchButton(symbol: String, label: String, offset: Int) -> some View {
        let localizedLabel = appLanguage.localized(label)
        return Button { search.move(by: offset) } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Color.ccElevated)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.ccBorder))
        }
        .buttonStyle(MonitorPressableButtonStyle())
        .disabled(search.matches.isEmpty)
        .help(localizedLabel)
        .accessibilityLabel(localizedLabel)
        .accessibilityIdentifier("monitor.detail.search.\(offset < 0 ? "previous" : "next")")
    }

    private var sourceNotice: some View {
        Label {
            Text("来源为本机网关管理 API。四个标签分别对应真实捕获边界，包含已脱敏 headers、正文和截断标记；未提供的内容不会被推断。")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.shield")
        }
        .font(.system(size: 9.5))
        .foregroundStyle(Color.ccCaption)
        .padding(.top, 1)
    }

    private var loadingBody: some View {
        VStack(spacing: 11) {
            ProgressView().controlSize(.small)
            Text("正在读取网关请求详情…")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ccMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorBody: some View {
        VStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 21, weight: .light))
                .foregroundStyle(Color.ccOrange)
            Text("无法读取详情")
                .font(.system(size: 12.5, weight: .semibold))
            Text(appLanguage.localized(
                store.detailError ?? "这条记录可能已从网关日志中清除"
            ))
                .font(.system(size: 11))
                .foregroundStyle(Color.ccCaption)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var selectedVisibleText: String? {
        guard let detail = store.selectedDetail else { return nil }
        let document = MonitorInspectorDocument(log: detail)
        guard let payload = document.payload(for: activeSection(in: document)) else { return nil }
        return visibleText(payload)
    }

    private func activeSection(in document: MonitorInspectorDocument) -> MonitorDetailSection {
        document.sections.contains(section) ? section : (document.sections.first ?? .clientRequest)
    }

    private func visibleText(_ payload: MonitorInspectorPayload) -> String {
        let value = payload.text(for: presentation)
        return revealsSensitiveData
            ? value
            : MonitorPrivacyRedactor.redact(value, language: appLanguage)
    }

    private func select(_ item: MonitorDetailSection) {
        let update = {
            section = item
            copied = false
            searchQuery = ""
            search.update(query: "", in: "")
        }
        if reduceMotion { update() }
        else { withAnimation(.easeOut(duration: 0.14), update) }
    }

    private func resetInspector() {
        section = .clientRequest
        presentation = .pretty
        copied = false
        searchQuery = ""
        search = MonitorPayloadSearchState()
    }

    private func refreshSearch() {
        search.update(query: searchQuery, in: selectedVisibleText ?? "")
    }

    private func copyLabel(for payload: MonitorInspectorPayload) -> String {
        if copied { return appLanguage.localized("已复制") }
        if payload.copyIsPartial {
            return appLanguage.localized(
                revealsSensitiveData ? "复制（部分）" : "复制脱敏内容（部分）"
            )
        }
        return appLanguage.localized(revealsSensitiveData ? "复制原文" : "复制脱敏内容")
    }

    private func formattedBytes(_ value: Int) -> String {
        Int64(value).formatted(
            .byteCount(style: .file).locale(appLanguage.locale)
        )
    }

    private func truncationNotice(for payload: MonitorInspectorPayload) -> String {
        if let totalBytes = payload.totalBytes {
            return "仅显示前 \(formattedBytes(payload.shownBytes)) / 共 \(formattedBytes(totalBytes))（已截断）"
        }
        return "网关仅提供截断预览（原始总大小未知）"
    }

    private func sectionAccessibilityLabel(_ section: MonitorDetailSection) -> String {
        let title = appLanguage.localized(section.title)
        let explanation = appLanguage.localized(section.explanation)
        return appLanguage.localized("\(title)：\(explanation)")
    }

    private func modelRouteLabel(_ detail: GatewayLog) -> String {
        let requested = detail.requestedModel.isEmpty ? "—" : detail.requestedModel
        let outgoing = detail.outgoingModel.isEmpty ? "—" : detail.outgoingModel
        return requested == outgoing ? requested : "\(requested) → \(outgoing)"
    }
}
