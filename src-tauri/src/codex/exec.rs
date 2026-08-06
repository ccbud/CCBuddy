use serde_json::{json, Value};

// ---- code-mode `exec` scripts (custom_tool_call name "exec") ----
//
// Codex code-mode (gpt-*-sol) emits one custom tool named `exec` whose input is JavaScript
// calling `tools.*` (exec_command / write_stdin / …). The dominant shape by far is a single
// `tools.exec_command({cmd, workdir, …})` plus print plumbing (`text(r.output);` and friends) —
// semantically just a shell run, so it renders as the familiar Bash card (command + workdir).
// Anything else (write_stdin, Promise.all batches, real orchestration code) keeps the whole
// script as a `Script` card the renderer shows as highlighted JavaScript. Extraction is
// conservative: any parse doubt falls back to the Script card, never to a wrong command.

/// First `{…}` object literal at/after `from`, brace-matched with double-quoted strings (and
/// their escapes) treated as opaque — shell commands are full of braces and quotes.
fn extract_object(s: &str, from: usize) -> Option<(usize, usize)> {
    let start = from + s[from..].find('{')?;
    let (mut depth, mut in_str, mut esc) = (0i32, false, false);
    for (i, &b) in s.as_bytes().iter().enumerate().skip(start) {
        if in_str {
            if esc {
                esc = false;
            } else if b == b'\\' {
                esc = true;
            } else if b == b'"' {
                in_str = false;
            }
            continue;
        }
        match b {
            b'"' => in_str = true,
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return Some((start, i));
                }
            }
            _ => {}
        }
    }
    None
}

/// Quote bare JS object keys (`{cmd: …}` → `{"cmd": …}`) outside string context so serde can
/// parse code-mode's object-literal arguments; double-quoted string contents pass verbatim.
fn quote_js_keys(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len() + 16);
    let (mut in_str, mut esc) = (false, false);
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if in_str {
            if esc {
                esc = false;
            } else if c == '\\' {
                esc = true;
            } else if c == '"' {
                in_str = false;
            }
            out.push(c);
            i += 1;
            continue;
        }
        if c == '"' {
            in_str = true;
            out.push(c);
            i += 1;
            continue;
        }
        if c == '{' || c == ',' {
            out.push(c);
            i += 1;
            while i < chars.len() && chars[i].is_whitespace() {
                out.push(chars[i]);
                i += 1;
            }
            let start = i;
            while i < chars.len() && (chars[i].is_ascii_alphanumeric() || chars[i] == '_' || chars[i] == '$') {
                i += 1;
            }
            if i > start {
                let mut j = i;
                while j < chars.len() && chars[j].is_whitespace() {
                    j += 1;
                }
                let ident: String = chars[start..i].iter().collect();
                if j < chars.len() && chars[j] == ':' {
                    out.push('"');
                    out.push_str(&ident);
                    out.push('"');
                } else {
                    out.push_str(&ident);
                }
            }
            continue;
        }
        out.push(c);
        i += 1;
    }
    out
}

/// The `{…}` argument of a tools.* call: strict JSON first (code-mode usually emits JSON),
/// then a bare-key-quoted retry for JS object literals.
fn parse_call_args(obj: &str) -> Option<Value> {
    serde_json::from_str::<Value>(obj)
        .ok()
        .or_else(|| serde_json::from_str::<Value>(&quote_js_keys(obj)).ok())
        .filter(|v| v.is_object())
}

/// Code-mode exec script → renderer tool card (see module comment above).
pub(super) fn map_exec_script(script: &str) -> (String, Value) {
    let fallback = || ("Script".to_string(), json!({ "code": script }));
    // exactly one tools.* call, and it must be exec_command (a cmd string that itself mentions
    // "tools." trips the count — conservative fallback, never a wrong command)
    if script.matches("tools.").count() != 1 {
        return fallback();
    }
    let call = match script.find("tools.exec_command(") {
        Some(i) => i,
        None => return fallback(),
    };
    // prefix must be assignment/await plumbing only: `const r = await` / `let out = await` / `await`
    let prefix: Vec<&str> = script[..call].split_whitespace().collect();
    let prefix_ok = match prefix.as_slice() {
        [] | ["await"] => true,
        [kw, _name, "=", "await"] => matches!(*kw, "const" | "let" | "var"),
        _ => false,
    };
    if !prefix_ok {
        return fallback();
    }
    let after = call + "tools.exec_command(".len();
    let (ostart, oend) = match extract_object(script, after) {
        Some(span) => span,
        None => return fallback(),
    };
    if !script[after..ostart].trim().is_empty() {
        return fallback();
    }
    let args = match parse_call_args(&script[ostart..=oend]) {
        Some(a) => a,
        None => return fallback(),
    };
    let cmd = args
        .get("cmd")
        .or_else(|| args.get("command"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if cmd.is_empty() {
        return fallback();
    }
    // tail must close the call, then carry only print plumbing
    let rest = script[oend + 1..].trim_start();
    let rest = match rest.strip_prefix(')') {
        Some(r) => r,
        None => return fallback(),
    };
    let rest = rest.strip_prefix(';').unwrap_or(rest);
    let plumbing = rest.lines().all(|l| {
        let l = l.trim();
        l.is_empty() || l.starts_with("text(") || l.starts_with("if (") || l.starts_with("//")
    });
    if !plumbing {
        return fallback();
    }
    let mut input = json!({ "command": cmd });
    if let Some(wd) = args.get("workdir").and_then(|v| v.as_str()) {
        if !wd.is_empty() {
            input["description"] = json!(wd);
        }
    }
    ("Bash".into(), input)
}

/// Error heuristic for code-mode exec output text: the runner's own status header
/// ("Script failed…" / "Exit code: N…").
pub(super) fn exec_text_err(text: &str) -> bool {
    if text.starts_with("Script failed") {
        return true;
    }
    if let Some(rest) = text.strip_prefix("Exit code: ") {
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        return digits.parse::<i64>().map(|c| c != 0).unwrap_or(false);
    }
    false
}
