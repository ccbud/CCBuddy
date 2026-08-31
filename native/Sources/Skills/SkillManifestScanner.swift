import Foundation

struct SkillManifestScanner {
    private let fileManager: FileManager
    private let maximumDepth = 12
    private let maximumEntries = 20_000
    private let maximumManifestBytes = 4 * 1_024 * 1_024

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func centralDirectories(root: URL) throws -> [(String, URL)] {
        let entries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        )
        var result: [(String, URL)] = []
        for entry in entries {
            let id = entry.lastPathComponent
            guard !id.hasPrefix("."), (try? SkillPathSafety.validateID(id)) != nil else { continue }
            guard try SkillPathSafety.entryKind(at: entry) == .directory,
                  try SkillPathSafety.entryKind(at: entry.appendingPathComponent("SKILL.md")) == .file
            else { continue }
            result.append((id, entry.standardizedFileURL))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    func localCandidates(at source: URL) throws -> [SkillLocalCandidate] {
        let base = try SkillPathSafety.realDirectory(source, label: "Local skill source")
        var directories: [URL] = []
        var seen = 0
        try walkCandidates(base, depth: 0, seen: &seen, result: &directories)
        return try directories.sorted { $0.path < $1.path }.map { directory in
            let summary = try manifestSummary(in: directory)
            return SkillLocalCandidate(
                name: summary.name,
                description: summary.description,
                path: directory
            )
        }
    }

    func manifestSummary(in directory: URL) throws -> (name: String, description: String?) {
        let manifest = directory.appendingPathComponent("SKILL.md")
        guard try SkillPathSafety.entryKind(at: manifest) == .file else {
            throw SkillPathSafety.failure("SKILL.md is not a regular file: \(manifest.path)")
        }
        let data = try Data(contentsOf: manifest, options: [.mappedIfSafe])
        guard data.count <= maximumManifestBytes else {
            throw SkillPathSafety.failure("SKILL.md is too large: \(manifest.path)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SkillPathSafety.failure("SKILL.md must be UTF-8")
        }
        let lines = text.components(separatedBy: .newlines)
        var name: String?
        var description: String?
        var bodyStart = 0
        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            for index in lines.indices.dropFirst() {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                    bodyStart = index + 1
                    break
                }
                if line.hasPrefix("name:") {
                    name = cleanScalar(String(line.dropFirst("name:".count)))
                } else if line.hasPrefix("description:") {
                    description = cleanScalar(String(line.dropFirst("description:".count)))
                }
            }
        }
        if name == nil {
            name = lines.dropFirst(bodyStart).compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.hasPrefix("# ") ? String(trimmed.dropFirst(2)) : nil
            }.first
        }
        if description == nil {
            description = lines.dropFirst(bodyStart).compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
                return String(trimmed.prefix(240))
            }.first
        }
        let fallback = directory.lastPathComponent.isEmpty ? "skill" : directory.lastPathComponent
        return (name?.isEmpty == false ? name! : fallback, description)
    }

    func files(in directory: URL) throws -> [SkillFile] {
        var result: [SkillFile] = []
        var seen = 0
        try walkFiles(base: directory, directory: directory, depth: 0, seen: &seen, result: &result)
        return result.sorted { $0.path < $1.path }
    }

    func modifiedMilliseconds(at url: URL, now: () -> Date) -> Int64 {
        let date = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now()
        return Int64(date.timeIntervalSince1970 * 1_000)
    }

    private func walkCandidates(
        _ directory: URL,
        depth: Int,
        seen: inout Int,
        result: inout [URL]
    ) throws {
        guard depth <= maximumDepth, seen <= maximumEntries else {
            throw SkillPathSafety.failure("Skill scan limit exceeded")
        }
        if try SkillPathSafety.entryKind(at: directory.appendingPathComponent("SKILL.md")) == .file {
            result.append(directory)
            return
        }
        for entry in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            seen += 1
            guard seen <= maximumEntries else {
                throw SkillPathSafety.failure("Skill scan limit exceeded")
            }
            let name = entry.lastPathComponent
            if name.hasPrefix(".ccbud") || [".git", "node_modules", "target"].contains(name) {
                continue
            }
            if try SkillPathSafety.entryKind(at: entry) == .directory {
                try walkCandidates(entry, depth: depth + 1, seen: &seen, result: &result)
            }
        }
    }

    private func walkFiles(
        base: URL,
        directory: URL,
        depth: Int,
        seen: inout Int,
        result: inout [SkillFile]
    ) throws {
        guard depth <= maximumDepth, seen <= maximumEntries else {
            throw SkillPathSafety.failure("Skill file listing limit exceeded")
        }
        for entry in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            seen += 1
            guard seen <= maximumEntries else {
                throw SkillPathSafety.failure("Skill file listing limit exceeded")
            }
            if entry.lastPathComponent == ".git" { continue }
            switch try SkillPathSafety.entryKind(at: entry) {
            case .directory:
                try walkFiles(base: base, directory: entry, depth: depth + 1, seen: &seen, result: &result)
            case .file:
                let prefix = base.standardizedFileURL.path + "/"
                guard entry.standardizedFileURL.path.hasPrefix(prefix) else {
                    throw SkillPathSafety.failure("Invalid skill file")
                }
                let relative = String(entry.standardizedFileURL.path.dropFirst(prefix.count))
                let attributes = try fileManager.attributesOfItem(atPath: entry.path)
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                result.append(SkillFile(path: relative, size: size))
            case .missing, .symlink, .other:
                continue
            }
        }
    }

    private func cleanScalar(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return trimmed.isEmpty || trimmed == ">" || trimmed == "|" ? nil : trimmed
    }
}
