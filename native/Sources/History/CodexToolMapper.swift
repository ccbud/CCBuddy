import Foundation

enum CodexToolMapper {
    static func map(name: String, arguments: HistoryValue?) -> (String, HistoryValue) {
        let object = arguments?.objectValue ?? [:]
        let string = { (key: String) in object[key]?.stringValue ?? "" }
        switch name {
        case "shell", "local_shell", "container.exec":
            var input: [String: HistoryValue] = [
                "command": .string(joinArguments(object["command"]))
            ]
            let description = !string("justification").isEmpty ? string("justification") : string("workdir")
            if !description.isEmpty { input["description"] = .string(description) }
            return ("Bash", .object(input))
        case "shell_command":
            return ("Bash", .object(["command": .string(string("command"))]))
        case "exec_command":
            let command = !string("cmd").isEmpty ? string("cmd") : string("command")
            return ("Bash", .object(["command": .string(command)]))
        case "apply_patch":
            let patch = !string("input").isEmpty ? string("input") : string("patch")
            return ("ApplyPatch", .object(["patch": .string(patch)]))
        case "update_plan":
            let todos = object["plan"]?.arrayValue?.map { step -> HistoryValue in
                let item = step.objectValue ?? [:]
                return .object([
                    "content": .string(item["step"]?.stringValue ?? ""),
                    "status": .string(item["status"]?.stringValue ?? "pending")
                ])
            } ?? []
            return ("TodoWrite", .object(["todos": .array(todos)]))
        case "view_image":
            return ("Read", .object(["file_path": .string(string("path"))]))
        case "web_search":
            return ("WebSearch", .object(["query": .string(string("query"))]))
        default:
            return (name, arguments?.objectValue == nil ? .object([:]) : arguments!)
        }
    }

    static func parseArguments(_ value: HistoryValue?) -> HistoryValue {
        if let string = value?.stringValue,
           let data = string.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(HistoryValue.self, from: data) {
            return parsed
        }
        return value ?? .object([:])
    }

    static func joinArguments(_ value: HistoryValue?) -> String {
        if let string = value?.stringValue { return string }
        guard let parts = value?.arrayValue?.compactMap({ $0.stringValue }) else { return "" }
        if parts.count == 3,
           ["bash", "sh", "zsh", "dash"].contains(parts[0]),
           ["-lc", "-c"].contains(parts[1]) {
            return parts[2]
        }
        return parts.map { part in
            guard part.isEmpty || part.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) else {
                return part
            }
            return "\"" + part.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }.joined(separator: " ")
    }

    static func shapeOutput(_ value: HistoryValue?) -> (HistoryValue, Bool) {
        guard let value else { return (.string(""), false) }
        if let object = value.objectValue {
            let text = object["content"]?.stringValue ?? value.jsonString
            return (.string(text), object["success"]?.boolValue == false)
        }
        guard let string = value.stringValue else { return (value, false) }
        if let data = string.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(HistoryValue.self, from: data),
           let object = decoded.objectValue {
            if let output = object["output"]?.stringValue {
                let exitCode = object["metadata"]?["exit_code"]?.integerValue ?? 0
                return (.string(output), exitCode != 0)
            }
            if let content = object["content"]?.stringValue {
                return (.string(content), object["success"]?.boolValue == false)
            }
        }
        let head = String(string.prefix(240))
        let failed = string.hasPrefix("Script failed")
            || nonzeroCode(after: "Exit code: ", in: head)
            || nonzeroCode(after: "exited with code ", in: head)
        return (.string(string), failed)
    }

    private static func nonzeroCode(after marker: String, in text: String) -> Bool {
        guard let range = text.range(of: marker) else { return false }
        let digits = text[range.upperBound...].prefix(while: { $0.isNumber })
        return Int(digits).map { $0 != 0 } ?? false
    }
}
