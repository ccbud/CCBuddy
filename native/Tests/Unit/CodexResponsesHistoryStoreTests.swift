import XCTest
@testable import CCBuddy

final class CodexResponsesHistoryStoreTests: XCTestCase {
    func testRestoresAndEnrichesCallsWithinScopeOnly() async throws {
        let store = CodexResponsesHistoryStore()
        let recorded = await store.recordResponse(
            scope: "session-a",
            request: json(#"{"input":[]}"#),
            response: json(#"""
            {
                "id":"resp_1","status":"completed","output":[{
                    "type":"function_call","call_id":"call_1","name":"read_file",
                    "arguments":"{\"path\":\"README.md\"}",
                    "reasoning_content":"Need the file."
                }]
            }
            """#)
        )
        XCTAssertEqual(recorded, 1)

        let followUp = json(#"""
        {
            "previous_response_id":"resp_1","input":[{
                "type":"function_call_output","call_id":"call_1","output":"ok"
            }]
        }
        """#)
        let resolved = await store.enrichRequest(scope: "session-a", body: followUp)
        XCTAssertEqual(resolved.changed, 1)
        let input = try XCTUnwrap(resolved.body["input"]?.arrayValue)
        XCTAssertEqual(input.map { $0["type"]?.stringValue }, [
            "function_call", "function_call_output",
        ])
        XCTAssertEqual(input[0]["name"]?.stringValue, "read_file")
        XCTAssertEqual(input[0]["reasoning_content"]?.stringValue, "Need the file.")

        let crossed = await store.enrichRequest(
            scope: "session-b",
            allowCallIDFallback: true,
            body: followUp
        )
        XCTAssertEqual(crossed.changed, 0)
        XCTAssertEqual(crossed.body, followUp)
    }

    func testMultipleHopsRestoreCompleteTranscriptAndExplicitHistoryIsIdempotent() async throws {
        let store = CodexResponsesHistoryStore()
        let firstRequest = json(#"""
        {
            "input":[{"type":"message","role":"user","content":"First question."}]
        }
        """#)
        await store.recordResponse(
            request: firstRequest,
            response: json(#"""
            {
                "id":"resp_first","status":"completed","output":[{
                    "type":"message","id":"msg_first","role":"assistant",
                    "content":[{"type":"output_text","text":"First answer."}]
                }]
            }
            """#)
        )

        let second = await store.enrichRequest(body: json(#"""
        {
            "previous_response_id":"resp_first",
            "input":[{"type":"message","role":"user","content":"Second question."}]
        }
        """#))
        XCTAssertEqual(second.changed, 2)
        await store.recordResponse(
            request: second.body,
            response: json(#"""
            {
                "id":"resp_second","status":"completed","output":[{
                    "type":"message","id":"msg_second","role":"assistant",
                    "content":[{"type":"output_text","text":"Second answer."}]
                }]
            }
            """#)
        )

        let third = await store.enrichRequest(body: json(#"""
        {
            "previous_response_id":"resp_second",
            "input":[{"type":"message","role":"user","content":"Third question."}]
        }
        """#))
        XCTAssertEqual(third.changed, 4)
        let items = try XCTUnwrap(third.body["input"]?.arrayValue)
        XCTAssertEqual(items.compactMap(Self.itemText), [
            "First question.", "First answer.", "Second question.",
            "Second answer.", "Third question.",
        ])

        let again = await store.enrichRequest(body: third.body)
        XCTAssertEqual(again.changed, 0)
        XCTAssertEqual(again.body, third.body)
    }

    func testParallelCallsKeepResponseOrderAndExistingCallIsEnriched() async throws {
        let store = CodexResponsesHistoryStore()
        await store.recordResponse(
            request: json(#"{"input":[]}"#),
            response: json(#"""
            {
                "id":"resp_parallel","status":"completed","output":[
                    {"type":"function_call","call_id":"call_a","name":"first","arguments":"{}"},
                    {"type":"function_call","call_id":"call_b","name":"second","arguments":"{}"}
                ]
            }
            """#)
        )
        let result = await store.enrichRequest(body: json(#"""
        {
            "previous_response_id":"resp_parallel","input":[
                {"type":"function_call","call_id":"call_a"},
                {"type":"function_call_output","call_id":"call_b","output":"two"},
                {"type":"function_call_output","call_id":"call_a","output":"one"}
            ]
        }
        """#))
        XCTAssertEqual(result.changed, 2, "one missing call plus one enriched explicit call")
        let input = try XCTUnwrap(result.body["input"]?.arrayValue)
        XCTAssertEqual(input.compactMap { $0["call_id"]?.stringValue }, [
            "call_a", "call_b", "call_b", "call_a",
        ])
        XCTAssertEqual(input[0]["name"]?.stringValue, "first")
        XCTAssertEqual(input[1]["name"]?.stringValue, "second")
    }

    func testUniqueCallFallbackUsesOneCompleteBranchOnly() async throws {
        let store = CodexResponsesHistoryStore()
        for (responseID, callID, prompt) in [
            ("resp_a", "call_a", "branch a"),
            ("resp_b", "call_b", "branch b"),
        ] {
            await store.recordResponse(
                scope: "scope",
                request: .object(["input": .array([.object([
                    "type": .string("message"),
                    "role": .string("user"),
                    "content": .string(prompt),
                ])])]),
                response: .object([
                    "id": .string(responseID),
                    "status": .string("completed"),
                    "output": .array([.object([
                        "type": .string("function_call"),
                        "call_id": .string(callID),
                        "name": .string("lookup"),
                        "arguments": .string("{}"),
                    ])]),
                ])
            )
        }
        let one = await store.materializeRequest(
            scope: "scope",
            allowCallIDFallback: true,
            body: json(#"""
            {"input":[{
                "type":"function_call_output","call_id":"call_a","output":"a"
            }]}
            """#)
        )
        XCTAssertEqual(one.changed, 2)
        XCTAssertEqual(one.body["input"]?.arrayValue?.first?["content"]?.stringValue, "branch a")

        let mixed = await store.enrichRequest(
            scope: "scope",
            allowCallIDFallback: true,
            body: json(#"""
            {"input":[
                {"type":"function_call_output","call_id":"call_a","output":"a"},
                {"type":"function_call_output","call_id":"call_b","output":"b"}
            ]}
            """#)
        )
        XCTAssertEqual(mixed.changed, 0)
    }

    func testNativeOwnershipAndMaterializabilityArePreserved() async throws {
        let store = CodexResponsesHistoryStore()
        await store.recordResponse(
            scope: "native",
            origin: .native(providerID: "provider-a"),
            request: json(#"{"input":"first"}"#),
            response: json(#"""
            {
                "id":"resp_native","object":"response","status":"incomplete","output":[{
                    "type":"message","id":"msg_native","role":"assistant",
                    "content":[{"type":"output_text","text":"answer"}]
                }]
            }
            """#)
        )
        let portable = await store.materializeRequest(
            scope: "native",
            allowCallIDFallback: true,
            body: json(#"{"previous_response_id":"resp_native","input":"second"}"#)
        )
        XCTAssertTrue(portable.resolution.previousFound)
        XCTAssertTrue(portable.resolution.previousMaterialized)
        XCTAssertEqual(portable.resolution.previousOrigin, .native(providerID: "provider-a"))
        XCTAssertNil(portable.body["previous_response_id"])
        XCTAssertEqual(portable.body["input"]?.arrayValue?.compactMap(Self.itemText), [
            "first", "answer", "second",
        ])

        await store.recordResponse(
            scope: "native",
            origin: .native(providerID: "provider-a"),
            materializable: false,
            request: json(#"{"input":"delta"}"#),
            response: json(#"""
            {
                "id":"resp_owner","status":"completed","output":[{
                    "type":"function_call","call_id":"owner_call","name":"shell","arguments":"{}"
                }]
            }
            """#)
        )
        let ownerRequest = json(#"{"previous_response_id":"resp_owner","input":"next"}"#)
        let owner = await store.materializeRequest(
            scope: "native",
            allowCallIDFallback: true,
            body: ownerRequest
        )
        XCTAssertTrue(owner.resolution.previousFound)
        XCTAssertFalse(owner.resolution.previousMaterialized)
        XCTAssertEqual(owner.body, ownerRequest)
    }

    func testTerminalFilteringUnsupportedOutputAndOversizedReplacement() async throws {
        let store = CodexResponsesHistoryStore(maximumBytes: 1_024)
        let request = json(#"{"input":"keep"}"#)
        let failed = await store.recordResponse(
            request: request,
            response: json(#"{"id":"failed","status":"failed","output":[]}"#)
        )
        XCTAssertEqual(failed, 0)
        let failedMetadata = await store.responseMetadata(responseID: "failed")
        XCTAssertNil(failedMetadata)

        await store.recordResponse(
            origin: .native(providerID: "provider-a"),
            request: request,
            response: json(#"""
            {
                "id":"unsupported","object":"response","status":"completed",
                "output":[{"type":"computer_call","id":"computer_1"}]
            }
            """#)
        )
        let unsupportedMetadata = await store.responseMetadata(responseID: "unsupported")
        XCTAssertEqual(unsupportedMetadata?.materializable, false)

        let kept = await store.recordResponse(
            request: request,
            response: json(#"""
            {
                "id":"keep","status":"completed","output":[{
                    "type":"function_call","call_id":"keep_call","name":"keep","arguments":"{}"
                }]
            }
            """#)
        )
        XCTAssertEqual(kept, 1)
        let huge = String(repeating: "x", count: 4_096)
        let hugeRequest: HistoryValue = .object(["input": .string(huge)])
        let hugeResponse: HistoryValue = .object([
            "id": .string("huge"),
            "status": .string("completed"),
            "output": .array([.object([
                "type": .string("message"),
                "role": .string("assistant"),
                "content": .string(huge),
            ])]),
        ])
        let rejectedHuge = await store.recordResponse(
            request: hugeRequest,
            response: hugeResponse
        )
        XCTAssertEqual(rejectedHuge, 0)
        let keepMetadata = await store.responseMetadata(responseID: "keep")
        XCTAssertNotNil(keepMetadata)

        var replacementObject = hugeResponse.objectValue!
        replacementObject["id"] = .string("keep")
        let rejectedReplacement = await store.recordResponse(
            request: hugeRequest,
            response: .object(replacementObject)
        )
        XCTAssertEqual(rejectedReplacement, 0)
        let removedKeep = await store.responseMetadata(responseID: "keep")
        XCTAssertNil(removedKeep)
    }

    func testCountEvictionReplacementAndAmbiguousFallbackCleanReverseIndex() async throws {
        let store = CodexResponsesHistoryStore(maximumResponses: 2)
        func response(_ responseID: String, _ callID: String, _ name: String) -> HistoryValue {
            .object([
                "id": .string(responseID),
                "status": .string("completed"),
                "output": .array([.object([
                    "type": .string("function_call"),
                    "call_id": .string(callID),
                    "name": .string(name),
                    "arguments": .string("{}"),
                ])]),
            ])
        }
        let empty = json(#"{"input":[]}"#)
        await store.recordResponse(
            scope: "scope", request: empty,
            response: response("resp_old", "call_old", "old")
        )
        await store.recordResponse(
            scope: "scope", request: empty,
            response: response("resp_shared_a", "shared", "first")
        )
        await store.recordResponse(
            scope: "scope", request: empty,
            response: response("resp_shared_b", "shared", "second")
        )
        let statistics = await store.statistics()
        XCTAssertEqual(statistics.responses, 2)

        let oldFallback = await store.enrichRequest(
            scope: "scope", allowCallIDFallback: true,
            body: callOutput("call_old")
        )
        XCTAssertEqual(oldFallback.changed, 0, "eviction removes the call reverse index")
        let ambiguous = await store.enrichRequest(
            scope: "scope", allowCallIDFallback: true,
            body: callOutput("shared")
        )
        XCTAssertEqual(ambiguous.changed, 0)

        await store.recordResponse(
            scope: "scope", request: empty,
            response: response("resp_shared_b", "replacement", "new")
        )
        let noStaleCall = await store.enrichRequest(
            scope: "scope", allowCallIDFallback: true,
            body: callOutput("shared")
        )
        XCTAssertEqual(noStaleCall.changed, 1)
        XCTAssertEqual(
            noStaleCall.body["input"]?.arrayValue?.first?["name"]?.stringValue,
            "first"
        )
        let replacement = await store.enrichRequest(
            scope: "scope", allowCallIDFallback: true,
            body: callOutput("replacement")
        )
        XCTAssertEqual(replacement.changed, 1)
        XCTAssertEqual(
            replacement.body["input"]?.arrayValue?.first?["name"]?.stringValue,
            "new"
        )
    }

    private static func json(_ text: String) -> HistoryValue {
        try! JSONDecoder().decode(HistoryValue.self, from: Data(text.utf8))
    }

    private func json(_ text: String) -> HistoryValue { Self.json(text) }

    private static func itemText(_ item: HistoryValue) -> String? {
        if let content = item["content"]?.stringValue { return content }
        return item["content"]?.arrayValue?.compactMap {
            $0["text"]?.stringValue
        }.joined(separator: "\n")
    }

    private func callOutput(_ callID: String) -> HistoryValue {
        .object(["input": .array([.object([
            "type": .string("function_call_output"),
            "call_id": .string(callID),
            "output": .string("ok"),
        ])])])
    }
}
