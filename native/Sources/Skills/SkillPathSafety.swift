import Darwin
import Foundation

enum SkillEntryKind: Equatable {
    case missing
    case file
    case directory
    case symlink
    case other
}

enum SkillPathSafety {
    static func entryKind(at url: URL) throws -> SkillEntryKind {
        var information = stat()
        let result = url.path.withCString { lstat($0, &information) }
        if result != 0 {
            if errno == ENOENT || errno == ENOTDIR { return .missing }
            throw failure("Cannot inspect \(url.path): \(posixMessage())")
        }
        switch information.st_mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    static func entryIdentity(at url: URL) throws -> String {
        var information = stat()
        let result = url.path.withCString { lstat($0, &information) }
        guard result == 0 else {
            throw failure("Cannot identify \(url.path): \(posixMessage())")
        }
        return "\(information.st_dev):\(information.st_ino):\(information.st_mode & S_IFMT)"
    }

    static func ensureRoot(_ root: URL, fileManager: FileManager) throws -> URL {
        guard root.isFileURL, root.path.hasPrefix("/") else {
            throw failure("Skills root must be an absolute file URL")
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        guard try entryKind(at: resolved) == .directory else {
            throw failure("Skills root is not a real directory: \(root.path)")
        }
        return resolved
    }

    static func realDirectory(_ url: URL, label: String) throws -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard try entryKind(at: resolved) == .directory else {
            throw failure("\(label) must be a real directory: \(url.path)")
        }
        return resolved
    }

    static func validateID(_ id: String) throws {
        let allowed = id.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
        }
        guard !id.isEmpty,
              !id.hasPrefix("."),
              id.utf8.count <= 120,
              allowed,
              !id.contains("/"),
              !id.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw failure("Invalid skill id")
        }
    }

    static func existingSkillDirectory(root: URL, id: String) throws -> URL {
        try validateID(id)
        let path = root.appendingPathComponent(id, isDirectory: true)
        guard try entryKind(at: path) == .directory else {
            throw failure("Skill not found: \(id)")
        }
        let resolved = path.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.deletingLastPathComponent() == root.standardizedFileURL,
              try entryKind(at: resolved.appendingPathComponent("SKILL.md")) == .file
        else {
            throw failure("Invalid skill directory: \(id)")
        }
        return resolved
    }

    static func directChild(root: URL, name: String) throws -> URL {
        try validateID(name)
        let child = root.appendingPathComponent(name)
        guard child.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw failure("Path escapes skills root")
        }
        return child
    }

    static func removeDirectChild(root: URL, child: URL, fileManager: FileManager) throws {
        guard child.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw failure("Refusing to remove outside \(root.path)")
        }
        guard try entryKind(at: child) != .missing else { return }
        try fileManager.removeItem(at: child)
    }

    static func uniqueHidden(
        root: URL,
        kind: String,
        makeUUID: () -> UUID
    ) throws -> URL {
        for _ in 0..<10_000 {
            let path = root.appendingPathComponent(".ccbud-\(kind)-\(makeUUID().uuidString)")
            if try entryKind(at: path) == .missing { return path }
        }
        throw failure("Cannot allocate a transaction path in \(root.path)")
    }

    static func safeRelativeComponents(_ path: String) throws -> [Substring] {
        guard !path.isEmpty,
              path.utf8.count <= 1_024,
              !path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw failure("Invalid skill file path")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw failure("Skill file path must be relative")
        }
        return components
    }

    static func isInside(_ child: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }

    static func failure(_ message: String) -> SkillsServiceError {
        SkillsServiceError(message: message)
    }

    private static func posixMessage() -> String {
        String(cString: strerror(errno))
    }
}

func skillErrorMessage(_ error: Error) -> String {
    if let error = error as? LocalizedError, let description = error.errorDescription {
        return description
    }
    return String(describing: error)
}
