import Foundation

enum CodexResponseOrigin: Equatable, Sendable {
    case local
    case native(providerID: String)
}

struct CodexResponseMetadata: Equatable, Sendable {
    var origin: CodexResponseOrigin
    var materializable: Bool
}

struct CodexResponsesHistoryResolution: Equatable, Sendable {
    var changed: Int = 0
    var hadPreviousResponseID = false
    var previousFound = false
    var previousMaterialized = false
    var previousOrigin: CodexResponseOrigin?
}

struct CodexResponsesRequestResult: Equatable, Sendable {
    var body: HistoryValue
    var resolution: CodexResponsesHistoryResolution

    var changed: Int { resolution.changed }
}

struct CodexResponsesCacheStatistics: Equatable, Sendable {
    var responses: Int
    var indexedCalls: Int
    var serializedBytes: Int
}

/// Bounded cross-request history for OpenAI Responses continuations.
///
/// A chat-style upstream cannot resolve `previous_response_id` itself. This actor remembers the
/// complete model-visible request and supported assistant output for each terminal response, then
/// restores that prefix before conversion. Keys always include a caller-provided session scope so
/// response and call ids can never leak between clients.
actor CodexResponsesHistoryStore {
    static let maximumCachedResponses = 512
    static let maximumCachedHistoryBytes = 32 * 1_024 * 1_024

    private struct ResponseKey: Hashable, Sendable {
        var scope: String
        var responseID: String
    }

    private struct CallKey: Hashable, Sendable {
        var scope: String
        var callID: String
    }

    private struct CachedResponse: Sendable {
        var requestInput: [HistoryValue] = []
        var output: [HistoryValue] = []
        var callsByID: [String: HistoryValue] = [:]
        var callOrder: [String] = []
        var serializedBytes = 0
        var origin: CodexResponseOrigin = .local
        var materializable = false
    }

    private let maximumResponses: Int
    private let maximumBytes: Int
    private var responses: [ResponseKey: CachedResponse] = [:]
    private var responseOrder: [ResponseKey] = []
    private var callIndex: [CallKey: [ResponseKey]] = [:]
    private var cachedBytes = 0

    init(
        maximumResponses: Int = CodexResponsesHistoryStore.maximumCachedResponses,
        maximumBytes: Int = CodexResponsesHistoryStore.maximumCachedHistoryBytes
    ) {
        self.maximumResponses = max(0, maximumResponses)
        self.maximumBytes = max(0, maximumBytes)
    }

    /// Records only resumable terminal Responses objects (`completed` or `incomplete`).
    /// Unsupported input/output is still retained as owner-only metadata, but can never be
    /// materialized onto a different provider.
    @discardableResult
    func recordResponse(
        scope: String = "",
        origin: CodexResponseOrigin = .local,
        materializable: Bool = true,
        request: HistoryValue,
        response: HistoryValue
    ) -> Int {
        guard let responseObject = response.objectValue else { return 0 }
        if let object = responseObject["object"]?.stringValue, object != "response" { return 0 }
        guard ["completed", "incomplete"].contains(
            responseObject["status"]?.stringValue ?? ""
        ), let responseID = Self.trimmed(responseObject["id"]?.stringValue) else { return 0 }

        let requestInput = Self.requestInputItems(request)
        let requestComplete = Self.requestInputIsMaterializable(request)
        let sourceOutput = responseObject["output"]?.arrayValue
        let output = sourceOutput?.compactMap(Self.cachedOutputItem) ?? []
        let outputComplete = sourceOutput.map {
            output.count == $0.count && $0.allSatisfy(Self.historyItemIsMaterializable)
        } ?? false
        return insert(
            scope: scope,
            responseID: responseID,
            requestInput: requestInput,
            output: output,
            origin: origin,
            materializable: materializable && requestComplete && outputComplete
        )
    }

    func responseMetadata(scope: String = "", responseID: String) -> CodexResponseMetadata? {
        guard let responseID = Self.trimmed(responseID),
              let response = responses[ResponseKey(scope: scope, responseID: responseID)] else {
            return nil
        }
        return CodexResponseMetadata(
            origin: response.origin,
            materializable: response.materializable
        )
    }

    func enrichRequest(
        scope: String = "",
        allowCallIDFallback: Bool = false,
        body: HistoryValue
    ) -> CodexResponsesRequestResult {
        resolve(
            scope: scope,
            allowCallIDFallback: allowCallIDFallback,
            stripMaterializedPreviousID: false,
            body: body
        )
    }

    func materializeRequest(
        scope: String,
        allowCallIDFallback: Bool,
        body: HistoryValue
    ) -> CodexResponsesRequestResult {
        resolve(
            scope: scope,
            allowCallIDFallback: allowCallIDFallback,
            stripMaterializedPreviousID: true,
            body: body
        )
    }

    func statistics() -> CodexResponsesCacheStatistics {
        CodexResponsesCacheStatistics(
            responses: responses.count,
            indexedCalls: callIndex.count,
            serializedBytes: cachedBytes
        )
    }

    // MARK: - Resolution

    private func resolve(
        scope: String,
        allowCallIDFallback: Bool,
        stripMaterializedPreviousID: Bool,
        body: HistoryValue
    ) -> CodexResponsesRequestResult {
        guard var object = body.objectValue else {
            return .init(body: body, resolution: .init())
        }
        let previousResponseID = Self.trimmed(object["previous_response_id"]?.stringValue)
        let hadPreviousResponseID = previousResponseID != nil
        let inputWasMissing = object["input"] == nil
        let originalInput = object["input"]
        let originalWasObject = originalInput?.objectValue != nil
        let originalString = originalInput?.stringValue

        let items: [HistoryValue]
        var unsupportedInput = false
        switch originalInput {
        case .array(let values): items = values
        case .object(let value): items = [.object(value)]
        case .string(let value):
            items = [.object([
                "type": .string("message"),
                "role": .string("user"),
                "content": .string(value),
            ])]
        case nil: items = []
        default:
            items = []
            unsupportedInput = true
        }

        let requestedCallIDs = Set(items.compactMap { item -> String? in
            let type = item["type"]?.stringValue ?? ""
            guard Self.isCallItemType(type) || Self.isCallOutputItemType(type) else { return nil }
            return Self.responseItemCallID(item)
        })
        let previous = previousResponseID.flatMap {
            responses[ResponseKey(scope: scope, responseID: $0)]
        }
        let fallback = allowCallIDFallback
            ? uniqueFallbackResponse(
                scope: scope,
                requestedCallIDs: requestedCallIDs,
                previous: previous
            )
            : nil
        var resolution = CodexResponsesHistoryResolution(
            changed: 0,
            hadPreviousResponseID: hadPreviousResponseID,
            previousFound: previous != nil,
            previousMaterialized: previous?.materializable ?? false,
            previousOrigin: previous?.origin
        )

        if unsupportedInput || (previous != nil && previous?.materializable == false) {
            return .init(body: body, resolution: resolution)
        }

        let replayContext = previous ?? fallback.flatMap { $0.materializable ? $0 : nil }
        let merged = Self.mergePreviousContext(items: items, previous: replayContext)
        var enriched = 0
        let resolvedItems = merged.items.map { original -> HistoryValue in
            var item = original
            guard let type = item["type"]?.stringValue, Self.isCallItemType(type),
                  let callID = Self.responseItemCallID(item),
                  let cached = previous?.callsByID[callID] ?? fallback?.callsByID[callID]
            else { return item }
            if Self.enrichCallItem(&item, from: cached) { enriched += 1 }
            return item
        }
        resolution.changed = merged.restored + enriched

        if resolution.changed == 0, let originalString, resolvedItems.count == 1 {
            object["input"] = .string(originalString)
        } else if resolution.changed == 0, originalWasObject, resolvedItems.count == 1 {
            object["input"] = resolvedItems[0]
        } else if inputWasMissing, resolution.changed == 0 {
            object.removeValue(forKey: "input")
        } else {
            object["input"] = .array(resolvedItems)
        }
        if stripMaterializedPreviousID, resolution.previousMaterialized {
            object.removeValue(forKey: "previous_response_id")
        }
        return .init(body: .object(object), resolution: resolution)
    }

    private func uniqueFallbackResponse(
        scope: String,
        requestedCallIDs: Set<String>,
        previous: CachedResponse?
    ) -> CachedResponse? {
        guard previous == nil, !requestedCallIDs.isEmpty else { return nil }
        var source: ResponseKey?
        for callID in requestedCallIDs {
            guard let responseKey = uniqueResponseForCall(scope: scope, callID: callID) else {
                return nil
            }
            if let source, source != responseKey { return nil }
            source = responseKey
        }
        return source.flatMap { responses[$0] }
    }

    private func uniqueResponseForCall(scope: String, callID: String) -> ResponseKey? {
        guard let keys = callIndex[CallKey(scope: scope, callID: callID)] else { return nil }
        var found: ResponseKey?
        for key in keys {
            guard let response = responses[key], response.materializable,
                  response.callsByID[callID] != nil else { continue }
            if found != nil { return nil }
            found = key
        }
        return found
    }

    // MARK: - Insertion and eviction

    private func insert(
        scope: String,
        responseID: String,
        requestInput: [HistoryValue],
        output: [HistoryValue],
        origin: CodexResponseOrigin,
        materializable: Bool
    ) -> Int {
        var cached = CachedResponse(
            requestInput: requestInput,
            output: output,
            origin: origin,
            materializable: materializable
        )
        for item in output {
            guard let callID = Self.responseItemCallID(item),
                  Self.isCallItemType(item["type"]?.stringValue ?? "") else { continue }
            if cached.callsByID[callID] == nil { cached.callOrder.append(callID) }
            cached.callsByID[callID] = item
        }
        cached.serializedBytes = Self.cachedResponseSize(
            scope: scope,
            responseID: responseID,
            response: cached
        )
        let key = ResponseKey(scope: scope, responseID: responseID)

        // One pathological response must not evict useful unrelated branches. An oversized
        // authoritative replacement removes only the stale value under its own id.
        if cached.serializedBytes > maximumBytes {
            if removeResponse(key) { responseOrder.removeAll { $0 == key } }
            return 0
        }

        let replacing = responses[key] != nil
        if !replacing { responseOrder.append(key) }
        _ = removeResponse(key)
        for callID in cached.callOrder {
            let callKey = CallKey(scope: scope, callID: callID)
            if callIndex[callKey]?.contains(key) != true {
                callIndex[callKey, default: []].append(key)
            }
        }
        cachedBytes = Self.saturatingAdd(cachedBytes, cached.serializedBytes)
        responses[key] = cached
        pruneToLimits()
        return responses[key] == nil ? 0 : output.count
    }

    @discardableResult
    private func removeResponse(_ key: ResponseKey) -> Bool {
        for callKey in Array(callIndex.keys) {
            callIndex[callKey]?.removeAll { $0 == key }
            if callIndex[callKey]?.isEmpty == true { callIndex.removeValue(forKey: callKey) }
        }
        guard let response = responses.removeValue(forKey: key) else { return false }
        cachedBytes = max(0, cachedBytes - response.serializedBytes)
        return true
    }

    private func pruneToLimits() {
        while responseOrder.count > maximumResponses || cachedBytes > maximumBytes {
            guard !responseOrder.isEmpty else { break }
            let oldest = responseOrder.removeFirst()
            _ = removeResponse(oldest)
        }
    }

    // MARK: - Context merge

    private static func mergePreviousContext(
        items: [HistoryValue],
        previous: CachedResponse?
    ) -> (items: [HistoryValue], restored: Int) {
        guard let previous else { return (items, 0) }
        let prefixCount = previous.requestInput.count
        let hasRequestPrefix = prefixCount <= items.count
            && zip(previous.requestInput, items).allSatisfy {
                cachedItemMatchesInput($0.0, $0.1)
            }
        let hasOutputAnchor = hasRequestPrefix && !previous.output.isEmpty
            && previous.output.contains { cached in
                items.dropFirst(prefixCount).contains { cachedItemMatchesInput(cached, $0) }
            }

        let prefix: [HistoryValue]
        let tail: [HistoryValue]
        let restoredInput: Int
        if hasRequestPrefix && hasOutputAnchor {
            prefix = Array(items.prefix(prefixCount))
            tail = Array(items.dropFirst(prefixCount))
            restoredInput = 0
        } else {
            prefix = previous.requestInput
            tail = items
            restoredInput = previous.requestInput.count
        }
        let outputMerge = mergeCachedOutput(items: tail, eligible: previous.output)
        return (prefix + outputMerge.items, restoredInput + outputMerge.restored)
    }

    private static func mergeCachedOutput(
        items: [HistoryValue],
        eligible: [HistoryValue]
    ) -> (items: [HistoryValue], restored: Int) {
        guard !eligible.isEmpty else { return (items, 0) }
        var matches: [Int: Int] = [:]
        var nextInput = 0
        for (cachedIndex, cached) in eligible.enumerated() where nextInput <= items.count {
            guard let relative = items[nextInput...].firstIndex(where: {
                cachedItemMatchesInput(cached, $0)
            }) else { continue }
            matches[relative] = cachedIndex
            nextInput = relative + 1
        }
        guard !matches.isEmpty else { return (eligible + items, eligible.count) }

        let lastMatch = matches.keys.max() ?? 0
        var merged: [HistoryValue] = []
        var cachedCursor = 0
        var restored = 0
        for (inputIndex, item) in items.enumerated() {
            if let cachedIndex = matches[inputIndex] {
                while cachedCursor < cachedIndex {
                    merged.append(eligible[cachedCursor])
                    cachedCursor += 1
                    restored += 1
                }
                merged.append(item)
                cachedCursor = cachedIndex + 1
                if inputIndex == lastMatch {
                    while cachedCursor < eligible.count {
                        merged.append(eligible[cachedCursor])
                        cachedCursor += 1
                        restored += 1
                    }
                }
            } else {
                merged.append(item)
            }
        }
        return (merged, restored)
    }

    // MARK: - Responses item rules

    private static func requestInputItems(_ request: HistoryValue) -> [HistoryValue] {
        switch request["input"] {
        case .array(let items): return items
        case .object(let object): return [.object(object)]
        case .string(let value):
            return [.object([
                "type": .string("message"),
                "role": .string("user"),
                "content": .string(value),
            ])]
        default: return []
        }
    }

    private static func requestInputIsMaterializable(_ request: HistoryValue) -> Bool {
        switch request["input"] {
        case nil, .string: return true
        case .array(let items): return items.allSatisfy(historyItemIsMaterializable)
        case .object: return request["input"].map(historyItemIsMaterializable) ?? false
        default: return false
        }
    }

    static func historyItemIsMaterializable(_ item: HistoryValue) -> Bool {
        guard let object = item.objectValue else { return false }
        let type = object["type"]?.stringValue ?? (object["role"] == nil ? "" : "message")
        switch type {
        case "additional_tools": return object["tools"]?.arrayValue != nil
        case "message":
            return object["content"].map(historyContentIsMaterializable) ?? true
        case "reasoning":
            let opaque = object["encrypted_content"].map { !isEmptyValue($0) } ?? false
            return !opaque
                && (object["summary"].map(historyContentIsMaterializable) ?? true)
                && (object["content"].map(historyContentIsMaterializable) ?? true)
        case let value where isCallItemType(value) || isCallOutputItemType(value): return true
        default: return false
        }
    }

    private static func historyContentIsMaterializable(_ content: HistoryValue) -> Bool {
        switch content {
        case .null, .string: return true
        case .array(let parts):
            return parts.allSatisfy { part in
                guard let type = part["type"]?.stringValue else { return false }
                switch type {
                case "input_text", "output_text", "text", "summary_text":
                    return part["text"]?.stringValue != nil
                case "input_image":
                    if part["image_url"]?.stringValue != nil { return true }
                    return part["image_url"]?["url"]?.stringValue != nil
                default: return false
                }
            }
        default: return false
        }
    }

    private static func cachedOutputItem(_ item: HistoryValue) -> HistoryValue? {
        switch item["type"]?.stringValue {
        case "reasoning": return item
        case "message" where item["role"]?.stringValue.map({ $0 == "assistant" }) ?? true:
            return item
        case let type? where isCallItemType(type): return item
        default: return nil
        }
    }

    private static func cachedItemMatchesInput(
        _ cached: HistoryValue,
        _ input: HistoryValue
    ) -> Bool {
        let cachedType = cached["type"]?.stringValue
        let inputType = input["type"]?.stringValue
        if let cachedType, isCallItemType(cachedType) {
            guard let inputType, isCallItemType(inputType),
                  let callID = responseItemCallID(cached) else { return false }
            return responseItemCallID(input) == callID
        }
        if let id = trimmed(cached["id"]?.stringValue) {
            return cachedType == inputType && trimmed(input["id"]?.stringValue) == id
        }
        return cached == input
    }

    private static func enrichCallItem(
        _ item: inout HistoryValue,
        from cached: HistoryValue
    ) -> Bool {
        guard var object = item.objectValue else { return false }
        var changed = false
        for key in [
            "name", "namespace", "arguments", "input", "status", "execution",
            "reasoning_content", "reasoning",
        ] {
            if object[key].map({ !isEmptyValue($0) }) == true { continue }
            guard let value = cached[key], !isEmptyValue(value) else { continue }
            object[key] = value
            changed = true
        }
        if changed { item = .object(object) }
        return changed
    }

    private static func responseItemCallID(_ item: HistoryValue) -> String? {
        trimmed(item["call_id"]?.stringValue ?? item["id"]?.stringValue)
    }

    private static func isCallItemType(_ type: String) -> Bool {
        ["function_call", "custom_tool_call", "tool_search_call"].contains(type)
    }

    private static func isCallOutputItemType(_ type: String) -> Bool {
        ["function_call_output", "custom_tool_call_output", "tool_search_output"].contains(type)
    }

    private static func isEmptyValue(_ value: HistoryValue) -> Bool {
        switch value {
        case .null: return true
        case .string(let value): return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let value): return value.isEmpty
        case .object(let value): return value.isEmpty
        default: return false
        }
    }

    // MARK: - Size accounting

    private static func cachedResponseSize(
        scope: String,
        responseID: String,
        response: CachedResponse
    ) -> Int {
        var size = 0
        for value in [
            HistoryValue.string(scope),
            .string(responseID),
            .array(response.requestInput),
            .array(response.output),
            .object(response.callsByID),
            .array(response.callOrder.map(HistoryValue.string)),
        ] {
            size = saturatingAdd(size, serializedSize(value))
        }
        switch response.origin {
        case .local: size = saturatingAdd(size, 1)
        case .native(let providerID):
            size = saturatingAdd(size, saturatingAdd(1, serializedSize(.string(providerID))))
        }
        return saturatingAdd(size, 1)
    }

    private static func serializedSize(_ value: HistoryValue) -> Int {
        value.jsonString.utf8.count
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let result = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else { return nil }
        return result
    }
}
