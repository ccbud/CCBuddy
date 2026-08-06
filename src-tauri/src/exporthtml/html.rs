// The single self-contained .html viewer page. Moved verbatim from exporthtml.rs.

use serde_json::Value;

use super::assets::{HLJS, HLJS_CSS, MARKED, RUNTIME, SKIN};
use super::build::build_data;

pub fn html_from_data(data: &Value) -> String {
    let json = serde_json::to_string(data)
        .unwrap_or_default()
        .replace('<', "\\u003c");
    // Tab title uses the project name (already public via the export's filename), NOT the
    // conversation title: Clarity reports document.title as page metadata that masking can't
    // reach, and the conversation title is first-message text. The full title still renders
    // in the viewer header, inside the Clarity-masked #app.
    let title = data
        .get("meta")
        .and_then(|m| m.get("project"))
        .and_then(|v| v.as_str())
        .unwrap_or("Conversation")
        .replace(['<', '>'], "");
    // The exported viewer is a static file opened in a plain browser (no app CSP). A nonce-based
    // CSP lets ONLY these four generator-emitted <script> blocks run: an injected inline handler
    // (e.g. an <img onerror> from a crafted image data-URL) or a `javascript:` link in a message
    // carries no nonce, so the browser refuses to execute it. The clarity.ms origins additionally
    // allow the Clarity analytics tag the runtime injects. img-src data: keeps inline images;
    // style-src 'unsafe-inline' keeps the embedded skin. Nonce is static (a local file has no
    // replay threat model — it only separates our scripts from attacker-injected markup).
    let csp = "default-src 'none'; script-src 'nonce-ccbudexport' https://www.clarity.ms https://*.clarity.ms; connect-src https://*.clarity.ms https://c.bing.com; style-src 'unsafe-inline'; img-src data:; base-uri 'none'";
    format!(
        "<!doctype html><html lang=\"zh\" data-theme=\"light\"><head><meta charset=\"utf-8\">\
<meta http-equiv=\"Content-Security-Policy\" content=\"{csp}\">\
<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\
<title>{title} · CC Buddy</title>\
<style>{skin}\n{hljscss}</style>\
</head><body><div id=\"app\" data-clarity-mask=\"true\"></div>\
<script nonce=\"ccbudexport\">{marked}</script>\
<script nonce=\"ccbudexport\">{hljs}</script>\
<script nonce=\"ccbudexport\">window.__CONV__={json};window.__CCBUD_VERSION__=\"{version}\";</script>\
<script nonce=\"ccbudexport\">{runtime}</script>\
</body></html>",
        csp = csp,
        title = title,
        skin = SKIN,
        hljscss = HLJS_CSS,
        marked = MARKED,
        hljs = HLJS,
        json = json,
        version = env!("CARGO_PKG_VERSION"),
        runtime = RUNTIME,
    )
}

pub fn build_export_html(file: &str) -> String {
    html_from_data(&build_data(file))
}
