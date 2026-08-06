use serde_json::{json, Value};
use std::collections::HashSet;

use super::routing::{resolve_routing, Routing};

/// In-binary equivalent of test/selftest.js's 8 routing unit checks.
pub fn routing_selftest() -> Value {
    let config = json!({ "port":0, "activeProviderId":"glm", "providers":[
        { "id":"glm","name":"GLM","baseUrl":"https://x","authToken":"","defaultModel":"glm-5.1","smallFastModel":"glm-5.1","mapDefaultModels":true,"models":[{"alias":"claude-opus-4.8[1m]","upstream":"glm-5.1"}] }
    ]});
    let cfg2 = json!({ "port":0, "activeProviderId":"main", "providers":[
        { "id":"main","name":"Main","baseUrl":"http://127.0.0.1:1","authToken":"k","defaultModel":"big-model","smallFastModel":"small-model","mapDefaultModels":true,"models":[{"alias":"my-alias","upstream":"aliased-up"}] },
        { "id":"other","name":"Other","baseUrl":"http://127.0.0.1:2","authToken":"k","defaultModel":"other-big","smallFastModel":"other-small","mapDefaultModels":true,"models":[{"alias":"other-alias","upstream":"other-up"}] }
    ]});
    let off = json!({ "port":0, "activeProviderId":"m", "providers":[
        { "id":"m","name":"M","baseUrl":"http://127.0.0.1:1","authToken":"k","defaultModel":"big","smallFastModel":"small","mapDefaultModels":false,"models":[] }
    ]});

    let out = |r: &Option<Routing>| r.as_ref().and_then(|x| x.outgoing_model.clone());
    let cf = |r: &Option<Routing>| r.as_ref().and_then(|x| x.client_facing_model.clone());
    let pidf = |r: &Option<Routing>| r.as_ref().map(|x| x.provider_id.clone());

    let mut fails: Vec<String> = vec![];
    let mut n = 0;
    let mut chk = |name: &str, cond: bool| {
        n += 1;
        if !cond {
            fails.push(name.to_string());
        }
    };

    let r = resolve_routing(Some("claude-opus-4.8[1m]"), &config, None);
    chk("1 alias→upstream", out(&r).as_deref() == Some("glm-5.1") && cf(&r).as_deref() == Some("claude-opus-4.8[1m]"));
    let r = resolve_routing(Some("glm-5.1"), &config, None);
    chk("2 real passthrough", out(&r).as_deref() == Some("glm-5.1") && cf(&r).as_deref() == Some("glm-5.1"));
    let r = resolve_routing(Some("claude-3-5-haiku-20241022"), &cfg2, None);
    chk("3 haiku→light", out(&r).as_deref() == Some("small-model"));
    let r = resolve_routing(Some("claude-sonnet-4-6"), &cfg2, None);
    chk("4 sonnet→primary", out(&r).as_deref() == Some("big-model"));
    let r = resolve_routing(Some("gpt-4-turbo"), &cfg2, None);
    chk("5 foreign→light", out(&r).as_deref() == Some("small-model"));
    let mut known = HashSet::new();
    known.insert("glm-5.2".to_string());
    let r = resolve_routing(Some("glm-5.2"), &cfg2, Some(&known));
    chk("6 known passthrough", out(&r).as_deref() == Some("glm-5.2"));
    let r = resolve_routing(Some("other-alias"), &cfg2, None);
    chk("7 stays on active", pidf(&r).as_deref() == Some("main") && out(&r).as_deref() == Some("small-model"));
    let r = resolve_routing(Some("whatever-x"), &off, None);
    chk("8 mapoff passthrough", out(&r).as_deref() == Some("whatever-x"));
    let r = resolve_routing(Some("gpt-5.5-ccbud"), &cfg2, None);
    chk(
        "9 codex sentinel→primary",
        out(&r).as_deref() == Some("big-model") && cf(&r).as_deref() == Some("gpt-5.5-ccbud"),
    );

    json!({ "total": n, "passed": n - fails.len(), "failed": fails.len(), "fails": fails })
}
