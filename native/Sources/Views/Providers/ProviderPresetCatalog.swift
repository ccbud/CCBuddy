import Foundation

/// Upstream services the gateway knows how to reach.
///
/// Only vendors that run the models themselves are listed: Anthropic, OpenAI and Google alongside
/// the model vendors with a first-party coding endpoint. The aggregators and resellers this list
/// used to carry were removed — their endpoints move, their protocol support is whatever their
/// own upstream happens to expose that week, and shipping them as presets implied a degree of
/// vetting this app cannot do. Anything not listed is still one `自定义` entry away.
///
/// Presets are a starting point, not a contract: they fill the editor's fields and the user can
/// change anything afterwards. Entries needing OAuth, per-user template values, or a wire format
/// the gateway cannot translate are deliberately absent rather than present and broken.
struct ProviderPreset: Identifiable, Hashable {
    enum Category: String, CaseIterable, Identifiable {
        case official
        case vendor
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .official: "官方"
            case .vendor: "模型厂商"
            case .custom: "自定义"
            }
        }
    }

    let id: String
    let name: String
    /// The vendor's root, with nothing protocol-specific on it. It seeds the editor's per-protocol
    /// derivations and is where model discovery looks first.
    let baseURL: String
    /// The endpoints this vendor publishes, by protocol. A vendor documenting two of them binds
    /// two, and a client speaking either is passed straight through; the third is converted.
    var endpoints: [Provider.WireProtocol: String] = [:]
    let defaultModel: String
    let smallModel: String
    /// The endpoint that also takes callers this vendor publishes nothing for.
    let wireProtocol: Provider.WireProtocol
    var category: Category = .vendor
    var website: String = ""

    /// Falls back to the base URL under the primary protocol, so a preset that names no endpoint
    /// still configures the one upstream it means.
    var resolvedEndpoints: [Provider.WireProtocol: String] {
        endpoints.isEmpty ? [wireProtocol: baseURL] : endpoints
    }

    func apply(to provider: inout Provider) {
        provider.name = name
        provider.baseUrl = baseURL
        provider.protocolUrls = Dictionary(
            uniqueKeysWithValues: resolvedEndpoints
                .filter { !$0.value.isEmpty }
                .map { ($0.key.rawValue, $0.value) }
        )
        provider.defaultModel = defaultModel
        provider.smallFastModel = smallModel
        provider.protocol = wireProtocol
        provider.icon = nil
    }

    /// Matches on the visible name and on the host, so "bigmodel" finds GLM and "kimi" finds both
    /// Kimi entries.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return name.lowercased().contains(needle)
            || baseURL.lowercased().contains(needle)
            || defaultModel.lowercased().contains(needle)
            || resolvedEndpoints.values.contains { $0.lowercased().contains(needle) }
    }

    static let custom = ProviderPreset(
        id: "custom",
        name: "",
        baseURL: "",
        defaultModel: "",
        smallModel: "",
        wireProtocol: .anthropic,
        category: .custom
    )

    static let all: [ProviderPreset] = [
        .init(
            id: "anthropic", name: "Anthropic",
            baseURL: "https://api.anthropic.com",
            endpoints: [.anthropic: "https://api.anthropic.com/v1"],
            defaultModel: "", smallModel: "", wireProtocol: .anthropic,
            category: .official, website: "https://www.anthropic.com/claude-code"
        ),
        .init(
            id: "openai", name: "OpenAI",
            baseURL: "https://api.openai.com",
            endpoints: [
                .openAIResponses: "https://api.openai.com/v1/responses",
                .openAIChat: "https://api.openai.com/v1/chat/completions",
            ],
            defaultModel: "gpt-5.2", smallModel: "gpt-5.2-mini",
            wireProtocol: .openAIResponses,
            category: .official, website: "https://platform.openai.com"
        ),
        .init(
            id: "google-ai-studio", name: "Google AI Studio",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            endpoints: [
                .openAIChat: "https://generativelanguage.googleapis.com/v1beta/openai",
            ],
            defaultModel: "gemini-3.5-flash", smallModel: "gemini-3.1-flash-lite",
            wireProtocol: .openAIChat,
            category: .official, website: "https://aistudio.google.com"
        ),
        .init(
            id: "kimi", name: "Kimi",
            baseURL: "https://api.moonshot.cn",
            endpoints: [
                .anthropic: "https://api.moonshot.cn/anthropic/v1",
                .openAIChat: "https://api.moonshot.cn/v1/chat/completions",
            ],
            defaultModel: "kimi-k2.7-code", smallModel: "kimi-k2.7-code",
            wireProtocol: .anthropic,
            category: .vendor, website: "https://platform.kimi.com"
        ),
        .init(
            id: "kimi-for-coding", name: "Kimi For Coding",
            baseURL: "https://api.kimi.com",
            endpoints: [.anthropic: "https://api.kimi.com/coding/v1"],
            defaultModel: "kimi-for-coding", smallModel: "kimi-for-coding",
            wireProtocol: .anthropic,
            category: .vendor, website: "https://www.kimi.com/code/"
        ),
        .init(
            id: "agent-plan", name: "火山 Agent Plan",
            baseURL: "https://ark.cn-beijing.volces.com",
            endpoints: [.anthropic: "https://ark.cn-beijing.volces.com/api/plan/v1"],
            defaultModel: "ark-code-latest", smallModel: "ark-code-latest",
            wireProtocol: .anthropic,
            category: .vendor,
            website: "https://www.volcengine.com/activity/agentplan?ac=MMAP8JTTCAQ2&rc=6J6FV5N2&utm_source=OWO&utm_medium=devrel-1&utm_campaign=hw&utm_term=ccswitch&utm_content=hw"
        ),
        .init(
            id: "coding-plan", name: "火山 Coding Plan",
            baseURL: "https://ark.cn-beijing.volces.com",
            endpoints: [.anthropic: "https://ark.cn-beijing.volces.com/api/coding/v1"],
            defaultModel: "ark-code-latest", smallModel: "ark-code-latest",
            wireProtocol: .anthropic,
            category: .vendor,
            website: "https://www.volcengine.com/activity/codingplan?ac=MMAP8JTTCAQ2&rc=6J6FV5N2&utm_campaign=hw&utm_content=ccswitch&utm_medium=devrel_tool_web&utm_source=OWO&utm_term=ccswitch"
        ),
        .init(
            id: "byteplus", name: "BytePlus",
            baseURL: "https://ark.ap-southeast.bytepluses.com",
            endpoints: [.anthropic: "https://ark.ap-southeast.bytepluses.com/api/coding/v1"],
            defaultModel: "ark-code-latest", smallModel: "ark-code-latest",
            wireProtocol: .anthropic,
            category: .vendor,
            website: "https://www.byteplus.com/en/product/modelark?utm_campaign=hw&utm_content=ccswitch&utm_medium=devrel_tool_web&utm_source=OWO&utm_term=ccswitch"
        ),
        .init(
            id: "doubaoseed", name: "DouBaoSeed",
            baseURL: "https://ark.cn-beijing.volces.com",
            endpoints: [.anthropic: "https://ark.cn-beijing.volces.com/api/compatible/v1"],
            defaultModel: "doubao-seed-2-1-pro-260628", smallModel: "doubao-seed-2-1-pro-260628",
            wireProtocol: .anthropic,
            category: .vendor,
            website: "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey?apikey=%7B%7D&utm_campaign=hw&utm_content=ccswitch&utm_medium=devrel_tool_web&utm_source=OWO&utm_term=ccswitch"
        ),
        .init(
            id: "deepseek", name: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            endpoints: [
                .anthropic: "https://api.deepseek.com/anthropic",
                .openAIChat: "https://api.deepseek.com/chat/completions",
            ],
            defaultModel: "deepseek-v4-pro", smallModel: "deepseek-v4-flash",
            wireProtocol: .anthropic,
            category: .vendor, website: "https://platform.deepseek.com"
        ),
        .init(
            id: "zhipu-glm", name: "Zhipu GLM",
            baseURL: "https://open.bigmodel.cn",
            endpoints: [
                .anthropic: "https://open.bigmodel.cn/api/anthropic/v1",
                .openAIChat: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
            ],
            defaultModel: "glm-5.1", smallModel: "glm-5.1", wireProtocol: .anthropic,
            category: .vendor, website: "https://open.bigmodel.cn"
        ),
        .init(
            id: "zhipu-glm-en", name: "Zhipu GLM en",
            baseURL: "https://api.z.ai",
            endpoints: [
                .anthropic: "https://api.z.ai/api/anthropic/v1",
                .openAIChat: "https://api.z.ai/api/paas/v4/chat/completions",
            ],
            defaultModel: "glm-5.1", smallModel: "glm-5.1", wireProtocol: .anthropic,
            category: .vendor, website: "https://z.ai"
        ),
        .init(
            id: "baidu-qianfan-coding-plan", name: "Baidu Qianfan Coding Plan",
            baseURL: "https://qianfan.baidubce.com",
            endpoints: [.anthropic: "https://qianfan.baidubce.com/anthropic/coding/v1"],
            defaultModel: "qianfan-code-latest", smallModel: "qianfan-code-latest",
            wireProtocol: .anthropic,
            category: .vendor, website: "https://cloud.baidu.com/product/qianfan_modelbuilder"
        ),
        .init(
            id: "baidu-qianfan-token-plan", name: "Baidu Qianfan Token Plan",
            baseURL: "https://qianfan.baidubce.com",
            endpoints: [
                .anthropic: "https://qianfan.baidubce.com/anthropic/tokenplan/personal/v1",
            ],
            defaultModel: "deepseek-v4-pro", smallModel: "deepseek-v4-pro",
            wireProtocol: .anthropic,
            category: .vendor, website: "https://cloud.baidu.com/product/codingplan.html"
        ),
        .init(
            id: "bailian", name: "Bailian",
            baseURL: "https://dashscope.aliyuncs.com",
            endpoints: [.anthropic: "https://dashscope.aliyuncs.com/apps/anthropic/v1"],
            defaultModel: "", smallModel: "", wireProtocol: .anthropic,
            category: .vendor, website: "https://bailian.console.aliyun.com"
        ),
        .init(
            id: "bailian-for-coding", name: "Bailian For Coding",
            baseURL: "https://coding.dashscope.aliyuncs.com",
            endpoints: [.anthropic: "https://coding.dashscope.aliyuncs.com/apps/anthropic/v1"],
            defaultModel: "", smallModel: "", wireProtocol: .anthropic,
            category: .vendor, website: "https://bailian.console.aliyun.com"
        ),
        .init(
            id: "stepfun", name: "StepFun",
            baseURL: "https://api.stepfun.com",
            endpoints: [.anthropic: "https://api.stepfun.com/step_plan/v1"],
            defaultModel: "step-3.5-flash-2603", smallModel: "step-3.5-flash-2603",
            wireProtocol: .anthropic,
            category: .vendor, website: "https://platform.stepfun.com/step-plan"
        ),
        .init(
            id: "stepfun-en", name: "StepFun en",
            baseURL: "https://api.stepfun.ai",
            endpoints: [.anthropic: "https://api.stepfun.ai/step_plan/v1"],
            defaultModel: "step-3.5-flash-2603", smallModel: "step-3.5-flash-2603",
            wireProtocol: .anthropic,
            category: .vendor, website: "https://platform.stepfun.ai/step-plan"
        ),
        .init(
            id: "longcat", name: "Longcat",
            baseURL: "https://api.longcat.chat",
            endpoints: [.anthropic: "https://api.longcat.chat/anthropic/v1"],
            defaultModel: "LongCat-2.0", smallModel: "LongCat-2.0", wireProtocol: .anthropic,
            category: .vendor, website: "https://longcat.chat/platform"
        ),
        .init(
            id: "minimax", name: "MiniMax",
            baseURL: "https://api.minimaxi.com",
            endpoints: [.anthropic: "https://api.minimaxi.com/anthropic/v1"],
            defaultModel: "MiniMax-M2.7", smallModel: "MiniMax-M2.7", wireProtocol: .anthropic,
            category: .vendor, website: "https://platform.minimaxi.com"
        ),
        .init(
            id: "minimax-en", name: "MiniMax en",
            baseURL: "https://api.minimax.io",
            endpoints: [.anthropic: "https://api.minimax.io/anthropic/v1"],
            defaultModel: "MiniMax-M2.7", smallModel: "MiniMax-M2.7", wireProtocol: .anthropic,
            category: .vendor, website: "https://platform.minimax.io"
        ),
        .init(
            id: "bailing", name: "BaiLing",
            baseURL: "https://api.tbox.cn",
            endpoints: [.anthropic: "https://api.tbox.cn/api/anthropic/v1"],
            defaultModel: "Ling-2.5-1T", smallModel: "Ling-2.5-1T", wireProtocol: .anthropic,
            category: .vendor, website: "https://alipaytbox.yuque.com/sxs0ba/ling/get_started"
        ),
        .init(
            id: "xiaomi-mimo", name: "Xiaomi MiMo",
            baseURL: "https://api.xiaomimimo.com",
            endpoints: [.anthropic: "https://api.xiaomimimo.com/anthropic/v1"],
            defaultModel: "mimo-v2.5-pro", smallModel: "mimo-v2.5-pro", wireProtocol: .anthropic,
            category: .vendor, website: "https://platform.xiaomimimo.com"
        ),
        .init(
            id: "xiaomi-mimo-token-plan-china", name: "Xiaomi MiMo Token Plan (China)",
            baseURL: "https://token-plan-cn.xiaomimimo.com",
            endpoints: [.anthropic: "https://token-plan-cn.xiaomimimo.com/anthropic/v1"],
            defaultModel: "mimo-v2.5-pro", smallModel: "mimo-v2.5-pro", wireProtocol: .anthropic,
            category: .vendor, website: "https://platform.xiaomimimo.com/#/token-plan"
        ),
        custom,
    ]

    /// Presentation order: the services you are most likely to be reaching for first.
    static let categoryOrder: [Category] = [.official, .vendor]

    static func grouped(matching query: String) -> [(category: Category, presets: [ProviderPreset])] {
        categoryOrder.compactMap { category in
            let items = all.filter { $0.category == category && $0.matches(query) }
            return items.isEmpty ? nil : (category, items)
        }
    }
}
