// The embedded viewer assets (skin, runtime parts, vendored marked/highlight.js) and the
// per-field size caps. Moved verbatim from exporthtml.rs — the include_str! paths gained one
// `../` because this file sits one directory deeper.

pub(super) const SKIN: &str = include_str!("../../../src/main/export-assets/skin.css");
// The viewer runtime ships as four source parts (each within the repo's module-size limit)
// concatenated verbatim into one <script> block — they share a single IIFE closure, so the
// order here IS the source order and must not change.
pub(super) const RUNTIME: &str = concat!(
    include_str!("../../../src/main/export-assets/runtime-analytics.js"),
    include_str!("../../../src/main/export-assets/runtime-render.js"),
    include_str!("../../../src/main/export-assets/runtime-messages.js"),
    include_str!("../../../src/main/export-assets/runtime-ui.js"),
);
pub(super) const MARKED: &str = include_str!("../../../src/renderer/vendor/marked.umd.js");
pub(super) const HLJS: &str = include_str!("../../../src/renderer/vendor/highlight.min.js");
pub(super) const HLJS_CSS: &str = include_str!("../../../src/renderer/vendor/hljs-dark.css");

pub(super) const CAP_TEXT: usize = 24000;
pub(super) const CAP_THINKING: usize = 16000;
pub(super) const CAP_RESULT: usize = 24000;
pub(super) const CAP_PROMPT: usize = 9000;
pub(super) const CAP_CONTENT: usize = 14000;
pub(super) const CAP_SKILL_SNAPSHOT: usize = 131072;
