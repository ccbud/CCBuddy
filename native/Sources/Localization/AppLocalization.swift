import Foundation
import SwiftUI

private final class AppLocalizationBundleMarker: NSObject {}

private extension Bundle {
    static let ccbudResources = Bundle(for: AppLocalizationBundleMarker.self)
}

enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh"
    case traditionalChinese = "zh-TW"
    case japanese = "ja"
    case korean = "ko"

    init(configValue: String?, systemLocale: Locale = .autoupdatingCurrent) {
        if let configValue, let configured = AppLanguage(rawValue: configValue) {
            self = configured
        } else {
            self = AppLanguage(locale: systemLocale)
        }
    }

    init(locale: Locale) {
        let identifier = locale.identifier.lowercased()
        if identifier.hasPrefix("zh-hant") || identifier.hasPrefix("zh-tw")
            || identifier.hasPrefix("zh-hk") || identifier.hasPrefix("zh-mo") {
            self = .traditionalChinese
        } else if identifier.hasPrefix("zh") {
            self = .simplifiedChinese
        } else if identifier.hasPrefix("ja") {
            self = .japanese
        } else if identifier.hasPrefix("ko") {
            self = .korean
        } else {
            self = .english
        }
    }

    var locale: Locale {
        Locale(identifier: localeIdentifier)
    }

    var localeIdentifier: String {
        switch self {
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        case .traditionalChinese: "zh-Hant"
        case .japanese: "ja"
        case .korean: "ko"
        }
    }

    var localizationDirectory: String { "\(localeIdentifier).lproj" }

    /// Localizes a runtime string using the same tables SwiftUI uses for literal text. In addition
    /// to exact keys, generated `{placeholder}` templates are matched and their captured values are
    /// reinserted verbatim. That keeps paths, names, model identifiers, and error details untouched
    /// while localizing the surrounding application-authored sentence.
    func localized(_ source: String, bundle requestedBundle: Bundle? = nil) -> String {
        let bundle = requestedBundle ?? .ccbudResources
        let table = requestedBundle == nil
            ? AppLocalizationCatalog.shared.table(for: self)
            : AppLocalizationTable(language: self, bundle: bundle)
        return table.localized(source)
    }
}

private struct AppLocalizationTable: Sendable {
    private struct Template: Sendable {
        enum Segment: Sendable {
            case literal(String)
            case placeholder(String)
        }

        let target: String
        let segments: [Segment]
        let literalLength: Int

        init?(source: String, target: String) {
            let segments = Self.segments(in: source)
            guard segments.contains(where: {
                if case .placeholder = $0 { return true }
                return false
            }) else { return nil }
            self.target = target
            self.segments = segments
            literalLength = segments.reduce(into: 0) { result, segment in
                if case .literal(let value) = segment { result += value.count }
            }
        }

        func localized(_ source: String) -> String? {
            guard let values = captures(in: source) else { return nil }
            return Self.replacingPlaceholders(in: target, with: values)
        }

        private func captures(in source: String) -> [String: String]? {
            var values: [String: String] = [:]
            var cursor = source.startIndex

            for (index, segment) in segments.enumerated() {
                switch segment {
                case .literal(let literal):
                    guard source[cursor...].hasPrefix(literal) else { return nil }
                    cursor = source.index(cursor, offsetBy: literal.count)
                case .placeholder(let key):
                    let nextLiteral = segments[(index + 1)...].compactMap { segment -> String? in
                        if case .literal(let value) = segment, !value.isEmpty { return value }
                        return nil
                    }.first
                    let end: String.Index
                    if let nextLiteral {
                        guard let range = source.range(of: nextLiteral, range: cursor..<source.endIndex) else {
                            return nil
                        }
                        end = range.lowerBound
                    } else {
                        end = source.endIndex
                    }
                    let captured = String(source[cursor..<end])
                    if let existing = values[key], existing != captured { return nil }
                    values[key] = captured
                    cursor = end
                }
            }
            return cursor == source.endIndex ? values : nil
        }

        private static func segments(in value: String) -> [Segment] {
            var result: [Segment] = []
            var literalStart = value.startIndex
            var cursor = value.startIndex
            while cursor < value.endIndex {
                guard value[cursor] == "{",
                      let close = value[cursor...].firstIndex(of: "}")
                else {
                    cursor = value.index(after: cursor)
                    continue
                }
                let keyStart = value.index(after: cursor)
                let key = String(value[keyStart..<close])
                guard !key.isEmpty,
                      key.unicodeScalars.allSatisfy({
                          CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
                              .contains($0)
                      })
                else {
                    cursor = value.index(after: cursor)
                    continue
                }
                if literalStart < cursor { result.append(.literal(String(value[literalStart..<cursor]))) }
                result.append(.placeholder(key))
                cursor = value.index(after: close)
                literalStart = cursor
            }
            if literalStart < value.endIndex {
                result.append(.literal(String(value[literalStart...])))
            }
            return result
        }

        private static func replacingPlaceholders(
            in template: String,
            with replacements: [String: String]
        ) -> String {
            segments(in: template).map { segment in
                switch segment {
                case .literal(let value): value
                case .placeholder(let key): replacements[key] ?? "{\(key)}"
                }
            }.joined()
        }
    }

    private let values: [String: String]
    private let templates: [Template]

    init(language: AppLanguage, bundle: Bundle) {
        guard let path = bundle.path(forResource: language.localeIdentifier, ofType: "lproj"),
              let localizedBundle = Bundle(path: path),
              let tableURL = localizedBundle.url(forResource: "Localizable", withExtension: "strings"),
              let data = try? Data(contentsOf: tableURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ),
              let values = propertyList as? [String: String]
        else {
            self.values = [:]
            templates = []
            return
        }
        self.values = values
        templates = values.compactMap { Template(source: $0.key, target: $0.value) }
            .sorted { left, right in left.literalLength > right.literalLength }
    }

    func localized(_ source: String) -> String {
        if let value = values[source] { return value }
        for template in templates {
            if let value = template.localized(source) { return value }
        }
        return source
    }
}

private struct AppLocalizationCatalog: Sendable {
    static let shared = AppLocalizationCatalog()

    private let tables: [AppLanguage: AppLocalizationTable]

    private init() {
        tables = Dictionary(uniqueKeysWithValues: AppLanguage.allCases.map {
            ($0, AppLocalizationTable(language: $0, bundle: .ccbudResources))
        })
    }

    func table(for language: AppLanguage) -> AppLocalizationTable {
        tables[language] ?? AppLocalizationTable(language: language, bundle: .ccbudResources)
    }
}

private struct AppLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppLanguage.simplifiedChinese
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageEnvironmentKey.self] }
        set { self[AppLanguageEnvironmentKey.self] = newValue }
    }
}

extension AppModel {
    var appLanguage: AppLanguage { AppLanguage(configValue: config.language) }
}
