import SwiftUI

struct ConversationOverviewPane: View {
    @ObservedObject var store: ConversationStore
    @Environment(\.appLanguage) private var appLanguage
    let collapsed: Bool
    let toggleCollapsed: () -> Void

    var body: some View {
        Group {
            if collapsed {
                Button(action: toggleCollapsed) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.ccMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ConversationPressableButtonStyle())
                .help(appLanguage.localized("展开会话概览"))
                .accessibilityLabel(appLanguage.localized("展开会话概览"))
                .accessibilityIdentifier("conversation.overview.expand")
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Spacer(minLength: 0)
                        Button(action: toggleCollapsed) {
                            ConversationWorkbenchIcon(.chevronRight, size: 12)
                        }
                        .buttonStyle(ConversationToolButtonStyle())
                        .help(appLanguage.localized("收起会话概览"))
                        .accessibilityLabel(appLanguage.localized("收起会话概览"))
                        .accessibilityIdentifier("conversation.overview.collapse")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 40)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.ccBorder).frame(height: 1) }

                    if let session = store.activeTranscript {
                        overview(session)
                    } else {
                        overviewLoadingState
                    }
                }
            }
        }
        .background(Color.ccConversationSurface)
        .accessibilityIdentifier("conversation.overview")
    }

    private func overview(_ session: HistorySession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeading("概览")
            VStack(spacing: 0) {
                ForEach(Array(statRows(session).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(appLanguage.localized(row.0))
                            .foregroundStyle(Color.ccCaption)
                        Spacer(minLength: 4)
                        Text(row.1)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color.ccForeground)
                            .lineLimit(1)
                            .help(row.1)
                    }
                    .font(.system(size: 11))
                    .padding(.vertical, 4.5)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.ccBorder).frame(height: 1) }
                }

                if !session.metadata.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("标签")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.ccCaption)
                        FlexibleOverviewTags(tags: session.metadata.tags)
                    }
                    .padding(.vertical, 7)
                }
            }
            .padding(.horizontal, 12)

            railHeading("导航")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    let entries = tableOfContents(session.messages)
                    if entries.isEmpty {
                        Text("没有用户消息可供导航")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.ccCaption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                    } else {
                        ForEach(entries, id: \.index) { entry in
                            Button { store.jump(to: entry.index) } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 8))
                                    Text(entry.title)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(Color.ccCaption)
                                .padding(.horizontal, 7)
                                .frame(height: 25)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(ConversationPressableButtonStyle())
                            .help(entry.fullText)
                            .accessibilityIdentifier("conversation.toc.\(entry.index)")
                        }
                    }
                }
                .padding(.horizontal, 7)
                .padding(.bottom, 10)
            }
            .accessibilityIdentifier("conversation.toc")
        }
    }

    @ViewBuilder private var overviewLoadingState: some View {
        switch store.detailState {
        case .loading:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在读取概览…")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Color.ccCaption)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            Label(appLanguage.localized(message), systemImage: "exclamationmark.triangle")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.ccRed)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        default:
            EmptyView()
        }
    }

    private func railHeading(_ value: String) -> some View {
        Text(appLanguage.localized(value))
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Color.ccCaption)
            .padding(.horizontal, 12)
            .padding(.top, 13)
            .padding(.bottom, 6)
    }

    private func statRows(_ session: HistorySession) -> [(String, String)] {
        let metadata = session.metadata
        let totals = metadata.totals
        var rows: [(String, String?)] = [
            ("标题", metadata.title.isEmpty ? nil : metadata.title),
            ("模型", metadata.model),
            ("项目", metadata.cwd ?? (metadata.project.isEmpty ? nil : metadata.project)),
            ("分支", metadata.gitBranch),
            ("会话", metadata.sessionID.isEmpty ? nil : String(metadata.sessionID.prefix(12))),
            ("根会话", metadata.rootSessionID.map { String($0.prefix(12)) }),
            ("父线程", metadata.parentThreadID.map { String($0.prefix(12)) }),
            ("代理", metadata.agentNickname),
            ("消息", String(metadata.messageCount)),
            ("轮次", totals.turns > 0 ? String(totals.turns) : nil),
            ("输入", totals.tokenUsageAvailable == false ? "—" : (totals.inputTokens > 0 ? ConversationPresentation.tokenCount(totals.inputTokens) : nil)),
            ("输出", totals.tokenUsageAvailable == false ? "—" : (totals.outputTokens > 0 ? ConversationPresentation.tokenCount(totals.outputTokens) : nil)),
            ("Credits", totals.credits.map(ConversationPresentation.credits)),
            ("缓存读取", totals.cacheRead > 0 ? ConversationPresentation.tokenCount(totals.cacheRead) : nil),
            ("来源", ConversationPresentation.sourceName(rawValue: metadata.source.rawValue)),
            ("版本", metadata.version),
            ("文件", ConversationPresentation.byteCount(metadata.sizeBytes, language: appLanguage)),
            ("异常行", metadata.diagnostics.malformedLines > 0 ? String(metadata.diagnostics.malformedLines) : nil),
        ]
        if metadata.isSubagent {
            rows.insert(("类型", appLanguage.localized("子代理会话")), at: min(2, rows.count))
        }
        if metadata.imported {
            rows.insert(("记录", appLanguage.localized("已导入")), at: min(2, rows.count))
        }
        return rows.compactMap { key, value in
            guard let value, !value.isEmpty else { return nil }
            return (key, value)
        }
    }

    private func tableOfContents(_ messages: [HistoryMessage]) -> [(index: Int, title: String, fullText: String)] {
        messages.enumerated().compactMap { index, message in
            guard message.role == "user", !message.isMetadata else { return nil }
            let value = ConversationVisibleText.visibleUserText(message)
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            guard !value.isEmpty else { return nil }
            return (index, String(value.prefix(32)), String(value.prefix(200)))
        }
    }
}

private struct FlexibleOverviewTags: View {
    let tags: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.ccBrandStrong)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.ccBrandSoft)
                    .clipShape(Capsule())
            }
        }
    }
}
