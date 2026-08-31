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
pub const TOOLS: [ToolSpec; 23] = [
    t!("mux", "Mux", ".mux/skills", ".mux", Some(".mux/skills")),
    t!("openclaude", "OpenClaude IDE", ".openclaude/skills", ".openclaude", Some(".openclaude/skills")),
    t!("openhands", "OpenHands", ".openhands/skills", ".openhands", Some(".openhands/skills")),
    t!("pi", "Pi", ".pi/agent/skills", ".pi", Some(".pi/skills")),
    t!("qoder", "Qoder", ".qoder/skills", ".qoder", Some(".qoder/skills")),
    t!("qoderwork", "QoderWork", ".qoderwork/skills", ".qoderwork", Some(".qoderwork/skills")),
    t!("qwen_code", "Qwen Code", ".qwen/skills", ".qwen", Some(".qwen/skills")),
    t!("trae", "Trae", ".trae/skills", ".trae", Some(".trae/skills")),
    t!("trae_cn", "Trae CN", ".trae-cn/skills", ".trae-cn", Some(".trae/skills")),
    t!("zencoder", "Zencoder", ".zencoder/skills", ".zencoder", Some(".zencoder/skills")),
    t!("neovate", "Neovate", ".neovate/skills", ".neovate", Some(".neovate/skills")),
    t!("pochi", "Pochi", ".pochi/skills", ".pochi", Some(".pochi/skills")),
    t!("adal", "AdaL", ".adal/skills", ".adal", Some(".adal/skills")),
    t!("kilo_code", "Kilo Code", ".kilocode/skills", ".kilocode", Some(".kilocode/skills")),
    t!("roo_code", "Roo Code", ".roo/skills", ".roo", Some(".roo/skills")),
    t!("goose", "Goose", ".config/goose/skills", ".config/goose", Some(".goose/skills")),
    t!("gemini_cli", "Gemini CLI", ".gemini/skills", ".gemini", Some(".agents/skills")),
    t!("github_copilot", "GitHub Copilot", ".copilot/skills", ".copilot", Some(".agents/skills")),
    t!("clawdbot", "Clawdbot", ".clawdbot/skills", ".clawdbot", Some(".clawdbot/skills")),
    t!("droid", "Droid", ".factory/skills", ".factory", Some(".factory/skills")),
    t!("windsurf", "Windsurf", ".codeium/windsurf/skills", ".codeium/windsurf", Some(".windsurf/skills")),
    t!("moltbot", "MoltBot", ".moltbot/skills", ".moltbot", Some(".moltbot/skills")),
    t!("hermes_agent", "Hermes Agent", ".hermes/skills", ".hermes", None),
];
