import Foundation

struct SkillToolSpec: Sendable {
    var key: String
    var label: String
    var skillsPath: String
    var detectionPath: String
    var projectPath: String?
}

enum SkillToolCatalog {
    static let all: [SkillToolSpec] = [
        .init(key: "cursor", label: "Cursor", skillsPath: ".cursor/skills", detectionPath: ".cursor", projectPath: ".agents/skills"),
        .init(key: "claude_code", label: "Claude Code", skillsPath: ".claude/skills", detectionPath: ".claude", projectPath: ".claude/skills"),
        .init(key: "codex", label: "Codex", skillsPath: ".codex/skills", detectionPath: ".codex", projectPath: ".agents/skills"),
        .init(key: "deepseek_harness", label: "DeepSeek Harness", skillsPath: ".dsh/skills", detectionPath: ".dsh", projectPath: ".dsh/skills"),
        .init(key: "opencode", label: "OpenCode", skillsPath: ".config/opencode/skills", detectionPath: ".config/opencode", projectPath: ".agents/skills"),
        .init(key: "antigravity", label: "Antigravity", skillsPath: ".gemini/config/skills", detectionPath: ".gemini/config", projectPath: ".agents/skills"),
        .init(key: "amp", label: "Amp", skillsPath: ".config/agents/skills", detectionPath: ".config/agents", projectPath: ".agents/skills"),
        .init(key: "kimi_cli", label: "Kimi Code CLI", skillsPath: ".config/agents/skills", detectionPath: ".config/agents", projectPath: ".agents/skills"),
        .init(key: "augment", label: "Augment", skillsPath: ".augment/skills", detectionPath: ".augment", projectPath: ".augment/skills"),
        .init(key: "openclaw", label: "OpenClaw", skillsPath: ".openclaw/skills", detectionPath: ".openclaw", projectPath: "skills"),
        .init(key: "copaw", label: "Copaw", skillsPath: ".copaw/skill_pool", detectionPath: ".copaw", projectPath: ".copaw/skill_pool"),
        .init(key: "cline", label: "Cline", skillsPath: ".agents/skills", detectionPath: ".agents", projectPath: ".agents/skills"),
        .init(key: "codebuddy", label: "CodeBuddy", skillsPath: ".codebuddy/skills", detectionPath: ".codebuddy", projectPath: ".codebuddy/skills"),
        .init(key: "codewhale", label: "CodeWhale", skillsPath: ".codewhale/skills", detectionPath: ".codewhale", projectPath: ".codewhale/skills"),
        .init(key: "workbuddy", label: "WorkBuddy", skillsPath: ".workbuddy/skills", detectionPath: ".workbuddy", projectPath: nil),
        .init(key: "command_code", label: "Command Code", skillsPath: ".commandcode/skills", detectionPath: ".commandcode", projectPath: ".commandcode/skills"),
        .init(key: "continue", label: "Continue", skillsPath: ".continue/skills", detectionPath: ".continue", projectPath: ".continue/skills"),
        .init(key: "crush", label: "Crush", skillsPath: ".config/crush/skills", detectionPath: ".config/crush", projectPath: ".crush/skills"),
        .init(key: "junie", label: "Junie", skillsPath: ".junie/skills", detectionPath: ".junie", projectPath: ".junie/skills"),
        .init(key: "iflow_cli", label: "iFlow CLI", skillsPath: ".iflow/skills", detectionPath: ".iflow", projectPath: ".iflow/skills"),
        .init(key: "kiro_cli", label: "Kiro CLI", skillsPath: ".kiro/skills", detectionPath: ".kiro", projectPath: ".kiro/skills"),
        .init(key: "kode", label: "Kode", skillsPath: ".kode/skills", detectionPath: ".kode", projectPath: ".kode/skills"),
        .init(key: "mcpjam", label: "MCPJam", skillsPath: ".mcpjam/skills", detectionPath: ".mcpjam", projectPath: ".mcpjam/skills"),
        .init(key: "mistral_vibe", label: "Mistral Vibe", skillsPath: ".vibe/skills", detectionPath: ".vibe", projectPath: ".vibe/skills"),
        .init(key: "mux", label: "Mux", skillsPath: ".mux/skills", detectionPath: ".mux", projectPath: ".mux/skills"),
        .init(key: "openclaude", label: "OpenClaude IDE", skillsPath: ".openclaude/skills", detectionPath: ".openclaude", projectPath: ".openclaude/skills"),
        .init(key: "openhands", label: "OpenHands", skillsPath: ".openhands/skills", detectionPath: ".openhands", projectPath: ".openhands/skills"),
        .init(key: "pi", label: "Pi", skillsPath: ".pi/agent/skills", detectionPath: ".pi", projectPath: ".pi/skills"),
        .init(key: "qoder", label: "Qoder", skillsPath: ".qoder/skills", detectionPath: ".qoder", projectPath: ".qoder/skills"),
        .init(key: "qoderwork", label: "QoderWork", skillsPath: ".qoderwork/skills", detectionPath: ".qoderwork", projectPath: ".qoderwork/skills"),
        .init(key: "qwen_code", label: "Qwen Code", skillsPath: ".qwen/skills", detectionPath: ".qwen", projectPath: ".qwen/skills"),
        .init(key: "trae", label: "Trae", skillsPath: ".trae/skills", detectionPath: ".trae", projectPath: ".trae/skills"),
        .init(key: "trae_cn", label: "Trae CN", skillsPath: ".trae-cn/skills", detectionPath: ".trae-cn", projectPath: ".trae/skills"),
        .init(key: "zencoder", label: "Zencoder", skillsPath: ".zencoder/skills", detectionPath: ".zencoder", projectPath: ".zencoder/skills"),
        .init(key: "neovate", label: "Neovate", skillsPath: ".neovate/skills", detectionPath: ".neovate", projectPath: ".neovate/skills"),
        .init(key: "pochi", label: "Pochi", skillsPath: ".pochi/skills", detectionPath: ".pochi", projectPath: ".pochi/skills"),
        .init(key: "adal", label: "AdaL", skillsPath: ".adal/skills", detectionPath: ".adal", projectPath: ".adal/skills"),
        .init(key: "kilo_code", label: "Kilo Code", skillsPath: ".kilocode/skills", detectionPath: ".kilocode", projectPath: ".kilocode/skills"),
        .init(key: "roo_code", label: "Roo Code", skillsPath: ".roo/skills", detectionPath: ".roo", projectPath: ".roo/skills"),
        .init(key: "goose", label: "Goose", skillsPath: ".config/goose/skills", detectionPath: ".config/goose", projectPath: ".goose/skills"),
        .init(key: "gemini_cli", label: "Gemini CLI", skillsPath: ".gemini/skills", detectionPath: ".gemini", projectPath: ".agents/skills"),
        .init(key: "github_copilot", label: "GitHub Copilot", skillsPath: ".copilot/skills", detectionPath: ".copilot", projectPath: ".agents/skills"),
        .init(key: "clawdbot", label: "Clawdbot", skillsPath: ".clawdbot/skills", detectionPath: ".clawdbot", projectPath: ".clawdbot/skills"),
        .init(key: "droid", label: "Droid", skillsPath: ".factory/skills", detectionPath: ".factory", projectPath: ".factory/skills"),
        .init(key: "windsurf", label: "Windsurf", skillsPath: ".codeium/windsurf/skills", detectionPath: ".codeium/windsurf", projectPath: ".windsurf/skills"),
        .init(key: "moltbot", label: "MoltBot", skillsPath: ".moltbot/skills", detectionPath: ".moltbot", projectPath: ".moltbot/skills"),
        .init(key: "hermes_agent", label: "Hermes Agent", skillsPath: ".hermes/skills", detectionPath: ".hermes", projectPath: nil),
    ]

    static func spec(for key: String) -> SkillToolSpec? {
        all.first { $0.key == key }
    }

    static func tools(home: URL, fileManager: FileManager) -> [SkillTool] {
        all.map { spec in
            var isDirectory: ObjCBool = false
            let detected = fileManager.fileExists(
                atPath: home.appendingPathComponent(spec.detectionPath).path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
            return SkillTool(
                key: spec.key,
                label: spec.label,
                path: home.appendingPathComponent(spec.skillsPath).standardizedFileURL,
                detected: detected,
                enabled: true,
                defaultSyncMode: spec.key == "cursor" ? .copy : .auto,
                sharedKeys: all.filter { $0.skillsPath == spec.skillsPath }.map(\.key),
                projectPath: spec.projectPath,
                sharedProjectKeys: spec.projectPath.map { project in
                    all.filter { $0.projectPath == project }.map(\.key)
                } ?? []
            )
        }
    }
}
