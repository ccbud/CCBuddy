use crate::protocol::codex_history::{HistoryResolution, ResponseOrigin};

use super::responses_history::{
    decide_responses_compact_history, decide_responses_history, ResponsesForwardMode,
    ResponsesHistoryDecision, ResponsesHistoryError,
};
use super::sse::{responses_terminal_event, ResponsesTerminalKind};

#[test]
fn responses_history_policy_covers_native_and_translated_provider_switches() {
    let known = |origin: ResponseOrigin, materializable: bool| HistoryResolution {
        changed: 3,
        had_previous_response_id: true,
        previous_found: true,
        previous_materialized: materializable,
        previous_origin: Some(origin),
    };
    let portable = ResponsesHistoryDecision {
        forward: ResponsesForwardMode::Materialized,
        descendant_materializable: true,
    };

    // Native Responses A → translated chat/Anthropic.
    assert_eq!(
        decide_responses_history(
            crate::protocol::Wire::OpenAiChat,
            "provider-chat",
            &known(ResponseOrigin::Native("provider-a".to_string()), true),
        ),
        Ok(portable)
    );
    // Translated/local → native Responses.
    assert_eq!(
        decide_responses_history(
            crate::protocol::Wire::OpenAiResponses,
            "provider-b",
            &known(ResponseOrigin::Local, true),
        ),
        Ok(portable)
    );
    // Native Responses A → native Responses B.
    assert_eq!(
        decide_responses_history(
            crate::protocol::Wire::OpenAiResponses,
            "provider-b",
            &known(ResponseOrigin::Native("provider-a".to_string()), true),
        ),
        Ok(portable)
    );
    // Same native owner keeps the provider-side id while the materialized local copy is retained
    // for recording its descendant.
    assert_eq!(
        decide_responses_history(
            crate::protocol::Wire::OpenAiResponses,
            "provider-a",
            &known(ResponseOrigin::Native("provider-a".to_string()), true),
        ),
        Ok(ResponsesHistoryDecision {
            forward: ResponsesForwardMode::Original,
            descendant_materializable: true,
        })
    );
    assert_eq!(
        decide_responses_history(
            crate::protocol::Wire::OpenAiResponses,
            "provider-a",
            &known(ResponseOrigin::Native("provider-a".to_string()), false),
        ),
        Ok(ResponsesHistoryDecision {
            forward: ResponsesForwardMode::Original,
            descendant_materializable: false,
        })
    );

    let missing = HistoryResolution {
        had_previous_response_id: true,
        ..HistoryResolution::default()
    };
    assert_eq!(
        decide_responses_history(
            crate::protocol::Wire::OpenAiResponses,
            "provider-a",
            &missing,
        ),
        Ok(ResponsesHistoryDecision {
            forward: ResponsesForwardMode::Original,
            descendant_materializable: false,
        })
    );
    assert_eq!(
        decide_responses_history(
            crate::protocol::Wire::Anthropic,
            "provider-anthropic",
            &missing,
        ),
        Err(ResponsesHistoryError::Unavailable)
    );
    assert_eq!(
        decide_responses_history(
            crate::protocol::Wire::OpenAiResponses,
            "provider-a",
            &HistoryResolution {
                changed: 2,
                ..HistoryResolution::default()
            },
        ),
        Ok(ResponsesHistoryDecision {
            forward: ResponsesForwardMode::Materialized,
            descendant_materializable: true,
        })
    );
    assert_eq!(
        decide_responses_history(
            crate::protocol::Wire::OpenAiResponses,
            "provider-b",
            &known(ResponseOrigin::Local, false),
        ),
        Err(ResponsesHistoryError::Unavailable)
    );
}
#[test]
fn responses_compact_localizes_portable_foreign_history_and_allows_owner_or_cache_miss() {
    let known = |origin: ResponseOrigin, materializable: bool| HistoryResolution {
        changed: 2,
        had_previous_response_id: true,
        previous_found: true,
        previous_materialized: materializable,
        previous_origin: Some(origin),
    };
    let missing = HistoryResolution {
        had_previous_response_id: true,
        ..HistoryResolution::default()
    };
    assert_eq!(
        decide_responses_compact_history("provider-a", &missing),
        Ok(ResponsesForwardMode::Original)
    );
    assert_eq!(
        decide_responses_compact_history(
            "provider-a",
            &known(ResponseOrigin::Native("provider-a".to_string()), false),
        ),
        Ok(ResponsesForwardMode::Original)
    );
    for origin in [
        ResponseOrigin::Local,
        ResponseOrigin::Native("provider-b".to_string()),
    ] {
        assert_eq!(
            decide_responses_compact_history("provider-a", &known(origin, true)),
            Ok(ResponsesForwardMode::Materialized)
        );
    }
    assert_eq!(
        decide_responses_compact_history(
            "provider-a",
            &known(ResponseOrigin::Local, false),
        ),
        Err(ResponsesHistoryError::Unavailable)
    );
}
#[test]
fn responses_terminal_parser_keeps_completed_and_incomplete_but_marks_failed() {
    for (event_type, status, expected) in [
        (
            "response.completed",
            "completed",
            ResponsesTerminalKind::Completed,
        ),
        (
            "response.incomplete",
            "incomplete",
            ResponsesTerminalKind::Incomplete,
        ),
        ("response.failed", "failed", ResponsesTerminalKind::Failed),
    ] {
        let sse = format!(
            "event: {event_type}\ndata: {{\"type\":\"{event_type}\",\"response\":{{\"id\":\"resp_1\",\"object\":\"response\",\"status\":\"{status}\",\"output\":[]}}}}\n\n"
        );
        let terminal = responses_terminal_event(&sse).unwrap();
        assert_eq!(terminal.kind, expected);
        assert_eq!(terminal.kind.is_resumable(), status != "failed");
        assert_eq!(terminal.response.as_ref().unwrap()["status"], status);
    }
    assert!(responses_terminal_event(
        "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"
    )
    .is_none());
}
