import Foundation

enum WakeHistoryAdapterSupport {
    static func directory(
        source: HistorySource,
        label: String,
        baseURL: URL,
        discoveryRoot: URL? = nil
    ) -> HistoryDirectory {
        let base = baseURL.standardizedFileURL
        return HistoryDirectory(
            id: "__wake_\(source.rawValue)__",
            label: label,
            baseURL: base,
            projectsURL: base.appendingPathComponent(".ccbuddy-no-projects", isDirectory: true),
            sessionsURL: (discoveryRoot ?? base).standardizedFileURL
        )
    }

    static func isActive(
        _ directory: HistoryDirectory,
        configuration: HistoryConfiguration,
        activeOnly: Bool
    ) -> Bool {
        guard activeOnly else { return true }
        switch configuration.active {
        case "all", "__trash__": return true
        default: return configuration.active == directory.id
        }
    }

    static func ordinaryFile(_ file: URL, allowedNames: Set<String>? = nil) -> Bool {
        if let allowedNames, !allowedNames.contains(file.lastPathComponent) { return false }
        guard let values = try? file.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ) else { return false }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && (values.fileSize ?? 0) > 0
    }

    static func ordinaryDirectory(_ directory: URL) -> Bool {
        guard let values = try? directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// Canonical producer roots are implicit trust boundaries beneath the configured home. Resolve
    /// every existing ancestor before discovery so a producer directory cannot be redirected to an
    /// unrelated tree through an ancestor symlink. The home itself remains the trusted anchor and
    /// may be presented through a platform-managed symlink.
    static func isContainedInHome(_ url: URL, homeDirectory: URL) -> Bool {
        let logicalHome = homeDirectory.standardizedFileURL
        let logicalURL = url.standardizedFileURL
        guard contains(logicalURL, in: logicalHome) else { return false }

        let resolvedHome = logicalHome.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = logicalURL.resolvingSymlinksInPath().standardizedFileURL
        return contains(resolvedURL, in: resolvedHome)
    }

    static func contents(of directory: URL) -> [URL] {
        guard ordinaryDirectory(directory) else { return [] }
        return (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ],
            options: [.skipsHiddenFiles]
        ))?.sorted { $0.path < $1.path } ?? []
    }

    static func jsonlFiles(in root: URL, maximumDepth: Int = 8) -> [URL] {
        var result: [URL] = []
        func walk(_ directory: URL, depth: Int) {
            guard depth <= maximumDepth else { return }
            for entry in contents(of: directory) {
                if ordinaryDirectory(entry) {
                    walk(entry, depth: depth + 1)
                } else if entry.pathExtension.lowercased() == "jsonl", ordinaryFile(entry) {
                    result.append(entry)
                }
            }
        }
        walk(root, depth: 0)
        return result
    }

    static func virtualSessionURL(database: URL, nativeID: String) -> URL {
        let encoded = Data(nativeID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return database.standardizedFileURL
            .appendingPathExtension("ccbuddy-sessions")
            .appendingPathComponent(encoded.isEmpty ? "session" : encoded)
    }

    static func nativeID(_ candidate: HistoryFileCandidate) -> String {
        candidate.nativeID
            ?? candidate.file.deletingPathExtension().lastPathComponent
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    static func date(milliseconds: Int64) -> Date? {
        guard milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    static func date(_ value: HistoryValue?) -> Date? {
        if let text = nonempty(value?.stringValue) {
            if let parsed = HistoryDateParser.parse(text) { return parsed }
            if let numeric = Double(text) { return date(numeric) }
        }
        return value?.numberValue.flatMap(date)
    }

    static func milliseconds(_ date: Date?) -> Int64 {
        guard let seconds = date?.timeIntervalSince1970, seconds.isFinite else { return 0 }
        let value = seconds * 1_000
        guard value >= Double(Int64.min), value <= Double(Int64.max) else { return 0 }
        return Int64(value.rounded(.towardZero))
    }

    static func timestampText(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// SQLite producers use both RFC 3339 and SQLite's space-separated UTC timestamps. Keep the
    /// conversion here so every database adapter applies the same locale- and timezone-stable
    /// interpretation.
    static func sqliteDate(_ rawValue: String?) -> Date? {
        guard let value = nonempty(rawValue) else { return nil }
        if let date = HistoryDateParser.parse(value) { return date }

        var rfc3339 = value
        if let separator = rfc3339.firstIndex(of: " ") {
            rfc3339.replaceSubrange(separator...separator, with: "T")
        }
        for fractional in [true, false] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = fractional
                ? [.withInternetDateTime, .withFractionalSeconds]
                : [.withInternetDateTime]
            if let date = formatter.date(from: rfc3339) { return date }
        }

        for format in [
            "yyyy-MM-dd HH:mm:ss.SSSSSS",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    static func integer(_ value: HistorySQLiteValue?) -> Int {
        guard let raw = value?.int64Value else { return 0 }
        if raw > Int64(Int.max) { return Int.max }
        if raw < Int64(Int.min) { return Int.min }
        return Int(raw)
    }

    static func historyValue(json text: String?) -> HistoryValue? {
        guard let text = nonempty(text), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HistoryValue.self, from: data)
    }

    static func text(from value: HistoryValue?) -> String {
        guard let value else { return "" }
        if let text = value.stringValue { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return value.arrayValue?.compactMap { part -> String? in
            if let text = part.stringValue { return nonempty(text) }
            return nonempty(part["text"]?.stringValue)
        }.joined(separator: "\n\n") ?? ""
    }

    private static func date(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = value > 1_000_000_000_000 ? value / 1_000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func contains(_ child: URL, in root: URL) -> Bool {
        let childComponents = child.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        return childComponents.count >= rootComponents.count
            && childComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }
}
