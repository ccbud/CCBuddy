import SwiftUI

struct MonitorDetailDrawer: View {
    @ObservedObject var store: MonitorStore
    @Binding var revealsSensitiveData: Bool
    let upstreamProtocol: Provider.WireProtocol?
    let width: CGFloat
    let expanded: Bool
    let toggleExpanded: () -> Void
    let close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appLanguage) private var appLanguage
    @State private var section: MonitorDetailSection = .request
    @State private var presentation: MonitorPayloadPresentation = .pretty
    @State private var copied = false
    @State private var searchQuery = ""
    @State private var search = MonitorPayloadSearchState()

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.separator).frame(height: 1)

            if let detail = store.selectedDetail {
                let document = MonitorInspectorDocument(
                    log: detail,
                    upstreamProtocol: upstreamProtocol
                )
                meta(for: detail, document: document)
                Rectangle().fill(Theme.separator).frame(height: 1)
                tabs(document)
                Rectangle().fill(Theme.separator).frame(height: 1)
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
        .overlay(alignment: .leading) { Rectangle().fill(Theme.separator).frame(width: 1) }
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
        .accessibilityContainerIdentifier(
            "monitor.detail.drawer",
            label: appLanguage.localized("请求详情")
        )
    }

    private var header: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text("请求详情")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.foreground)
                if let id = store.detailRequestID {
                    Text(id)
                        .font(.ccMono(Typography.label))
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if let record = headerRecord {
                Text(headerStatus(for: record))
                    .font(.ccLabel(.medium))
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
                .foregroundStyle(Theme.mutedForeground)
                .frame(width: 28, height: 28)
                .background(Theme.surface.opacity(0.86))
                .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.button).stroke(Theme.separator))
        }
        .buttonStyle(MonitorPressableButtonStyle())
        .help(localizedHelp)
        .accessibilityLabel(localizedHelp)
        .accessibilityIdentifier(identifier)
    }

    private var headerRecord: BifrostLog? {
        if let detail = store.selectedDetail { return detail }
        guard let id = store.detailRequestID else { return nil }
        return store.requests.first { $0.id == id }
    }

    private func meta(for detail: BifrostLog, document: MonitorInspectorDocument) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(
                    label: "模型",
                    value: "\(detail.requestedModel.isEmpty ? "—" : detail.requestedModel) → \(detail.outgoingModel.isEmpty ? "—" : detail.outgoingModel)"
                )
                chip(label: "Provider", value: detail.displayProvider.isEmpty ? "—" : detail.displayProvider)
                if let translationLabel = document.protocolDisposition.translationLabel {
                    chip(label: "协议转换", value: translationLabel)
                }
                if additionalBool("aborted", in: detail) == true {
                    chip(label: "已中断", value: appLanguage.localized("客户端中途断开"))
                }
                chip(label: "耗时", value: "\(MonitorFormat.milliseconds(detail.latency)) ms")
                if let sessionID = additionalString(["session_id", "sessionId"], in: detail) {
                    chip(label: "会话", value: String(sessionID.prefix(8)))
                }
                if additionalString(["agent_id", "agentId"], in: detail) != nil {
                    chip(label: "代理", value: appLanguage.localized("子代理"))
                }
                chip(label: "时间", value: MonitorFormat.timestamp(detail.monitorTimestamp))
                if detail.stream == true {
                    chip(label: "模式", value: appLanguage.localized("流式"))
                }
                if detail.isError, let code = detail.errorStatusCode {
                    chip(label: "真实上游 HTTP", value: String(code))
                }
                if let cost = MonitorFormat.compactCost(detail.cost) {
                    chip(label: "成本", value: cost)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
    }

    private func chip(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(appLanguage.localized(label)).foregroundStyle(Theme.mutedForeground)
            Text(value).foregroundStyle(Theme.foreground)
        }
        .font(.ccMono(Typography.label))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.foreground.opacity(0.052))
        .clipShape(Capsule())
    }

    private func headerStatus(for record: BifrostLog) -> String {
        if record.isError, let code = record.errorStatusCode {
            return appLanguage.localized("Bifrost · 错误 · 上游 HTTP \(code)")
        }
        let status = record.status.monitorLabel(language: appLanguage)
        return appLanguage.localized("Bifrost · \(status)")
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
                                .foregroundStyle(activeSection(in: document) == item ? Theme.accentText : Theme.mutedForeground)
                            Rectangle()
                                .fill(activeSection(in: document) == item ? Theme.accentText : Color.clear)
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
        .background(Theme.surface.opacity(0.32))
    }

    @ViewBuilder
    private func payloadBody(_ detail: BifrostLog, document: MonitorInspectorDocument) -> some View {
        let selectedSection = activeSection(in: document)
        let payload = document.payload(for: selectedSection)
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(appLanguage.localized(selectedSection.title))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.foreground)
                        if let payload {
                            Text(appLanguage.localized(
                                payload.isTruncated
                                    ? "截断预览"
                                    : (payload.source == .capturedRaw ? "捕获原文" : "规范化 JSON")
                            ))
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Theme.mutedForeground)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.foreground.opacity(0.05))
                                .clipShape(Capsule())
                        }
                    }
                    Text(appLanguage.localized(selectedSection.explanation))
                        .font(.ccLabel())
                        .foregroundStyle(selectedSection.isProviderWirePayload ? Theme.accentText : Theme.mutedForeground)
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
                        .foregroundStyle(Theme.warning)
                        .accessibilityIdentifier("monitor.detail.truncation")
                }

                searchBar

                MonitorPayloadTextView(text: visibleText(payload), search: search)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.fill.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.row).stroke(Theme.separator))
                    .privacySensitive()
                    .accessibilityIdentifier("monitor.detail.payload")
            } else {
                VStack(spacing: 7) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(Theme.mutedForeground)
                    Text("Bifrost 未保存此字段")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.mutedForeground)
                    Text("界面不会从其他字段猜测或拼装内容")
                        .font(.ccLabel())
                        .foregroundStyle(Theme.mutedForeground)
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
                        .foregroundStyle(presentation == item ? Theme.foreground : Theme.mutedForeground)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(presentation == item ? Theme.foreground.opacity(0.07) : Color.clear)
                }
                .buttonStyle(MonitorPressableButtonStyle())
                .accessibilityIdentifier("monitor.detail.presentation.\(item.rawValue)")
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.button).stroke(Theme.separator))
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
                .font(.ccLabel(.medium))
                .foregroundStyle(copied ? Theme.success : Theme.mutedForeground)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.button).stroke(Theme.separator))
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
                .font(.ccMono(Typography.label))
                .foregroundStyle(Theme.mutedForeground)
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
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.keyboard, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.keyboard).stroke(Theme.separator))
        }
        .buttonStyle(MonitorPressableButtonStyle())
        .disabled(search.matches.isEmpty)
        .help(localizedLabel)
        .accessibilityLabel(localizedLabel)
        .accessibilityIdentifier("monitor.detail.search.\(offset < 0 ? "previous" : "next")")
    }

    private var sourceNotice: some View {
        Label {
            Text("来源为 Bifrost 管理 API。原文复制保留 Bifrost 捕获的正文；规范化标签的“原文”是无缩进 JSON。管理 API 未提供的 headers、URL 或成功 HTTP 状态不会被推断。")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.shield")
        }
        .font(.system(size: 9.5))
        .foregroundStyle(Theme.mutedForeground)
        .padding(.top, 1)
    }

    private var loadingBody: some View {
        VStack(spacing: 11) {
            ProgressView().controlSize(.small)
            Text("正在读取 Bifrost 请求详情…")
                .font(.ccCaption())
                .foregroundStyle(Theme.mutedForeground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorBody: some View {
        VStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 21, weight: .light))
                .foregroundStyle(Theme.warning)
            Text("无法读取详情")
                .font(.ccBody(.medium))
            Text(appLanguage.localized(
                store.detailError ?? "这条记录可能已从 Bifrost 日志中清除"
            ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var selectedVisibleText: String? {
        guard let detail = store.selectedDetail else { return nil }
        let document = MonitorInspectorDocument(
            log: detail,
            upstreamProtocol: upstreamProtocol
        )
        guard let payload = document.payload(for: activeSection(in: document)) else { return nil }
        return visibleText(payload)
    }

    private func activeSection(in document: MonitorInspectorDocument) -> MonitorDetailSection {
        document.sections.contains(section) ? section : (document.sections.first ?? .request)
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
        section = .request
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
        return "Bifrost 仅提供截断预览（原始总大小未知）"
    }

    private func sectionAccessibilityLabel(_ section: MonitorDetailSection) -> String {
        let title = appLanguage.localized(section.title)
        let explanation = appLanguage.localized(section.explanation)
        return appLanguage.localized("\(title)：\(explanation)")
    }

    private func additionalString(_ names: [String], in detail: BifrostLog) -> String? {
        for name in names {
            guard let value = detail.additionalFields[name] else { continue }
            if case .string(let string) = value,
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return string
            }
        }
        return nil
    }

    private func additionalBool(_ name: String, in detail: BifrostLog) -> Bool? {
        guard let value = detail.additionalFields[name] else { return nil }
        switch value {
        case .bool(let bool): return bool
        case .number(let number): return number != 0
        case .string(let string): return ["true", "yes", "1"].contains(string.lowercased())
        default: return nil
        }
    }
}
