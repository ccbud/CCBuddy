use axum::http::HeaderMap;
use serde_json::Value;
use std::collections::HashSet;

/// Default Claude tier models ccbud advertises to Claude-family clients (Claude Code).
pub const CLAUDE_TIER_MODELS: &[&str] = &[
    "claude-fable-5",
    "claude-opus-4-8",
    "claude-sonnet-5",
    "claude-haiku-4-5",
    "claude-haiku-4-5-20251001",
];

/// Stable Codex model identities advertised by the gateway. These names are understood by the
/// current Codex CLI and keep its ordinary function/custom tool registry enabled; synthetic
/// `gpt-5.6-sol*` identities select Codex's code-mode metadata and produce an empty Responses
/// `tools` array against a generic custom provider.
pub const CODEX_TIER_MODELS: &[&str] = &["gpt-5.4", "gpt-5.4-mini"];

/// Which coding-agent family a model name belongs to. Claude Code sends `claude-*`,
/// Codex sends `gpt-*`; each names its primary vs fast tier differently.
enum ModelFamily {
    Claude,
    Codex,
    Other,
}
fn model_family(name: &str) -> ModelFamily {
    let n = name.to_ascii_lowercase();
    if n.starts_with("claude-") || n.starts_with("claude_") {
        ModelFamily::Claude
    } else if n.starts_with("gpt-") || n.starts_with("gpt_") {
        ModelFamily::Codex
    } else {
        ModelFamily::Other
    }
}
/// Claude fast/light tier = the haiku models; fable/opus/sonnet (and any other
/// claude-*) route to the primary model.
fn is_claude_fast(name: &str) -> bool {
    name.to_ascii_lowercase().contains("haiku")
}
/// The stable auto-connect identity and legacy `sol` / `terra` aliases route to primary. Explicit
/// small-model identities route to fast; other foreign `gpt-*` names retain the historical fast
/// fallback instead of unexpectedly consuming the primary provider model.
fn is_codex_primary(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    if lower == "gpt-5.4" {
        return true;
    }
    let segments = lower
        .split(|c| c == '-' || c == '_')
        .collect::<Vec<_>>();
    !segments
        .iter()
        .any(|seg| matches!(*seg, "mini" | "nano" | "luna" | "spark"))
        && segments.iter().any(|seg| matches!(*seg, "sol" | "terra"))
}
/// True if the request comes from a Codex/OpenAI-family client (vs Claude), detected by
/// the client's self-reported identity — User-Agent, or Codex's `originator` header.
pub(super) fn client_is_codex(h: &HeaderMap) -> bool {
    let field = |k: &str| h.get(k).and_then(|v| v.to_str().ok()).unwrap_or("").to_ascii_lowercase();
    field("user-agent").contains("codex") || field("originator").contains("codex")
}

#[derive(Debug, Clone)]
pub struct Routing {
    pub provider_id: String,
    pub outgoing_model: Option<String>,
    pub client_facing_model: Option<String>,
}

/// Decide how to route a request and translate its model name. Mirrors proxy.js `resolveRouting`.
pub fn resolve_routing(
    requested_model: Option<&str>,
    config: &Value,
    known_models: Option<&HashSet<String>>,
) -> Option<Routing> {
    let providers = config.get("providers")?.as_array()?;
    if providers.is_empty() {
        return None;
    }
    let active_id = config.get("activeProviderId").and_then(|v| v.as_str());
    let active = providers
        .iter()
        .find(|p| p.get("id").and_then(|v| v.as_str()) == active_id)
        .or_else(|| providers.first())?;
    let pid = active.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string();

    let pass = |m: &str| {
        Some(Routing {
            provider_id: pid.clone(),
            outgoing_model: Some(m.to_string()),
            client_facing_model: Some(m.to_string()),
        })
    };

    let requested = match requested_model {
        None => {
            return Some(Routing {
                provider_id: pid.clone(),
                outgoing_model: None,
                client_facing_model: None,
            })
        }
        Some(m) => m,
    };

    let primary = active.get("defaultModel").and_then(|v| v.as_str()).unwrap_or("");
    let light = active.get("smallFastModel").and_then(|v| v.as_str()).unwrap_or("");
    let models = active.get("models").and_then(|v| v.as_array());

    if let Some(ms) = models {
        for m in ms {
            let alias = m.get("alias").and_then(|v| v.as_str()).unwrap_or("");
            let upstream = m.get("upstream").and_then(|v| v.as_str()).unwrap_or("");
            if !alias.is_empty() && alias == requested && !upstream.is_empty() {
                return Some(Routing {
                    provider_id: pid.clone(),
                    outgoing_model: Some(upstream.to_string()),
                    client_facing_model: Some(requested.to_string()),
                });
            }
        }
    }
    if requested == primary || requested == light {
        return pass(requested);
    }
    if let Some(ms) = models {
        for m in ms {
            if m.get("upstream").and_then(|v| v.as_str()) == Some(requested) {
                return pass(requested);
            }
        }
    }
    if let Some(known) = known_models {
        if known.contains(requested) {
            return pass(requested);
        }
    }
    // Codex connects with the sentinel model "gpt-5.5-ccbud" — a name Codex's model-family
    // detection accepts (gpt-5.5 prefix), so it doesn't warn about an unknown model. Route the
    // sentinel to the active provider's PRIMARY model (never the lightweight fallback).
    if requested.ends_with("-ccbud") {
        let target = if !primary.is_empty() { primary } else { light };
        if !target.is_empty() {
            return Some(Routing {
                provider_id: pid.clone(),
                outgoing_model: Some(target.to_string()),
                client_facing_model: Some(requested.to_string()),
            });
        }
    }
    let map_default = active
        .get("mapDefaultModels")
        .map(|v| v.as_bool().unwrap_or(true))
        .unwrap_or(true);
    if !map_default {
        return pass(requested);
    }
    let big = if !primary.is_empty() { primary } else { light };
    let small = if !light.is_empty() { light } else { primary };
    // Claude and Codex name their primary vs fast tiers differently, so classify by
    // family: claude-haiku* → fast, other claude-* → primary; gpt-*-sol / gpt-*-terra
    // → primary, other gpt-* → fast; anything else → fast.
    let target = match model_family(requested) {
        ModelFamily::Claude => if is_claude_fast(requested) { small } else { big },
        ModelFamily::Codex => if is_codex_primary(requested) { big } else { small },
        ModelFamily::Other => small,
    };
    if !target.is_empty() {
        return Some(Routing {
            provider_id: pid.clone(),
            outgoing_model: Some(target.to_string()),
            client_facing_model: Some(requested.to_string()),
        });
    }
    pass(requested)
}
