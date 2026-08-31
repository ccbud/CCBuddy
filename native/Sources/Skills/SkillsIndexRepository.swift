import Darwin
import Foundation

struct SkillsIndexRepository {
    private let fileManager: FileManager
    private let beforeCommit: @Sendable () throws -> Void
    private let indexName = ".ccbud-index.json"
    private let backupName = ".ccbud-index.bak"
    private let legacyTemporaryName = ".ccbud-index.tmp"
    private let temporaryPrefix = ".ccbud-index.tmp-"

    init(
        fileManager: FileManager,
        beforeCommit: @escaping @Sendable () throws -> Void
    ) {
        self.fileManager = fileManager
        self.beforeCommit = beforeCommit
    }

    func load(root: URL) throws -> SkillIndexDocument {
        try clearLegacyTemporary(root: root)
        try recoverBackup(root: root)
        let path = root.appendingPathComponent(indexName)
        switch try SkillPathSafety.entryKind(at: path) {
        case .missing:
            return SkillIndexDocument()
        case .file:
            break
        default:
            throw SkillPathSafety.failure("Skills index is not a regular file")
        }
        let data = try Data(contentsOf: path, options: [.mappedIfSafe])
        guard data.count <= 8 * 1_024 * 1_024 else {
            throw SkillPathSafety.failure("Skills index is unexpectedly large")
        }
        let document: SkillIndexDocument
        do {
            document = try JSONDecoder().decode(SkillIndexDocument.self, from: data)
        } catch {
            throw SkillPathSafety.failure("Cannot parse skills index \(path.path): \(error.localizedDescription)")
        }
        guard document.version == 1 else {
            throw SkillPathSafety.failure("Unsupported skills index version: \(document.version)")
        }
        return document
    }

    func save(root: URL, document: SkillIndexDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw SkillPathSafety.failure("Cannot encode skills index: \(error.localizedDescription)")
        }
        let destination = root.appendingPathComponent(indexName)
        let backup = root.appendingPathComponent(backupName)
        try clearLegacyTemporary(root: root)
        try recoverBackup(root: root)
        try removeReservedRegularFileIfPresent(
            root: root,
            url: backup,
            label: "Skills index backup"
        )

        let temporary = try writeTemporary(root: root, data: data)
        do {
            try beforeCommit()
            try validateOwnedRegularFile(
                temporary.url,
                identity: temporary.identity,
                label: "Skills index temporary file"
            )
        } catch {
            try failAfterTemporaryCleanup(temporary, original: error)
        }

        let destinationKind = try SkillPathSafety.entryKind(at: destination)
        guard destinationKind == .missing || destinationKind == .file else {
            try failAfterTemporaryCleanup(
                temporary,
                original: SkillPathSafety.failure("Skills index is not a regular file")
            )
        }
        let hadDestination = destinationKind == .file
        let replacedIdentity = hadDestination
            ? try SkillPathSafety.entryIdentity(at: destination)
            : nil
        if hadDestination {
            do {
                try fileManager.moveItem(at: destination, to: backup)
                guard let replacedIdentity,
                      try SkillPathSafety.entryIdentity(at: backup) == replacedIdentity
                else {
                    throw SkillPathSafety.failure("Skills index backup identity changed")
                }
            } catch {
                if let replacedIdentity {
                    try? restoreBackup(
                        backup: backup,
                        destination: destination,
                        identity: replacedIdentity
                    )
                }
                try failAfterTemporaryCleanup(
                    temporary,
                    original: SkillPathSafety.failure(
                        "Cannot back up skills index: \(error.localizedDescription)"
                    )
                )
            }
        }
        do {
            try fileManager.moveItem(at: temporary.url, to: destination)
            try validateOwnedRegularFile(
                destination,
                identity: temporary.identity,
                label: "Installed skills index"
            )
        } catch {
            var restoreMessage = ""
            if let replacedIdentity {
                do {
                    try restoreBackup(
                        backup: backup,
                        destination: destination,
                        identity: replacedIdentity
                    )
                } catch let restoreError {
                    restoreMessage = "; restore failed: \(restoreError.localizedDescription)"
                }
            }
            let failure = SkillPathSafety.failure(
                "Cannot replace skills index: \(error.localizedDescription)\(restoreMessage)"
            )
            if (try? SkillPathSafety.entryKind(at: temporary.url)) != .missing {
                try failAfterTemporaryCleanup(temporary, original: failure)
            }
            throw failure
        }
        synchronizeDirectory(root)
        if let replacedIdentity {
            try? unlinkOwnedRegularFile(
                backup,
                identity: replacedIdentity,
                label: "Skills index backup"
            )
            synchronizeDirectory(root)
        }
    }

    private func recoverBackup(root: URL) throws {
        let destination = root.appendingPathComponent(indexName)
        let backup = root.appendingPathComponent(backupName)
        let destinationKind = try SkillPathSafety.entryKind(at: destination)
        guard destinationKind == .missing || destinationKind == .file else {
            throw SkillPathSafety.failure("Skills index is not a regular file")
        }
        let backupKind = try SkillPathSafety.entryKind(at: backup)
        guard backupKind == .missing || backupKind == .file else {
            throw SkillPathSafety.failure("Skills index backup is not a regular file")
        }
        guard destinationKind == .missing, backupKind == .file else { return }

        let identity = try SkillPathSafety.entryIdentity(at: backup)
        try restoreBackup(backup: backup, destination: destination, identity: identity)
        synchronizeDirectory(root)
    }

    private func clearLegacyTemporary(root: URL) throws {
        try removeReservedRegularFileIfPresent(
            root: root,
            url: root.appendingPathComponent(legacyTemporaryName),
            label: "Legacy skills index temporary file"
        )
    }

    private func removeReservedRegularFileIfPresent(
        root: URL,
        url: URL,
        label: String
    ) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw SkillPathSafety.failure("\(label) is outside the Skills root")
        }
        switch try SkillPathSafety.entryKind(at: url) {
        case .missing:
            return
        case .file:
            try unlinkOwnedRegularFile(
                url,
                identity: try SkillPathSafety.entryIdentity(at: url),
                label: label
            )
        case .directory, .symlink, .other:
            throw SkillPathSafety.failure("\(label) is not a regular file")
        }
    }

    private func writeTemporary(root: URL, data: Data) throws -> (
        url: URL,
        identity: String
    ) {
        let rootDescriptor = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootDescriptor >= 0 else {
            throw posixFailure("Cannot open Skills root for index save")
        }
        defer { _ = Darwin.close(rootDescriptor) }

        for _ in 0..<10_000 {
            let name = "\(temporaryPrefix)\(UUID().uuidString)"
            let descriptor = name.withCString {
                Darwin.openat(
                    rootDescriptor,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw posixFailure("Cannot create skills index temporary file")
            }

            let url = root.appendingPathComponent(name)
            var information = stat()
            guard Darwin.fstat(descriptor, &information) == 0,
                  information.st_mode & S_IFMT == S_IFREG,
                  information.st_nlink == 1,
                  information.st_uid == geteuid()
            else {
                let savedError = errno
                _ = Darwin.close(descriptor)
                errno = savedError
                throw posixFailure("Cannot verify skills index temporary file")
            }
            let identity = identity(of: information)
            guard (try? SkillPathSafety.entryIdentity(at: url)) == identity,
                  Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
            else {
                let savedError = errno
                _ = Darwin.close(descriptor)
                try? unlinkOwnedRegularFile(
                    url,
                    identity: identity,
                    label: "Skills index temporary file"
                )
                errno = savedError
                throw posixFailure("Cannot secure skills index temporary file")
            }

            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                try? unlinkOwnedRegularFile(
                    url,
                    identity: identity,
                    label: "Skills index temporary file"
                )
                throw SkillPathSafety.failure(
                    "Cannot write skills index temporary file: \(error.localizedDescription)"
                )
            }
            return (url, identity)
        }
        throw SkillPathSafety.failure("Cannot allocate a unique skills index temporary file")
    }

    private func failAfterTemporaryCleanup(
        _ temporary: (url: URL, identity: String),
        original: Error
    ) throws -> Never {
        do {
            try unlinkOwnedRegularFile(
                temporary.url,
                identity: temporary.identity,
                label: "Skills index temporary file"
            )
        } catch {
            throw SkillPathSafety.failure(
                "\(skillErrorMessage(original)); temporary cleanup refused: \(skillErrorMessage(error))"
            )
        }
        throw original
    }

    private func restoreBackup(backup: URL, destination: URL, identity: String) throws {
        guard try SkillPathSafety.entryKind(at: destination) == .missing else {
            throw SkillPathSafety.failure("Skills index destination reappeared during restore")
        }
        try validateOwnedRegularFile(
            backup,
            identity: identity,
            label: "Skills index backup"
        )
        try fileManager.moveItem(at: backup, to: destination)
        try validateOwnedRegularFile(
            destination,
            identity: identity,
            label: "Restored skills index"
        )
    }

    private func unlinkOwnedRegularFile(
        _ url: URL,
        identity: String,
        label: String
    ) throws {
        let kind = try SkillPathSafety.entryKind(at: url)
        if kind == .missing { return }
        guard kind == .file else {
            throw SkillPathSafety.failure("\(label) is not a regular file")
        }
        try validateOwnedRegularFile(url, identity: identity, label: label)
        guard Darwin.unlink(url.path) == 0 else {
            throw posixFailure("Cannot remove \(label.lowercased())")
        }
    }

    private func validateOwnedRegularFile(
        _ url: URL,
        identity: String,
        label: String
    ) throws {
        guard try SkillPathSafety.entryKind(at: url) == .file,
              try SkillPathSafety.entryIdentity(at: url) == identity
        else {
            throw SkillPathSafety.failure("\(label) identity changed")
        }
    }

    private func identity(of information: stat) -> String {
        "\(information.st_dev):\(information.st_ino):\(information.st_mode & S_IFMT)"
    }

    private func posixFailure(_ message: String) -> SkillsServiceError {
        SkillPathSafety.failure("\(message): \(String(cString: strerror(errno)))")
    }

    private func synchronizeDirectory(_ url: URL) {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        _ = Darwin.close(descriptor)
    }
}
