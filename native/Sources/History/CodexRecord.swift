import Foundation

struct CodexLine: Sendable {
    var kind: String
    var payload: [String: HistoryValue]
    var timestampText: String?
}

struct CodexIdentity: Sendable {
    var threadID: String?
    var rootSessionID: String?
    var parentThreadID: String?
    var forkedFromID: String?
    var isSubagent = false
    var agentPath: String?
    var agentNickname: String?
    var agentRole: String?
    var agentDepth: Int?
}

enum CodexRecord {
    static func split(_ record: [String: HistoryValue]) -> CodexLine {
        let timestamp = record["timestamp"]?.stringValue
        let type = record["type"]?.stringValue ?? ""
        if let payload = record["payload"]?.objectValue {
            return CodexLine(kind: type, payload: payload, timestampText: timestamp)
        }
        if [
            "message", "function_call", "function_call_output", "reasoning",
            "local_shell_call", "custom_tool_call", "custom_tool_call_output", "web_search_call"
        ].contains(type) {
            return CodexLine(kind: "response_item", payload: record, timestampText: timestamp)
        }
        if type.isEmpty, record["id"] != nil, record["timestamp"] != nil {
            return CodexLine(kind: "session_meta", payload: record, timestampText: timestamp)
        }
        return CodexLine(kind: type, payload: record, timestampText: timestamp)
    }

    static func canonicalIdentity(_ payload: [String: HistoryValue]) -> CodexIdentity {
        let subagent = payload["source"]?["subagent"]?.objectValue
            ?? payload["source"]?["sub_agent"]?.objectValue
            ?? payload["thread_source"]?["subagent"]?.objectValue
            ?? payload["thread_source"]?["sub_agent"]?.objectValue
        let detail: [String: HistoryValue]? = {
            guard let subagent else { return nil }
            for key in ["thread_spawn", "review", "compact", "other"] {
                if let object = subagent[key]?.objectValue { return object }
            }
            return subagent.values.compactMap(\.objectValue).first
        }()
        let string = { (value: HistoryValue?) -> String? in
            guard let value = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        let thread = string(payload["id"] ?? payload["thread_id"])
        let root = string(payload["session_id"]) ?? thread
        let parent = string(payload["parent_thread_id"] ?? detail?["parent_thread_id"])
        let agentPath = string(payload["agent_path"] ?? detail?["agent_path"])
        let nickname = string(payload["agent_nickname"] ?? detail?["agent_nickname"])
        let role = string(
            payload["agent_role"] ?? payload["agent_type"]
                ?? detail?["agent_role"] ?? detail?["agent_type"]
        )
        let explicitSubagent = payload["thread_source"]?.stringValue == "subagent"
        return CodexIdentity(
            threadID: thread,
            rootSessionID: root,
            parentThreadID: parent,
            forkedFromID: string(payload["forked_from_id"]),
            isSubagent: subagent != nil || explicitSubagent || agentPath != nil || nickname != nil
                || (parent != nil && thread != root),
            agentPath: agentPath,
            agentNickname: nickname,
            agentRole: role,
            agentDepth: detail?["depth"]?.integerValue ?? payload["agent_depth"]?.integerValue
        )
    }
}
