/// Mirror of the renderer's formatCodexBootstrap (conversations.js / runtime.js): Codex records
/// its initial AGENTS.md instructions + environment snapshot as one XML-ish user text block, and
/// the panel renders it as compact Markdown — search must index that same Markdown, not the raw
/// transport shape. None = not a bootstrap message (ordinary prose passes through untouched).
fn format_codex_bootstrap(source: &str) -> Option<String> {
    static AGENTS_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static ENV_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static ROOT_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let agents_re = AGENTS_RE.get_or_init(|| {
        regex::Regex::new(
            r"(?is)^\s*#\s+AGENTS\.md instructions for ([^\r\n]+).*?<INSTRUCTIONS\b[^>]*>(.*?)</INSTRUCTIONS>",
        )
        .unwrap()
    });
    let env_re = ENV_RE.get_or_init(|| {
        regex::Regex::new(r"(?is)<environment_context\b[^>]*>(.*?)</environment_context>").unwrap()
    });
    let root_re =
        ROOT_RE.get_or_init(|| regex::Regex::new(r"(?is)<root\b[^>]*>(.*?)</root>").unwrap());
    let agents = agents_re.captures(source)?;

    // Dynamic per-name regexes are fine here: at most one bootstrap message exists per session.
    let tag = |block: &str, name: &str| -> String {
        regex::Regex::new(&format!(r"(?is)<{name}\b[^>]*>(.*?)</{name}>"))
            .ok()
            .and_then(|re| re.captures(block).and_then(|c| c.get(1).map(|m| m.as_str().trim().to_string())))
            .unwrap_or_default()
    };
    let attr = |block: &str, name: &str, attribute: &str| -> String {
        regex::Regex::new(&format!(r#"(?i)<{name}\b[^>]*\b{attribute}=["']([^"']+)["']"#))
            .ok()
            .and_then(|re| re.captures(block).and_then(|c| c.get(1).map(|m| m.as_str().trim().to_string())))
            .unwrap_or_default()
    };
    let code = |value: &str| -> String {
        if value.is_empty() { String::new() } else { format!("`{}`", value) }
    };

    let mut parts: Vec<String> =
        vec![format!("# AGENTS.md instructions for {}", agents.get(1).map(|m| m.as_str().trim()).unwrap_or(""))];
    let instructions = agents.get(2).map(|m| m.as_str().trim()).unwrap_or("");
    if !instructions.is_empty() {
        let lines: Vec<&str> = instructions.lines().filter(|line| !line.trim().is_empty()).collect();
        parts.push(if lines.len() == 1 {
            format!("**INSTRUCTIONS:** {}", lines[0].trim())
        } else {
            format!("**INSTRUCTIONS:**\n\n{}", instructions)
        });
    }

    let env = env_re.captures(source);
    if let Some(env) = &env {
        let block = env.get(1).map(|m| m.as_str()).unwrap_or("");
        let roots: Vec<String> = root_re
            .captures_iter(block)
            .filter_map(|c| c.get(1).map(|m| m.as_str().trim().to_string()))
            .filter(|r| !r.is_empty())
            .map(|r| code(&r))
            .collect();
        let fields: Vec<(&str, String)> = vec![
            ("environment_context", code(&tag(block, "cwd"))),
            ("shell", tag(block, "shell")),
            ("current_date", tag(block, "current_date")),
            ("timezone", tag(block, "timezone")),
            ("workspace_roots", roots.join(", ")),
            ("permission_profile", attr(block, "permission_profile", "type")),
            ("file_system", attr(block, "file_system", "type")),
        ]
        .into_iter()
        .filter(|(_, value)| !value.is_empty())
        .collect();
        if !fields.is_empty() {
            parts.push(
                fields
                    .iter()
                    .map(|(name, value)| format!("**{}:** {}", name, value))
                    .collect::<Vec<_>>()
                    .join("  \n"),
            );
        }
    }

    let mut rest = source.replacen(agents.get(0).map(|m| m.as_str()).unwrap_or(""), "", 1);
    if let Some(env) = &env {
        rest = rest.replacen(env.get(0).map(|m| m.as_str()).unwrap_or(""), "", 1);
    }
    let rest = rest.trim();
    if !rest.is_empty() {
        parts.push(rest.to_string());
    }
    Some(parts.join("\n\n").trim().to_string())
}

/// Strip harness-injected blocks from user prose — MUST stay rule-for-rule in sync with the
/// renderer's stripInjected (conversations.js) and the export viewer's copy (runtime.js), so what
/// the big search matches is exactly what the in-conversation search (and the panel) will show.
/// The Codex AGENTS bootstrap reformats to the same Markdown the panel renders; task-notification
/// envelopes keep their human-facing <result> body; the transport metadata (ids, status, summary)
/// is dropped and must therefore never be searchable.
pub(super) fn strip_injected(s: &str) -> String {
    static SKILL_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static TASK_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static RESULT_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    // Same rule order as the JS: the Codex AGENTS bootstrap is reformatted FIRST, then the
    // envelope rules run over the (possibly rewritten) text.
    let bootstrap = format_codex_bootstrap(s);
    let s: &str = bootstrap.as_deref().unwrap_or(s);
    // A turn that is nothing but a <skill> envelope is Codex's recorded skill-instruction
    // injection — runtime context the panel suppresses wholesale, so search must too. Prose that
    // merely quotes <skill> markup alongside other text stays searchable.
    let skill_re = SKILL_RE
        .get_or_init(|| regex::Regex::new(r"(?is)^\s*<skill\b[^>]*>.*</skill>\s*$").unwrap());
    if skill_re.is_match(s) {
        return String::new();
    }
    let task_re = TASK_RE.get_or_init(|| {
        regex::Regex::new(r"(?is)<task-notification\b[^>]*>.*?</task-notification>").unwrap()
    });
    let result_re =
        RESULT_RE.get_or_init(|| regex::Regex::new(r"(?is)<result\b[^>]*>(.*?)</result>").unwrap());
    let re = RE.get_or_init(|| {
        regex::Regex::new(
            r"(?s)<system-reminder>.*?</system-reminder>|<command-[a-z-]+>.*?</command-[a-z-]+>|<local-command-[a-z]+>.*?</local-command-[a-z]+>",
        )
        .unwrap()
    });
    let unwrapped = task_re.replace_all(s, |caps: &regex::Captures| {
        result_re
            .captures(caps.get(0).map(|m| m.as_str()).unwrap_or(""))
            .and_then(|c| c.get(1))
            .map(|m| format!("\n{}\n", m.as_str().trim()))
            .unwrap_or_default()
    });
    re.replace_all(&unwrapped, "").trim().to_string()
}
