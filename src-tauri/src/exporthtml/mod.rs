// Standalone conversation export → a single self-contained .html viewer. Rust port of exportHtml.js.
//
// Embeds the conversation as JSON plus a Claude-design skin (light/dark) + a client runtime
// (render + theme + search + expandable tools/subagents), with marked + highlight.js vendored.
// Heavy content fields are capped so the embedded JSON stays bounded.

#![allow(dead_code)]
mod assets;
mod build;
mod html;
mod name;
mod parse;
mod session;
mod shape;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_more;

pub use build::build_data;
pub use html::{build_export_html, html_from_data};
pub use name::{export_base_name, export_base_name_from_data};
