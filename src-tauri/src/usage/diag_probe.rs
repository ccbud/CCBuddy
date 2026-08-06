use super::*;
use serde_json::json;
#[test]
#[ignore]
fn probe_diag() {
    let Ok(dir) = std::env::var("CCBUD_PROBE_DIR") else { return };
    eprintln!("{}", diag(&json!({ "historyDirs": [dir] }), "all"));
}
