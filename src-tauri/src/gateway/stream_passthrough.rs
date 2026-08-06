use axum::{
    body::Body,
    http::{Method, StatusCode},
    response::Response,
};
use bytes::Bytes;
use futures_util::StreamExt;
use serde_json::{json, Value};
use std::sync::Arc;

use crate::protocol::codex_history::ResponseOrigin;

use super::capture::StreamAbortGuard;
use super::monitor::UsageAcc;
use super::redact::{now_ms, vec_headers};
use super::responses_history::NativeResponsesHistoryContext;
use super::routing::Routing;
use super::sse::{process_sse_line, responses_terminal_event};
use super::state::GatewayState;

#[allow(clippy::too_many_arguments)]
pub(super) fn stream_passthrough(
    st: &Arc<GatewayState>,
    resp: reqwest::Response,
    need_rewrite: bool,
    routing: Routing,
    method: Method,
    req_path: String,
    provider_name: String,
    status: StatusCode,
    ex_id: u64,
    started: std::time::Instant,
    out_headers: Vec<(String, String)>,
    ex_req_headers: Value,
    ex_req_body: Value,
    ex_client_req: Value,
    ex_translated: Option<String>,
    ex_url: String,
    native_responses_history: Option<NativeResponsesHistoryContext>,
    client_wire: crate::protocol::Wire,
) -> Response {
    let rewrite_model = if need_rewrite { routing.client_facing_model.clone() } else { None };
    let st2 = st.clone();
    let status_code = status.as_u16();
    let ex_id2 = ex_id;
    let started2 = started;
    let res_headers = vec_headers(&out_headers);
    let mut guard = StreamAbortGuard::new(
        st.clone(), ex_id, started, method.clone(), req_path.clone(), provider_name.clone(),
        routing.clone(), status_code,
        json!({
            "id": ex_id, "ts": now_ms(), "method": method.as_str(), "path": req_path, "url": ex_url,
            "provider": provider_name, "requestedModel": routing.client_facing_model,
            "outgoingModel": routing.outgoing_model, "clientFacingModel": routing.client_facing_model,
            "status": status_code, "reqHeaders": ex_req_headers, "reqBody": ex_req_body,
            "clientReq": ex_client_req, "translated": ex_translated,
            "resHeaders": res_headers,
            "resBody": json!({ "text": "", "bytes": 0, "truncated": 0 }),
        }),
        None,
    );
    let method2 = method.clone();
    let path2 = req_path.clone();
    let pname2 = provider_name.clone();
    let routing2 = routing.clone();
    let native_history = native_responses_history.clone();
    let native_responses_stream = client_wire == crate::protocol::Wire::OpenAiResponses;
    let body_stream = async_stream::stream! {
        let mut s = resp.bytes_stream();
        let mut buf = String::new();
        let mut usage = UsageAcc::default();
        let mut history_recorded = false;
        while let Some(chunk) = s.next().await {
            match chunk {
                Ok(bytes) => {
                    buf.push_str(&String::from_utf8_lossy(&bytes));
                    let mut out = String::new();
                    while let Some(idx) = buf.find('\n') {
                        let line: String = buf.drain(..=idx).collect();
                        out.push_str(&process_sse_line(&line, rewrite_model.as_deref(), &mut usage));
                    }
                    let terminal = native_responses_stream
                        .then(|| responses_terminal_event(&out))
                        .flatten();
                    guard.push_res(&out);
                    if let Some(terminal) = terminal {
                        guard.finished = true;
                        if !history_recorded
                            && (200..300).contains(&status_code)
                            && terminal.kind.is_resumable()
                        {
                            if let (Some(history), Some(response)) =
                                (native_history.as_ref(), terminal.response.as_ref())
                            {
                                st2.codex_history
                                    .record_response_scoped_with_metadata(
                                        &history.scope,
                                        ResponseOrigin::Native(history.provider_id.clone()),
                                        history.materializable,
                                        &history.request,
                                        response,
                                    )
                                    .await;
                            }
                        }
                        history_recorded = true;
                    }
                    guard.usage = Some(usage.clone());
                    if !out.is_empty() {
                        yield Ok::<Bytes, std::io::Error>(Bytes::from(out));
                    }
                }
                Err(error) => {
                    let message = format!("upstream stream transport error: {}", error);
                    st2.log("error", format!("{} ({})", message, pname2));
                    yield Err(std::io::Error::new(std::io::ErrorKind::Other, message));
                    return;
                }
            }
        }
        if !buf.is_empty() {
            let line = process_sse_line(&buf, rewrite_model.as_deref(), &mut usage);
            let terminal = native_responses_stream
                .then(|| responses_terminal_event(&line))
                .flatten();
            guard.push_res(&line);
            if let Some(terminal) = terminal {
                guard.finished = true;
                if !history_recorded
                    && (200..300).contains(&status_code)
                    && terminal.kind.is_resumable()
                {
                    if let (Some(history), Some(response)) =
                        (native_history.as_ref(), terminal.response.as_ref())
                    {
                        st2.codex_history
                            .record_response_scoped_with_metadata(
                                &history.scope,
                                ResponseOrigin::Native(history.provider_id.clone()),
                                history.materializable,
                                &history.request,
                                response,
                            )
                            .await;
                    }
                }
            }
            yield Ok(Bytes::from(line));
        }
        if native_responses_stream && !guard.finished {
            let message = "upstream Responses stream ended before a terminal event";
            st2.log("error", format!("{} ({})", message, pname2));
            yield Err(std::io::Error::new(std::io::ErrorKind::UnexpectedEof, message));
            return;
        }
        st2.emit_request(ex_id2, started2, &method2, &path2, &pname2, &routing2, status_code, Some(&usage));
        let mut ex = guard.complete();
        ex["ms"] = json!(started2.elapsed().as_millis() as u64);
        st2.record_exchange(ex).await;
    };
    let mut builder = Response::builder().status(status.as_u16());
    for (k, v) in &out_headers {
        builder = builder.header(k, v);
    }
    return builder.body(Body::from_stream(body_stream)).unwrap();
}
