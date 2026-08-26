import Foundation
import SwiftUI


struct PluginActionViewState: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case link
        case call
        case form
    }

    let action: PluginAction

    var id: String { action.id }
    var label: String { action.label }
    var kind: Kind { Kind(rawValue: action.kind) ?? .call }
    var requiresRunning: Bool {
        action.requiresRunning ?? (kind != .link)
    }
    var confirmation: String? {
        action.values["confirm"]?.stringValue?.nonEmpty
    }
    var submitLabel: String {
        action.values["submitLabel"]?.stringValue?.nonEmpty ?? "保存"
    }
    var hasCustomSubmitLabel: Bool {
        action.values["submitLabel"]?.stringValue?.nonEmpty != nil
    }
    var loadsOnOpen: Bool {
        action.values["loadOnOpen"]?.boolValue ?? true
    }
    var externalURL: URL? {
        guard let raw = action.values["url"]?.stringValue,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    func isAvailable(pluginRunning: Bool) -> Bool {
        !requiresRunning || pluginRunning
    }
}

struct PluginFormField: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case text
        case number
        case password
        case textarea
        case select
        case checkbox
    }

    struct Option: Identifiable, Equatable {
        let index: Int
        let label: String
        let value: PluginJSONValue
        var id: Int { index }
    }

    let key: String
    let label: String
    let kind: Kind
    let placeholder: String
    let help: String?
    let required: Bool
    let defaultValue: PluginJSONValue?
    let minimum: Double?
    let maximum: Double?
    let options: [Option]

    var id: String { key }

    init?(value: PluginJSONValue) {
        guard let object = value.objectValue,
              let key = object["key"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        self.key = key
        label = object["label"]?.stringValue?.nonEmpty ?? key
        kind = Kind(rawValue: object["type"]?.stringValue ?? "text") ?? .text
        placeholder = object["placeholder"]?.stringValue ?? ""
        help = object["help"]?.stringValue?.nonEmpty
        required = object["required"]?.boolValue ?? false
        defaultValue = object["default"]
        minimum = object["min"]?.numberValue
        maximum = object["max"]?.numberValue
        options = (object["options"]?.arrayValue ?? []).enumerated().map { index, value in
            if let option = value.objectValue, let rawValue = option["value"] {
                return Option(
                    index: index,
                    label: option["label"]?.displayString ?? rawValue.displayString,
                    value: rawValue
                )
            }
            return Option(index: index, label: value.displayString, value: value)
        }
    }
}

struct PluginFormDraft: Equatable {
    enum Input: Equatable {
        case text(String)
        case checked(Bool)
        case selection(Int?)
    }

    enum ValidationError: Error, LocalizedError, Equatable {
        case required(key: String, label: String)
        case invalidNumber(key: String, label: String)
        case belowMinimum(key: String, label: String, minimum: Double)
        case aboveMaximum(key: String, label: String, maximum: Double)

        var errorDescription: String? {
            switch self {
            case .required(_, let label): return "请填写“\(label)”"
            case .invalidNumber(_, let label): return "“\(label)”必须是数字"
            case .belowMinimum(_, let label, let minimum):
                return "“\(label)”不能小于 \(minimum.displayString)"
            case .aboveMaximum(_, let label, let maximum):
                return "“\(label)”不能大于 \(maximum.displayString)"
            }
        }

        var key: String {
            switch self {
            case .required(let key, _), .invalidNumber(let key, _),
                 .belowMinimum(let key, _, _), .aboveMaximum(let key, _, _): return key
            }
        }
    }

    let fields: [PluginFormField]
    var inputs: [String: Input]

    init(action: PluginAction, initialValues: [String: PluginJSONValue] = [:]) {
        fields = action.fields.compactMap(PluginFormField.init(value:))
        inputs = [:]
        for field in fields {
            let initial = initialValues[field.key] ?? field.defaultValue
            switch field.kind {
            case .checkbox:
                inputs[field.key] = .checked(Self.bool(from: initial))
            case .select:
                let selection = initial.flatMap { selected in
                    field.options.first(where: { $0.value == selected })?.index
                        ?? field.options.first(where: { $0.value.displayString == selected.displayString })?.index
                } ?? field.options.first?.index
                inputs[field.key] = .selection(selection)
            case .text, .number, .password, .textarea:
                inputs[field.key] = .text(initial?.displayString ?? "")
            }
        }
    }

    func text(for key: String) -> String {
        guard case .text(let value) = inputs[key] else { return "" }
        return value
    }

    mutating func setText(_ value: String, for key: String) {
        inputs[key] = .text(value)
    }

    func isChecked(_ key: String) -> Bool {
        guard case .checked(let value) = inputs[key] else { return false }
        return value
    }

    mutating func setChecked(_ value: Bool, for key: String) {
        inputs[key] = .checked(value)
    }

    func selection(for key: String) -> Int? {
        guard case .selection(let value) = inputs[key] else { return nil }
        return value
    }

    mutating func setSelection(_ value: Int?, for key: String) {
        inputs[key] = .selection(value)
    }

    func collectedValues() throws -> [String: PluginJSONValue] {
        var result: [String: PluginJSONValue] = [:]
        for field in fields {
            switch field.kind {
            case .checkbox:
                result[field.key] = .bool(isChecked(field.key))
            case .select:
                guard let selection = selection(for: field.key),
                      let option = field.options.first(where: { $0.index == selection }) else {
                    if field.required { throw ValidationError.required(key: field.key, label: field.label) }
                    result[field.key] = .null
                    continue
                }
                result[field.key] = option.value
            case .number:
                let raw = text(for: field.key).trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty {
                    if field.required { throw ValidationError.required(key: field.key, label: field.label) }
                    result[field.key] = .null
                    continue
                }
                guard let number = Double(raw), number.isFinite else {
                    throw ValidationError.invalidNumber(key: field.key, label: field.label)
                }
                if let minimum = field.minimum, number < minimum {
                    throw ValidationError.belowMinimum(key: field.key, label: field.label, minimum: minimum)
                }
                if let maximum = field.maximum, number > maximum {
                    throw ValidationError.aboveMaximum(key: field.key, label: field.label, maximum: maximum)
                }
                result[field.key] = .number(number)
            case .text, .password, .textarea:
                let raw = text(for: field.key)
                if field.required && raw.isEmpty {
                    throw ValidationError.required(key: field.key, label: field.label)
                }
                result[field.key] = .string(raw)
            }
        }
        return result
    }

    private static func bool(from value: PluginJSONValue?) -> Bool {
        switch value {
        case .bool(let value): return value
        case .number(let value): return value == 1
        case .string(let value): return value == "1" || value.lowercased() == "true"
        case .object, .array, .null, .none: return false
        }
    }
}

private extension PluginJSONValue {
    var displayString: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return value.displayString
        case .bool(let value): return value ? "true" : "false"
        case .null: return ""
        case .object, .array: return ""
        }
    }
}

private extension Double {
    var displayString: String {
        String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), self)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
