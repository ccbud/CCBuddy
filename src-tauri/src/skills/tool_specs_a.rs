use super::tools::ToolSpec;

macro_rules! t {
    ($key:literal, $label:literal, $skills:literal, $detect:literal, $project:expr) => {
        ToolSpec {
            key: $key,
            label: $label,
            skills: $skills,
            detect: $detect,
            project: $project,
        }
    };
}

#[rustfmt::skip]
pub const TOOLS: [ToolSpec; 24] = [
    t!("cursor", "Cursor", ".cursor/skills", ".cursor", Some(".agents/skills")),
    t!("claude_code", "Claude Code", ".claude/skills", ".claude", Some(".claude/skills")),
    t!("codex", "Codex", ".codex/skills", ".codex", Some(".agents/skills")),
    t!("deepseek_harness", "DeepSeek Harness", ".dsh/skills", ".dsh", Some(".dsh/skills")),
    t!("opencode", "OpenCode", ".config/opencode/skills", ".config/opencode", Some(".agents/skills")),
    t!("antigravity", "Antigravity", ".gemini/config/skills", ".gemini/config", Some(".agents/skills")),
    t!("amp", "Amp", ".config/agents/skills", ".config/agents", Some(".agents/skills")),
    t!("kimi_cli", "Kimi Code CLI", ".config/agents/skills", ".config/agents", Some(".agents/skills")),
    t!("augment", "Augment", ".augment/skills", ".augment", Some(".augment/skills")),
    t!("openclaw", "OpenClaw", ".openclaw/skills", ".openclaw", Some("skills")),
    t!("copaw", "Copaw", ".copaw/skill_pool", ".copaw", Some(".copaw/skill_pool")),
    t!("cline", "Cline", ".agents/skills", ".agents", Some(".agents/skills")),
    t!("codebuddy", "CodeBuddy", ".codebuddy/skills", ".codebuddy", Some(".codebuddy/skills")),
    t!("codewhale", "CodeWhale", ".codewhale/skills", ".codewhale", Some(".codewhale/skills")),
    t!("workbuddy", "WorkBuddy", ".workbuddy/skills", ".workbuddy", None),
    t!("command_code", "Command Code", ".commandcode/skills", ".commandcode", Some(".commandcode/skills")),
    t!("continue", "Continue", ".continue/skills", ".continue", Some(".continue/skills")),
    t!("crush", "Crush", ".config/crush/skills", ".config/crush", Some(".crush/skills")),
    t!("junie", "Junie", ".junie/skills", ".junie", Some(".junie/skills")),
    t!("iflow_cli", "iFlow CLI", ".iflow/skills", ".iflow", Some(".iflow/skills")),
    t!("kiro_cli", "Kiro CLI", ".kiro/skills", ".kiro", Some(".kiro/skills")),
    t!("kode", "Kode", ".kode/skills", ".kode", Some(".kode/skills")),
    t!("mcpjam", "MCPJam", ".mcpjam/skills", ".mcpjam", Some(".mcpjam/skills")),
    t!("mistral_vibe", "Mistral Vibe", ".vibe/skills", ".vibe", Some(".vibe/skills")),
];
