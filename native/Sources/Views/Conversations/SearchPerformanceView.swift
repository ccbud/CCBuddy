import SwiftUI

/// Query diagnostics are a snapshot, not a live build-progress feed. A direct search during
/// background preparation is normal operation and must not look like a stalled/error state.
enum ConversationSearchAccelerationPresentation {
    static func isNormalDirectSearch(_ reason: String) -> Bool {
        reason == "indexPreparing" || reason == "indexRestoring" || reason == "sourceVerification"
    }

    static func explanationKey(_ reason: String) -> String {
        switch reason {
        case "indexPreparing", "indexRestoring":
            return "本次查询直接核对压缩正文，不等待索引；加速在后台准备，后续查询自动使用。"
        case "sourceVerification":
            return "本次查询直接核对新增或已变化的原始记录，已确认的匹配会先显示。"
        case "lowDiskSpace":
            return "索引所在磁盘空间不足，搜索加速已暂停。"
        case "unsafeCache":
            return "搜索缓存位置不可用，加速引擎未能启动。"
        case "ioFailure":
            return "无法读写搜索缓存，正在使用精确搜索。"
        default:
            return "搜索加速暂不可用，正在使用精确搜索。"
        }
    }
}

/// Real query measurements live beside the control that opts into local inference. None of the
/// labels infer ANE execution from the machine architecture or the requested compute policy.
struct SearchPerformanceView: View {
    @ObservedObject var store: ConversationStore
    @Environment(\.appLanguage) private var language
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "internaldrive")
                .foregroundStyle(Theme.accentText)
            Text(store.searchDiagnostics?.engine ?? language.localized("本地搜索"))
                .font(.ccLabel(.medium))
                .accessibilityIdentifier("search.performance.engine")
            if let elapsed = store.searchDurationMilliseconds {
                Text(verbatim: String(format: "%.1f ms", elapsed))
                    .font(.ccLabel())
                    .monospacedDigit()
                    .foregroundStyle(Theme.mutedForeground)
                    .accessibilityIdentifier("search.performance.duration")
            }
            if let reason = store.searchDiagnostics?.fallbackReason {
                let direct = ConversationSearchAccelerationPresentation.isNormalDirectSearch(reason)
                Label(language.localized(direct ? "直接搜索" : "加速暂不可用"),
                      systemImage: direct ? "doc.text.magnifyingglass" : "exclamationmark.triangle")
                    .font(.ccLabel())
                    .foregroundStyle(direct ? Theme.mutedForeground : Theme.warning)
                    .help(fallbackExplanation(reason))
                    .accessibilityIdentifier(direct ? "search.performance.direct" : "search.performance.fallback")
            }
            Spacer(minLength: Space.sm)
            if store.isRankingSearch {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel(language.localized("正在智能排序"))
            }
            Toggle(language.localized("智能排序"), isOn: Binding(
                get: { store.semanticRankingEnabled },
                set: store.setSemanticRankingEnabled
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.ccLabel())
            .fixedSize()
            .help(language.localized("离线模型为前 32 条结果排序，适合英文与代码查询。"))
            .accessibilityIdentifier("search.semantic.toggle")
            Button { showsDetails.toggle() } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.mutedForeground)
            .accessibilityLabel(language.localized("搜索与加速详情"))
            .accessibilityIdentifier("search.performance.details")
            .popover(isPresented: $showsDetails, arrowEdge: .bottom) { details }
        }
        .padding(.horizontal, Space.xl)
        .frame(minHeight: 42)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.performance")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Label(language.localized("本机完成，隐私留在本机"), systemImage: "lock.shield")
                .font(.ccHeading(.semibold))
            Text(language.localized("tgrep 缩小候选范围，再精确核对原文；智能排序不会移除匹配结果。"))
                .font(.ccCaption())
                .foregroundStyle(Theme.mutedForeground)
            Text(language.localized("首次使用会准备本地模型，精确搜索结果始终可用。"))
                .font(.ccCaption())
                .foregroundStyle(Theme.mutedForeground)
            if let lexical = store.searchDiagnostics {
                LabeledContent(language.localized("搜索引擎"), value: lexical.engine)
                LabeledContent(language.localized("索引分组"), value: String(lexical.indexedDocuments))
                LabeledContent(language.localized("本次候选"), value: String(lexical.candidateCount))
                LabeledContent(language.localized("候选检索"),
                               value: String(format: "%.1f ms", lexical.queryMilliseconds))
                if let reason = lexical.fallbackReason {
                    Text(fallbackExplanation(reason))
                        .foregroundStyle(ConversationSearchAccelerationPresentation.isNormalDirectSearch(reason)
                            ? Theme.mutedForeground : Theme.warning)
                        .accessibilityIdentifier("search.performance.fallback.reason")
                    if !ConversationSearchAccelerationPresentation.isNormalDirectSearch(reason) {
                        Text(language.localized("精确搜索仍可用；后续搜索会自动重试加速。"))
                            .foregroundStyle(Theme.mutedForeground)
                    }
                    LabeledContent(language.localized("诊断代码"), value: reason)
                }
            }
            if let first = store.searchFirstResultMilliseconds {
                LabeledContent(language.localized("首批结果"), value: String(format: "%.1f ms", first))
                    .accessibilityIdentifier("search.performance.first.result")
            }
            if let complete = store.searchDurationMilliseconds {
                LabeledContent(language.localized("完整搜索"), value: String(format: "%.1f ms", complete))
            }
            if let semantic = store.semanticDiagnostics {
                Divider()
                LabeledContent(language.localized("本地模型"), value: semantic.modelName)
                LabeledContent(language.localized("计算策略"), value: semantic.computePolicy == .cpuAndNeuralEngine
                    ? "CPU + Neural Engine" : "CPU")
                if let preferred = semantic.neuralEnginePreferredOperationCount,
                   let total = semantic.totalPlannedOperationCount {
                    LabeledContent(language.localized("ANE 优选算子"), value: "\(preferred) / \(total)")
                }
                LabeledContent(language.localized("向量缓存命中"), value: String(semantic.cacheHitCount))
                Text(verbatim: String(format: "%.1f ms", semantic.durationMilliseconds))
                    .monospacedDigit()
                Text(semanticStatus(semantic))
                    .foregroundStyle(Theme.mutedForeground)
                    .accessibilityIdentifier("search.semantic.status")
            }
            Text(language.localized("Neural Engine 由 Core ML 调度；计算计划不代表逐次运行的硬件计数。"))
                .font(.ccLabel())
                .foregroundStyle(Theme.mutedForeground)
        }
        .font(.ccCaption())
        .padding(Space.xl)
        .frame(width: 360)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.performance.popover")
    }

    private func semanticStatus(_ diagnostic: SemanticSearchDiagnostics) -> String {
        switch diagnostic.state {
        case .ready:
            return language.localized("本地智能排序已完成。")
        case .unsupportedLanguage:
            return language.localized("This model supports English and code queries. Keyword order is preserved for other languages.")
        case .unavailable:
            return language.localized("Local semantic model unavailable. Keyword results remain available.")
        }
    }

    private func fallbackExplanation(_ reason: String) -> String {
        language.localized(ConversationSearchAccelerationPresentation.explanationKey(reason))
    }
}
