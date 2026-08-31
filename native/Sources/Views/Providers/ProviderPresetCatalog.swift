import Foundation

/// Upstream services the gateway knows how to reach.
///
/// The list is ported from cc-switch's provider catalog, which tracks the endpoints and model ids
/// of the Anthropic-compatible services people actually use; keeping ten hand-written entries here
/// meant most users had to look every one of them up by hand. Referral parameters were stripped
/// from the website links — those belong to cc-switch, not to this app.
///
/// Presets are a starting point, not a contract: they fill the editor's fields and the user can
/// change anything afterwards. Entries needing OAuth, per-user template values, or a wire format
/// the gateway cannot translate are deliberately absent rather than present and broken.
struct ProviderPreset: Identifiable, Hashable {
    enum Category: String, CaseIterable, Identifiable {
        case official
        case vendor
        case aggregator
        case thirdParty
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .official: "官方"
            case .vendor: "模型厂商"
            case .aggregator: "聚合平台"
            case .thirdParty: "第三方中转"
            case .custom: "自定义"
            }
        }
    }

    let id: String
    let name: String
    let baseURL: String
    let defaultModel: String
    let smallModel: String
    let wireProtocol: Provider.WireProtocol
    var category: Category = .thirdParty
    var website: String = ""

    func apply(to provider: inout Provider) {
        provider.name = name
        provider.baseUrl = baseURL
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
        .init(id: "anthropic", name: "Anthropic", baseURL: "https://api.anthropic.com/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .official, website: "https://www.anthropic.com/claude-code"),
        .init(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", defaultModel: "gpt-5.2", smallModel: "gpt-5.2-mini", wireProtocol: .openAIResponses, category: .official, website: "https://platform.openai.com"),
        .init(id: "google-ai-studio", name: "Google AI Studio", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", defaultModel: "gemini-3.5-flash", smallModel: "gemini-3.1-flash-lite", wireProtocol: .openAIChat, category: .official, website: "https://aistudio.google.com"),
        .init(id: "kimi", name: "Kimi", baseURL: "https://api.moonshot.cn/anthropic/v1", defaultModel: "kimi-k2.7-code", smallModel: "kimi-k2.7-code", wireProtocol: .anthropic, category: .vendor, website: "https://platform.kimi.com"),
        .init(id: "kimi-for-coding", name: "Kimi For Coding", baseURL: "https://api.kimi.com/coding/v1", defaultModel: "kimi-for-coding", smallModel: "kimi-for-coding", wireProtocol: .anthropic, category: .vendor, website: "https://www.kimi.com/code/"),
        .init(id: "packycode", name: "PackyCode", baseURL: "https://www.packyapi.ai/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .thirdParty, website: "https://www.packyapi.ai"),
        .init(id: "zetaapi", name: "ZetaAPI", baseURL: "https://api.zetaapi.ai/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .aggregator, website: "https://zetaapi.ai"),
        .init(id: "apinebula", name: "APINebula", baseURL: "https://apinebula.ai/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .thirdParty, website: "https://apinebula.ai"),
        .init(id: "aicodemirror", name: "AICodeMirror", baseURL: "https://api.aicodemirror.ai/api/claudecode/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .thirdParty, website: "https://www.aicodemirror.ai"),
        .init(id: "patewayai", name: "PatewayAI", baseURL: "https://api.pateway.ai/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .thirdParty, website: "https://pateway.ai"),
        .init(id: "fennoai", name: "FennoAI", baseURL: "https://api.fenno.ai/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .aggregator, website: "https://api.fenno.ai"),
        .init(id: "runapi", name: "RunAPI", baseURL: "https://runapi.host/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .aggregator, website: "https://runapi.host"),
        .init(id: "shengsuanyun", name: "Shengsuanyun", baseURL: "https://router.shengsuanyun.com/api/v1", defaultModel: "anthropic/claude-sonnet-5", smallModel: "anthropic/claude-haiku-4.5", wireProtocol: .anthropic, category: .aggregator, website: "https://www.shengsuanyun.com/?from=CH_4HHXMRYF"),
        .init(id: "aigocode", name: "AIGoCode", baseURL: "https://api.aigocode.app/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .thirdParty, website: "https://aigocode.app"),
        .init(id: "qiniu", name: "Qiniu", baseURL: "https://api.qnaigc.com/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .aggregator, website: "https://s.qiniu.com/nMvAvy"),
        .init(id: "aicoding", name: "AICoding", baseURL: "https://api.aicoding.inc/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .thirdParty, website: "https://aicoding.inc"),
        .init(id: "subrouter", name: "SubRouter", baseURL: "https://subrouter.ai/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .aggregator, website: "https://subrouter.ai"),
        .init(id: "apikey-fun", name: "APIKEY.FUN", baseURL: "https://api.apikey.fun/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .thirdParty, website: "https://apikey.fun"),
        .init(id: "claudeapi", name: "ClaudeAPI", baseURL: "https://gw.apito.ai/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .aggregator, website: "https://www.apito.ai"),
        .init(id: "code0", name: "Code0", baseURL: "https://code0.ai/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .aggregator, website: "https://code0.ai"),
        .init(id: "teamorouter", name: "TeamoRouter", baseURL: "https://api.teamorouter.cn/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .aggregator, website: "https://teamorouter.cn"),
        .init(id: "ppio", name: "PPIO", baseURL: "https://api.ppio.com/anthropic/v1", defaultModel: "deepseek/deepseek-v4-flash-0731", smallModel: "deepseek/deepseek-v4-flash-0731", wireProtocol: .anthropic, category: .aggregator, website: "https://ppio.com"),
        .init(id: "claudecn", name: "ClaudeCN", baseURL: "https://claudecn.top/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .thirdParty, website: "https://claudecn.top"),
        .init(id: "agent-plan", name: "火山 Agent Plan", baseURL: "https://ark.cn-beijing.volces.com/api/plan/v1", defaultModel: "ark-code-latest", smallModel: "ark-code-latest", wireProtocol: .anthropic, category: .vendor, website: "https://www.volcengine.com/activity/agentplan?ac=MMAP8JTTCAQ2&rc=6J6FV5N2&utm_source=OWO&utm_medium=devrel-1&utm_campaign=hw&utm_term=ccswitch&utm_content=hw"),
        .init(id: "coding-plan", name: "火山 Coding Plan", baseURL: "https://ark.cn-beijing.volces.com/api/coding/v1", defaultModel: "ark-code-latest", smallModel: "ark-code-latest", wireProtocol: .anthropic, category: .vendor, website: "https://www.volcengine.com/activity/codingplan?ac=MMAP8JTTCAQ2&rc=6J6FV5N2&utm_campaign=hw&utm_content=ccswitch&utm_medium=devrel_tool_web&utm_source=OWO&utm_term=ccswitch"),
        .init(id: "byteplus", name: "BytePlus", baseURL: "https://ark.ap-southeast.bytepluses.com/api/coding/v1", defaultModel: "ark-code-latest", smallModel: "ark-code-latest", wireProtocol: .anthropic, category: .vendor, website: "https://www.byteplus.com/en/product/modelark?utm_campaign=hw&utm_content=ccswitch&utm_medium=devrel_tool_web&utm_source=OWO&utm_term=ccswitch"),
        .init(id: "doubaoseed", name: "DouBaoSeed", baseURL: "https://ark.cn-beijing.volces.com/api/compatible/v1", defaultModel: "doubao-seed-2-1-pro-260628", smallModel: "doubao-seed-2-1-pro-260628", wireProtocol: .anthropic, category: .vendor, website: "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey?apikey=%7B%7D&utm_campaign=hw&utm_content=ccswitch&utm_medium=devrel_tool_web&utm_source=OWO&utm_term=ccswitch"),
        .init(id: "siliconflow", name: "SiliconFlow", baseURL: "https://api.siliconflow.cn/v1", defaultModel: "Pro/MiniMaxAI/MiniMax-M2.5", smallModel: "Pro/MiniMaxAI/MiniMax-M2.5", wireProtocol: .anthropic, category: .aggregator, website: "https://siliconflow.cn"),
        .init(id: "siliconflow-en", name: "SiliconFlow en", baseURL: "https://api.siliconflow.com/v1", defaultModel: "MiniMaxAI/MiniMax-M3", smallModel: "MiniMaxAI/MiniMax-M3", wireProtocol: .anthropic, category: .aggregator, website: "https://siliconflow.com"),
        .init(id: "a6api", name: "A6API", baseURL: "https://api.a6api.com/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .aggregator, website: "https://www.a6api.com"),
        .init(id: "atlascloud", name: "AtlasCloud", baseURL: "https://api.atlascloud.ai/v1", defaultModel: "zai-org/glm-5.1", smallModel: "zai-org/glm-5.1", wireProtocol: .anthropic, category: .aggregator, website: "https://www.atlascloud.ai/console/coding-plan"),
        .init(id: "compshare", name: "Compshare", baseURL: "https://api.modelverse.cn/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .aggregator, website: "https://www.compshare.cn"),
        .init(id: "compshare-coding-plan", name: "Compshare Coding Plan", baseURL: "https://cp.compshare.cn/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .aggregator, website: "https://www.compshare.cn"),
        .init(id: "ccsub", name: "CCSub", baseURL: "https://www.ccsub.net/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .aggregator, website: "https://www.ccsub.net"),
        .init(id: "sssaicode", name: "SSSAiCode", baseURL: "https://node-hk.sssaicodeapi.com/api/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .thirdParty, website: "https://sssaicodeapi.com"),
        .init(id: "micu", name: "Micu", baseURL: "https://www.micuapi.ai/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .thirdParty, website: "https://www.micuapi.ai"),
        .init(id: "rightcode", name: "RightCode", baseURL: "https://www.rightapi.ai/claude/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .thirdParty, website: "https://www.rightapi.ai"),
        .init(id: "etok-ai", name: "ETok.ai", baseURL: "https://api.etok.ai/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .thirdParty, website: "https://etok.ai"),
        .init(id: "cubence", name: "Cubence", baseURL: "https://api.cubence.com/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .thirdParty, website: "https://cubence.com"),
        .init(id: "crazyrouter", name: "CrazyRouter", baseURL: "https://cn.crazyrouter.com/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .thirdParty, website: "https://www.crazyrouter.com"),
        .init(id: "dmxapi", name: "DMXAPI", baseURL: "https://www.dmxapi.cn/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .aggregator, website: "https://www.dmxapi.cn"),
        .init(id: "sudocode-chat", name: "SudoCode.chat", baseURL: "https://api.sudocode.chat/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .thirdParty, website: "https://sudocode.chat"),
        .init(id: "sudocode-us", name: "SudoCode.us", baseURL: "https://sudocode.us/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .thirdParty, website: "https://sudocode.us"),
        .init(id: "xycai", name: "XycAi", baseURL: "https://apicdn.xycai.us/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .aggregator, website: "https://xycai.us"),
        .init(id: "amux", name: "Amux", baseURL: "https://api.amux.ai/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .aggregator, website: "https://amux.ai"),
        .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/anthropic/v1", defaultModel: "deepseek-v4-pro", smallModel: "deepseek-v4-flash", wireProtocol: .anthropic, category: .vendor, website: "https://platform.deepseek.com"),
        .init(id: "opencode-go", name: "OpenCode Go", baseURL: "https://opencode.ai/zen/go/v1", defaultModel: "deepseek-v4-flash", smallModel: "deepseek-v4-flash", wireProtocol: .anthropic, category: .thirdParty, website: "https://opencode.ai/go"),
        .init(id: "zhipu-glm", name: "Zhipu GLM", baseURL: "https://open.bigmodel.cn/api/anthropic/v1", defaultModel: "glm-5.1", smallModel: "glm-5.1", wireProtocol: .anthropic, category: .vendor, website: "https://open.bigmodel.cn"),
        .init(id: "zhipu-glm-en", name: "Zhipu GLM en", baseURL: "https://api.z.ai/api/anthropic/v1", defaultModel: "glm-5.1", smallModel: "glm-5.1", wireProtocol: .anthropic, category: .vendor, website: "https://z.ai"),
        .init(id: "baidu-qianfan-coding-plan", name: "Baidu Qianfan Coding Plan", baseURL: "https://qianfan.baidubce.com/anthropic/coding/v1", defaultModel: "qianfan-code-latest", smallModel: "qianfan-code-latest", wireProtocol: .anthropic, category: .vendor, website: "https://cloud.baidu.com/product/qianfan_modelbuilder"),
        .init(id: "baidu-qianfan-token-plan", name: "Baidu Qianfan Token Plan", baseURL: "https://qianfan.baidubce.com/anthropic/tokenplan/personal/v1", defaultModel: "deepseek-v4-pro", smallModel: "deepseek-v4-pro", wireProtocol: .anthropic, category: .vendor, website: "https://cloud.baidu.com/product/codingplan.html"),
        .init(id: "bailian", name: "Bailian", baseURL: "https://dashscope.aliyuncs.com/apps/anthropic/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .vendor, website: "https://bailian.console.aliyun.com"),
        .init(id: "bailian-for-coding", name: "Bailian For Coding", baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .vendor, website: "https://bailian.console.aliyun.com"),
        .init(id: "stepfun", name: "StepFun", baseURL: "https://api.stepfun.com/step_plan/v1", defaultModel: "step-3.5-flash-2603", smallModel: "step-3.5-flash-2603", wireProtocol: .anthropic, category: .vendor, website: "https://platform.stepfun.com/step-plan"),
        .init(id: "stepfun-en", name: "StepFun en", baseURL: "https://api.stepfun.ai/step_plan/v1", defaultModel: "step-3.5-flash-2603", smallModel: "step-3.5-flash-2603", wireProtocol: .anthropic, category: .vendor, website: "https://platform.stepfun.ai/step-plan"),
        .init(id: "modelscope", name: "ModelScope", baseURL: "https://api-inference.modelscope.cn/v1", defaultModel: "ZhipuAI/GLM-5.2", smallModel: "ZhipuAI/GLM-5.2", wireProtocol: .anthropic, category: .aggregator, website: "https://modelscope.cn"),
        .init(id: "longcat", name: "Longcat", baseURL: "https://api.longcat.chat/anthropic/v1", defaultModel: "LongCat-2.0", smallModel: "LongCat-2.0", wireProtocol: .anthropic, category: .vendor, website: "https://longcat.chat/platform"),
        .init(id: "minimax", name: "MiniMax", baseURL: "https://api.minimaxi.com/anthropic/v1", defaultModel: "MiniMax-M2.7", smallModel: "MiniMax-M2.7", wireProtocol: .anthropic, category: .vendor, website: "https://platform.minimaxi.com"),
        .init(id: "minimax-en", name: "MiniMax en", baseURL: "https://api.minimax.io/anthropic/v1", defaultModel: "MiniMax-M2.7", smallModel: "MiniMax-M2.7", wireProtocol: .anthropic, category: .vendor, website: "https://platform.minimax.io"),
        .init(id: "bailing", name: "BaiLing", baseURL: "https://api.tbox.cn/api/anthropic/v1", defaultModel: "Ling-2.5-1T", smallModel: "Ling-2.5-1T", wireProtocol: .anthropic, category: .vendor, website: "https://alipaytbox.yuque.com/sxs0ba/ling/get_started"),
        .init(id: "aihubmix", name: "AiHubMix", baseURL: "https://aihubmix.com/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .aggregator, website: "https://aihubmix.com"),
        .init(id: "cherryin", name: "CherryIN", baseURL: "https://open.cherryin.net/v1", defaultModel: "anthropic/claude-sonnet-5", smallModel: "anthropic/claude-haiku-4.5", wireProtocol: .anthropic, category: .aggregator, website: "https://open.cherryin.ai"),
        .init(id: "relaxycode", name: "RelaxyCode", baseURL: "https://www.relaxycode.com/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .thirdParty, website: "https://www.relaxycode.com"),
        .init(id: "e-flowcode", name: "E-FlowCode", baseURL: "https://e-flowcode.cc/v1", defaultModel: "", smallModel: "", wireProtocol: .anthropic, category: .thirdParty, website: "https://e-flowcode.cc"),
        .init(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", defaultModel: "anthropic/claude-sonnet-5", smallModel: "anthropic/claude-haiku-4.5", wireProtocol: .anthropic, category: .aggregator, website: "https://openrouter.ai"),
        .init(id: "therouter", name: "TheRouter", baseURL: "https://api.therouter.ai/v1", defaultModel: "anthropic/claude-sonnet-5", smallModel: "anthropic/claude-haiku-4.5", wireProtocol: .anthropic, category: .aggregator, website: "https://therouter.ai"),
        .init(id: "novita-ai", name: "Novita AI", baseURL: "https://api.novita.ai/anthropic/v1", defaultModel: "zai-org/glm-5.1", smallModel: "zai-org/glm-5.1", wireProtocol: .anthropic, category: .aggregator, website: "https://novita.ai"),
        .init(id: "nvidia", name: "Nvidia", baseURL: "https://integrate.api.nvidia.com/v1", defaultModel: "moonshotai/kimi-k2.5", smallModel: "moonshotai/kimi-k2.5", wireProtocol: .openAIChat, category: .aggregator, website: "https://build.nvidia.com"),
        .init(id: "pipellm", name: "PIPELLM", baseURL: "https://cc-api.pipellm.ai/v1", defaultModel: "claude-opus-5", smallModel: "claude-haiku-4-5-20251001", wireProtocol: .anthropic, category: .aggregator, website: "https://code.pipellm.ai"),
        .init(id: "xiaomi-mimo", name: "Xiaomi MiMo", baseURL: "https://api.xiaomimimo.com/anthropic/v1", defaultModel: "mimo-v2.5-pro", smallModel: "mimo-v2.5-pro", wireProtocol: .anthropic, category: .vendor, website: "https://platform.xiaomimimo.com"),
        .init(id: "xiaomi-mimo-token-plan-china", name: "Xiaomi MiMo Token Plan (China)", baseURL: "https://token-plan-cn.xiaomimimo.com/anthropic/v1", defaultModel: "mimo-v2.5-pro", smallModel: "mimo-v2.5-pro", wireProtocol: .anthropic, category: .vendor, website: "https://platform.xiaomimimo.com/#/token-plan"),
        .init(id: "jiekou-ai", name: "JieKou AI", baseURL: "https://api.jiekou.ai/anthropic/v1", defaultModel: "claude-fable-5", smallModel: "claude-fable-5", wireProtocol: .anthropic, category: .aggregator, website: "https://jiekou.ai/#model-library"),
        custom,
    ]

    /// Presentation order: the services you are most likely to be reaching for first.
    static let categoryOrder: [Category] = [.official, .vendor, .aggregator, .thirdParty]

    static func grouped(matching query: String) -> [(category: Category, presets: [ProviderPreset])] {
        categoryOrder.compactMap { category in
            let items = all.filter { $0.category == category && $0.matches(query) }
            return items.isEmpty ? nil : (category, items)
        }
    }
}
