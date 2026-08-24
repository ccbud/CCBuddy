import XCTest
@testable import CCBuddy

final class CLIConnectionManagerTests: XCTestCase {
    private enum InjectedFailure: Error { case write }

    private struct RecoveryManifest: Decodable {
        struct Entry: Decodable {
            let targetPath: String
            let originallyExisted: Bool
            let originalPermissions: Int?
            let recoveryFile: String?
        }

        let version: Int
        let entries: [Entry]
    }

    private var root: URL!
    private var repository: ConfigRepository!
    private var manager: CLIConnectionManager!
    private var claudeURL: URL!
    private var codexURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbud-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        claudeURL = root.appendingPathComponent("claude/settings.json")
        codexURL = root.appendingPathComponent("codex/config.toml")
        repository = ConfigRepository(configURL: root.appendingPathComponent("ccbud/config.json"))
        manager = CLIConnectionManager(
            repository: repository,
            environment: [
                "HOME": root.path,
                "CCBUD_CLAUDE_SETTINGS": claudeURL.path,
                "CCBUD_CODEX_CONFIG": codexURL.path,
            ]
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testClaudeConnectReconnectAndDisconnectRestoreAllOwnedValues() throws {
        try FileManager.default.createDirectory(at: claudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = #"{"model":"original-model","permissions":{"allow":["Read"]},"env":{"KEEP":"yes","ANTHROPIC_BASE_URL":"https://api.example.test","ANTHROPIC_AUTH_TOKEN":"original-token","ANTHROPIC_MODEL":"original-alias"}}"#
        try Data(original.utf8).write(to: claudeURL)

        var config = try manager.connectClaude(config: .fixture)
        var settings = try decodeJSONObject(at: claudeURL)
        var environment = try XCTUnwrap(settings["env"]?.objectValue)
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], .string("http://localhost:8788"))
        XCTAssertEqual(environment["ANTHROPIC_AUTH_TOKEN"], .string("ccbud-local"))
        XCTAssertNil(environment["ANTHROPIC_MODEL"])
        XCTAssertNil(settings["model"])
        XCTAssertEqual(settings["permissions"], .object(["allow": .array([.string("Read")])]))
        XCTAssertTrue(manager.isClaudeConnected(port: 8788))

        config.port = 9876
        config = try manager.connectClaude(config: config)
        settings = try decodeJSONObject(at: claudeURL)
        environment = try XCTUnwrap(settings["env"]?.objectValue)
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], .string("http://localhost:9876"))

        config = try manager.disconnectClaude(config: config)
        settings = try decodeJSONObject(at: claudeURL)
        environment = try XCTUnwrap(settings["env"]?.objectValue)
        XCTAssertEqual(environment["KEEP"], .string("yes"))
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], .string("https://api.example.test"))
        XCTAssertEqual(environment["ANTHROPIC_AUTH_TOKEN"], .string("original-token"))
        XCTAssertEqual(environment["ANTHROPIC_MODEL"], .string("original-alias"))
        XCTAssertEqual(settings["model"], .string("original-model"))
        XCTAssertTrue(config.claudeBackup.isNull)
        XCTAssertFalse(config.connectTargets.contains("claude"))
    }

    func testClaudeRefusesToOverwriteMalformedSettings() throws {
        try FileManager.default.createDirectory(at: claudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let malformed = Data("not-json".utf8)
        try malformed.write(to: claudeURL)
        XCTAssertThrowsError(try manager.connectClaude(config: .fixture))
        XCTAssertEqual(try Data(contentsOf: claudeURL), malformed)
    }

    func testCodexRoundTripPreservesCommentsUnrelatedSettingsAndPriorProviderBlock() throws {
        try FileManager.default.createDirectory(at: codexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = """
        # my codex config
        model = "gpt-5" # keep this exact comment
        model_provider = "openai"
        approval_policy = "on-request"

        [model_providers.other]
        name = "Other"
        base_url = "https://other.example/v1"

        [model_providers.ccbud]
        name = "User-owned prior block"
        base_url = "https://prior.example/v1"
        """ + "\n"
        try Data(original.utf8).write(to: codexURL)

        var config = try manager.connectCodex(config: .fixture)
        var connected = try String(contentsOf: codexURL, encoding: .utf8)
        XCTAssertTrue(connected.contains("# my codex config"))
        XCTAssertTrue(connected.contains("approval_policy = \"on-request\""))
        XCTAssertTrue(connected.contains("[model_providers.other]"))
        XCTAssertTrue(connected.contains("base_url = \"http://localhost:8788/v1\""))
        XCTAssertTrue(connected.contains("wire_api = \"responses\""))
        XCTAssertTrue(connected.contains("supports_websockets = false"))
        XCTAssertTrue(manager.isCodexConnected(port: 8788))

        config.port = 9988
        config = try manager.connectCodex(config: config)
        connected = try String(contentsOf: codexURL, encoding: .utf8)
        XCTAssertTrue(connected.contains("base_url = \"http://localhost:9988/v1\""))

        config = try manager.disconnectCodex(config: config)
        let restored = try String(contentsOf: codexURL, encoding: .utf8)
        XCTAssertTrue(restored.contains("model = \"gpt-5\" # keep this exact comment"))
        XCTAssertTrue(restored.contains("model_provider = \"openai\""))
        XCTAssertFalse(restored.contains("model_reasoning_effort"))
        XCTAssertTrue(restored.contains("[model_providers.other]"))
        XCTAssertTrue(restored.contains("name = \"User-owned prior block\""))
        XCTAssertTrue(restored.contains("base_url = \"https://prior.example/v1\""))
        XCTAssertTrue(config.codexBackup.isNull)
        XCTAssertFalse(config.connectTargets.contains("codex"))
    }

    func testCodexConnectCreatesAndDisconnectCleansFreshConfiguration() throws {
        var config = try manager.connectCodex(config: .fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexURL.path))
        XCTAssertTrue(manager.isCodexConnected(port: 8788))
        config = try manager.disconnectCodex(config: config)
        let restored = try String(contentsOf: codexURL, encoding: .utf8)
        XCTAssertFalse(restored.contains("ccbud"))
        XCTAssertFalse(restored.contains("model_reasoning_effort"))
        XCTAssertFalse(config.connectTargets.contains("codex"))
    }

    func testManagedFilesUsePrivatePermissions() throws {
        var config = try manager.connectClaude(config: .fixture)
        config = try manager.connectCodex(config: config)
        for url in [claudeURL!, codexURL!, repository.configURL] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        }
        XCTAssertEqual(Set(config.connectTargets), Set(["claude", "codex"]))
    }

    func testCombinedConnectNormalizesPortBeforeStagingBothCLIConfigurations() throws {
        var invalid = AppConfig.fixture
        invalid.port = 0

        let connected = try manager.updateConnections(
            config: invalid,
            claude: .connect,
            codex: .connect
        )

        let claude = try decodeJSONObject(at: claudeURL)
        let claudeEnvironment = try XCTUnwrap(claude["env"]?.objectValue)
        XCTAssertEqual(
            claudeEnvironment["ANTHROPIC_BASE_URL"],
            .string("http://localhost:8788")
        )
        let codex = try String(contentsOf: codexURL, encoding: .utf8)
        XCTAssertTrue(codex.contains("base_url = \"http://localhost:8788/v1\""))
        XCTAssertEqual(connected.port, 8788)
        XCTAssertEqual(try repository.load().port, 8788)
    }

    func testCombinedConnectRollsBackConfigAndBothCLIFilesWhenSecondCLIWriteFails() throws {
        try FileManager.default.createDirectory(
            at: claudeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: codexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let originalClaude = Data(#"{"env":{"KEEP":"claude"},"model":"prior"}"#.utf8)
        let originalCodex = Data("# prior\nmodel = \"gpt-5\"\n".utf8)
        try originalClaude.write(to: claudeURL)
        try originalCodex.write(to: codexURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: claudeURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: codexURL.path)
        var originalConfig = AppConfig.fixture
        originalConfig.gatewayEnabled = false
        try repository.save(originalConfig)
        let originalConfigData = try Data(contentsOf: repository.configURL)

        var injected = false
        let faulting = makeManager { [codexURL] data, url, fileManager in
            if url.standardizedFileURL == codexURL?.standardizedFileURL, !injected {
                injected = true
                throw InjectedFailure.write
            }
            try SecureAtomicFile.write(data, to: url, fileManager: fileManager)
        }

        XCTAssertThrowsError(try faulting.updateConnections(
            config: originalConfig,
            claude: .connect,
            codex: .connect
        ))
        XCTAssertTrue(injected)
        XCTAssertEqual(try Data(contentsOf: repository.configURL), originalConfigData)
        XCTAssertEqual(try Data(contentsOf: claudeURL), originalClaude)
        XCTAssertEqual(try Data(contentsOf: codexURL), originalCodex)
        XCTAssertEqual(try permissions(at: claudeURL), 0o644)
        XCTAssertEqual(try permissions(at: codexURL), 0o640)
        XCTAssertTrue(try recoveryTransactionDirectories().isEmpty)
    }

    func testRollbackFailureRetainsPrivateRecoveryJournalWithOriginalBytes() throws {
        try FileManager.default.createDirectory(
            at: claudeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: codexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let originalClaude = Data(#"{"env":{"KEEP":"claude"},"model":"prior"}"#.utf8)
        let originalCodex = Data("# untouched\nmodel = \"gpt-5\"\n".utf8)
        try originalClaude.write(to: claudeURL)
        try originalCodex.write(to: codexURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: claudeURL.path)
        var originalConfig = AppConfig.fixture
        originalConfig.gatewayEnabled = false
        try repository.save(originalConfig)
        let originalConfigData = try Data(contentsOf: repository.configURL)

        var writesByPath: [String: Int] = [:]
        let faulting = makeManager { [claudeURL, codexURL] data, url, fileManager in
            let path = url.standardizedFileURL.path
            writesByPath[path, default: 0] += 1
            if path == codexURL?.standardizedFileURL.path {
                throw InjectedFailure.write
            }
            if path == claudeURL?.standardizedFileURL.path, writesByPath[path] == 2 {
                throw InjectedFailure.write
            }
            try SecureAtomicFile.write(data, to: url, fileManager: fileManager)
        }

        var failedURLs: [URL] = []
        var retainedDirectory: URL?
        XCTAssertThrowsError(try faulting.updateConnections(
            config: originalConfig,
            claude: .connect,
            codex: .connect
        )) { error in
            guard case CLIConnectionError.rollbackFailed(let urls, let recoveryDirectory) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            failedURLs = urls
            retainedDirectory = recoveryDirectory
            XCTAssertTrue(error.localizedDescription.contains(recoveryDirectory.path))
        }

        let recoveryDirectory = try XCTUnwrap(retainedDirectory)
        XCTAssertEqual(failedURLs.map(\.standardizedFileURL), [claudeURL.standardizedFileURL])
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryDirectory.path))
        XCTAssertEqual(try permissions(at: recoveryDirectory), 0o700)
        XCTAssertEqual(try permissions(at: recoveryDirectory.deletingLastPathComponent()), 0o700)

        let journalURL = recoveryDirectory.appendingPathComponent("journal.json")
        XCTAssertEqual(try permissions(at: journalURL), 0o600)
        let manifest = try JSONDecoder().decode(
            RecoveryManifest.self,
            from: Data(contentsOf: journalURL)
        )
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.entries.count, 3)
        let entries = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.targetPath, $0) })
        let configPath = repository.configURL.resolvingSymlinksInPath().standardizedFileURL.path
        let claudePath = claudeURL.resolvingSymlinksInPath().standardizedFileURL.path
        let codexPath = codexURL.resolvingSymlinksInPath().standardizedFileURL.path
        let configEntry = try XCTUnwrap(entries[configPath])
        let claudeEntry = try XCTUnwrap(entries[claudePath])
        let codexEntry = try XCTUnwrap(entries[codexPath])
        XCTAssertTrue(configEntry.originallyExisted)
        XCTAssertTrue(claudeEntry.originallyExisted)
        XCTAssertTrue(codexEntry.originallyExisted)
        XCTAssertEqual(configEntry.originalPermissions, 0o600)
        XCTAssertEqual(claudeEntry.originalPermissions, 0o640)

        let configBackup = recoveryDirectory.appendingPathComponent(
            try XCTUnwrap(configEntry.recoveryFile)
        )
        let claudeBackup = recoveryDirectory.appendingPathComponent(
            try XCTUnwrap(claudeEntry.recoveryFile)
        )
        let codexBackup = recoveryDirectory.appendingPathComponent(
            try XCTUnwrap(codexEntry.recoveryFile)
        )
        XCTAssertEqual(try permissions(at: configBackup), 0o600)
        XCTAssertEqual(try permissions(at: claudeBackup), 0o600)
        XCTAssertEqual(try permissions(at: codexBackup), 0o600)
        XCTAssertEqual(try Data(contentsOf: configBackup), originalConfigData)
        XCTAssertEqual(try Data(contentsOf: claudeBackup), originalClaude)
        XCTAssertEqual(try Data(contentsOf: codexBackup), originalCodex)

        XCTAssertEqual(try Data(contentsOf: repository.configURL), originalConfigData)
        XCTAssertNotEqual(try Data(contentsOf: claudeURL), originalClaude)
        XCTAssertEqual(try Data(contentsOf: codexURL), originalCodex)
    }

    func testPendingRecoveryJournalDiscoveryReturnsOnlyDurableJournalDirectories() throws {
        let recoveryRoot = manager.recoveryRootURL
        let first = recoveryRoot.appendingPathComponent("transaction-b", isDirectory: true)
        let second = recoveryRoot.appendingPathComponent("transaction-a", isDirectory: true)
        let incomplete = recoveryRoot.appendingPathComponent("transaction-incomplete", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try Data("{}".utf8).write(
            to: first.appendingPathComponent(CLIConnectionManager.recoveryJournalFileName)
        )
        try Data("{}".utf8).write(
            to: second.appendingPathComponent(CLIConnectionManager.recoveryJournalFileName)
        )

        XCTAssertEqual(
            try manager.pendingRecoveryJournalDirectories().map(\.lastPathComponent),
            ["transaction-a", "transaction-b"]
        )
    }

    func testPendingRecoveryJournalDiscoveryRejectsSymlinkedTransactionDirectory() throws {
        let recoveryRoot = manager.recoveryRootURL
        let outside = root.appendingPathComponent("outside-transaction", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("{}".utf8).write(
            to: outside.appendingPathComponent(CLIConnectionManager.recoveryJournalFileName)
        )
        try FileManager.default.createSymbolicLink(
            at: recoveryRoot.appendingPathComponent(".transaction-symlink", isDirectory: true),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try manager.pendingRecoveryJournalDirectories())
    }

    func testPendingRecoveryJournalDiscoveryRejectsNonDirectoryTransactionEntry() throws {
        let recoveryRoot = manager.recoveryRootURL
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        try Data("not-a-transaction-directory".utf8).write(
            to: recoveryRoot.appendingPathComponent("transaction-file")
        )

        XCTAssertThrowsError(try manager.pendingRecoveryJournalDirectories())
    }

    func testPendingRecoveryJournalDiscoveryRejectsSymlinkedJournal() throws {
        let recoveryRoot = manager.recoveryRootURL
        let transaction = recoveryRoot.appendingPathComponent("transaction", isDirectory: true)
        let outsideJournal = root.appendingPathComponent("outside-journal.json")
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: outsideJournal)
        try FileManager.default.createSymbolicLink(
            at: transaction.appendingPathComponent(CLIConnectionManager.recoveryJournalFileName),
            withDestinationURL: outsideJournal
        )

        XCTAssertThrowsError(try manager.pendingRecoveryJournalDirectories())
    }

    func testPendingRecoveryJournalDiscoveryRejectsUninspectableJournal() throws {
        let recoveryRoot = manager.recoveryRootURL
        let transaction = recoveryRoot.appendingPathComponent("transaction", isDirectory: true)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        try Data("{}".utf8).write(
            to: transaction.appendingPathComponent(CLIConnectionManager.recoveryJournalFileName)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: transaction.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: transaction.path
            )
        }

        XCTAssertThrowsError(try manager.pendingRecoveryJournalDirectories())
    }

    func testRecoveryJournalCreationFailurePerformsNoForwardWrites() throws {
        var original = AppConfig.fixture
        original.gatewayEnabled = false
        try repository.save(original)
        let originalConfigData = try Data(contentsOf: repository.configURL)
        try Data("recovery-root-is-not-a-directory".utf8).write(to: manager.recoveryRootURL)

        var writes = 0
        let observing = makeManager { data, url, fileManager in
            writes += 1
            try SecureAtomicFile.write(data, to: url, fileManager: fileManager)
        }

        XCTAssertThrowsError(try observing.updateConnections(
            config: original,
            claude: .connect,
            codex: .connect
        ))
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try Data(contentsOf: repository.configURL), originalConfigData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexURL.path))
    }

    func testPreseededRecoveryRootSymlinkIsRejectedBeforeForwardWrites() throws {
        var original = AppConfig.fixture
        original.gatewayEnabled = false
        try repository.save(original)
        let originalConfigData = try Data(contentsOf: repository.configURL)
        let outside = root.appendingPathComponent("outside-recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: manager.recoveryRootURL,
            withDestinationURL: outside
        )
        var writes = 0
        let observing = makeManager { data, url, fileManager in
            writes += 1
            try SecureAtomicFile.write(data, to: url, fileManager: fileManager)
        }

        XCTAssertThrowsError(try observing.updateConnections(
            config: original,
            claude: .connect,
            codex: .connect
        ))
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try Data(contentsOf: repository.configURL), originalConfigData)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexURL.path))
    }

    func testFailedDirectorySyncAfterUnlinkRetainsRecoveryJournal() throws {
        var original = AppConfig.fixture
        original.gatewayEnabled = false
        try repository.save(original)
        var writesByPath: [String: Int] = [:]
        let claudeDirectory = claudeURL.deletingLastPathComponent().standardizedFileURL
        let faulting = CLIConnectionManager(
            repository: repository,
            environment: [
                "HOME": root.path,
                "CCBUD_CLAUDE_SETTINGS": claudeURL.path,
                "CCBUD_CODEX_CONFIG": codexURL.path,
            ],
            fileWriter: { [codexURL] data, url, fileManager in
                let path = url.standardizedFileURL.path
                writesByPath[path, default: 0] += 1
                if path == codexURL?.standardizedFileURL.path {
                    throw InjectedFailure.write
                }
                try SecureAtomicFile.write(data, to: url, fileManager: fileManager)
            },
            directorySynchronizer: { directory in
                if directory.standardizedFileURL == claudeDirectory {
                    throw InjectedFailure.write
                }
            }
        )

        XCTAssertThrowsError(try faulting.updateConnections(
            config: original,
            claude: .connect,
            codex: .connect
        )) { error in
            guard let connectionError = error as? CLIConnectionError,
                  case .rollbackFailed(let failed, let recoveryDirectory) = connectionError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failed.map(\.standardizedFileURL), [claudeURL.standardizedFileURL])
            XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryDirectory.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeURL.path))
        XCTAssertEqual(try faulting.pendingRecoveryJournalDirectories().count, 1)
    }

    func testCombinedConnectPreflightsBothDocumentsBeforeWritingAnything() throws {
        try FileManager.default.createDirectory(
            at: claudeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: codexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let originalClaude = Data(#"{"env":{"KEEP":"yes"}}"#.utf8)
        let invalidCodex = Data([0xFF, 0xFE, 0xFD])
        try originalClaude.write(to: claudeURL)
        try invalidCodex.write(to: codexURL)
        var originalConfig = AppConfig.fixture
        originalConfig.gatewayEnabled = false
        try repository.save(originalConfig)
        let originalConfigData = try Data(contentsOf: repository.configURL)
        var writes = 0
        let observing = makeManager { data, url, fileManager in
            writes += 1
            try SecureAtomicFile.write(data, to: url, fileManager: fileManager)
        }

        XCTAssertThrowsError(try observing.updateConnections(
            config: originalConfig,
            claude: .connect,
            codex: .connect
        )) { error in
            guard case CLIConnectionError.invalidCodexConfiguration = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try Data(contentsOf: repository.configURL), originalConfigData)
        XCTAssertEqual(try Data(contentsOf: claudeURL), originalClaude)
        XCTAssertEqual(try Data(contentsOf: codexURL), invalidCodex)
    }

    func testCombinedDisconnectRollsBackBothCLIFilesWhenFinalConfigWriteFails() throws {
        try FileManager.default.createDirectory(
            at: claudeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: codexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"env":{"KEEP":"yes"}}"#.utf8).write(to: claudeURL)
        try Data("model = \"gpt-5\"\n".utf8).write(to: codexURL)
        var initial = AppConfig.fixture
        initial.gatewayEnabled = false
        let connected = try manager.updateConnections(
            config: initial,
            claude: .connect,
            codex: .connect
        )
        let connectedConfig = try Data(contentsOf: repository.configURL)
        let connectedClaude = try Data(contentsOf: claudeURL)
        let connectedCodex = try Data(contentsOf: codexURL)

        var injected = false
        let faulting = makeManager { [repository] data, url, fileManager in
            if url.standardizedFileURL == repository?.configURL.standardizedFileURL, !injected {
                injected = true
                throw InjectedFailure.write
            }
            try SecureAtomicFile.write(data, to: url, fileManager: fileManager)
        }

        XCTAssertThrowsError(try faulting.updateConnections(
            config: connected,
            claude: .disconnect,
            codex: .disconnect
        ))
        XCTAssertTrue(injected)
        XCTAssertEqual(try Data(contentsOf: repository.configURL), connectedConfig)
        XCTAssertEqual(try Data(contentsOf: claudeURL), connectedClaude)
        XCTAssertEqual(try Data(contentsOf: codexURL), connectedCodex)
        XCTAssertEqual(try repository.load(), connected)
    }

    func testDisconnectWithoutOwnershipDoesNotCreateMissingCLIConfigFiles() throws {
        var config = AppConfig.fixture
        config.gatewayEnabled = false

        let disconnected = try manager.updateConnections(
            config: config,
            claude: .disconnect,
            codex: .disconnect
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexURL.path))
        XCTAssertTrue(disconnected.connectTargets.isEmpty)
        XCTAssertEqual(try repository.load(), disconnected)
    }

    func testDisconnectLeavesUnownedLocalProxyConfigurationsByteIdentical() throws {
        try FileManager.default.createDirectory(
            at: claudeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: codexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let unownedClaude = Data(
            #"{"env":{"ANTHROPIC_BASE_URL":"http://localhost:8788/anthropic","KEEP":"yes"}}"#.utf8
        )
        let unownedCodex = Data("""
        model = "user-model"
        model_provider = "user-proxy"

        [model_providers.user-proxy]
        base_url = "http://127.0.0.1:8788/openai/v1"
        """.utf8)
        try unownedClaude.write(to: claudeURL)
        try unownedCodex.write(to: codexURL)
        var config = AppConfig.fixture
        config.connectTargets = ["claude", "codex"]

        let disconnected = try manager.updateConnections(
            config: config,
            claude: .disconnect,
            codex: .disconnect
        )

        XCTAssertEqual(try Data(contentsOf: claudeURL), unownedClaude)
        XCTAssertEqual(try Data(contentsOf: codexURL), unownedCodex)
        XCTAssertTrue(disconnected.connectTargets.isEmpty)
        XCTAssertTrue(disconnected.claudeBackup.isNull)
        XCTAssertTrue(disconnected.codexBackup.isNull)
    }

    func testMalformedUnownedClaudeSettingsDoNotBlockDisconnectingOwnedCodex() throws {
        try FileManager.default.createDirectory(
            at: claudeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: codexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let originalCodex = Data("# prior\nmodel = \"gpt-5\"\n".utf8)
        try originalCodex.write(to: codexURL)
        var connected = try manager.connectCodex(config: .fixture)
        let malformedClaude = Data("not-json-and-not-owned".utf8)
        try malformedClaude.write(to: claudeURL)
        connected.connectTargets.append("claude")

        let disconnected = try manager.updateConnections(
            config: connected,
            claude: .disconnect,
            codex: .disconnect
        )

        XCTAssertEqual(try Data(contentsOf: claudeURL), malformedClaude)
        XCTAssertEqual(try Data(contentsOf: codexURL), originalCodex)
        XCTAssertTrue(disconnected.connectTargets.isEmpty)
        XCTAssertTrue(disconnected.codexBackup.isNull)
    }

    func testManagedWritesPreserveSymlinkedCLIConfigurationFiles() throws {
        let targets = root.appendingPathComponent("dotfiles", isDirectory: true)
        let claudeTarget = targets.appendingPathComponent("claude-settings.json")
        let codexTarget = targets.appendingPathComponent("codex-config.toml")
        try FileManager.default.createDirectory(at: targets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: claudeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: codexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"env":{"KEEP":"yes"}}"#.utf8).write(to: claudeTarget)
        try Data("model = \"gpt-5\"\n".utf8).write(to: codexTarget)
        try FileManager.default.createSymbolicLink(at: claudeURL, withDestinationURL: claudeTarget)
        try FileManager.default.createSymbolicLink(at: codexURL, withDestinationURL: codexTarget)
        var initial = AppConfig.fixture
        initial.gatewayEnabled = false

        let connected = try manager.updateConnections(
            config: initial,
            claude: .connect,
            codex: .connect
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: claudeURL.path),
            claudeTarget.path
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: codexURL.path),
            codexTarget.path
        )
        XCTAssertTrue(try String(contentsOf: claudeTarget, encoding: .utf8).contains("ANTHROPIC_BASE_URL"))
        XCTAssertTrue(try String(contentsOf: codexTarget, encoding: .utf8).contains("model_providers.ccbud"))

        _ = try manager.updateConnections(
            config: connected,
            claude: .disconnect,
            codex: .disconnect
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: claudeURL.path),
            claudeTarget.path
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: codexURL.path),
            codexTarget.path
        )
    }

    func testMixedConnectAndDisconnectMutationIsRejectedBeforeAnyWrite() throws {
        var original = AppConfig.fixture
        original.gatewayEnabled = false
        try repository.save(original)
        let configBefore = try Data(contentsOf: repository.configURL)

        XCTAssertThrowsError(try manager.updateConnections(
            config: original,
            claude: .connect,
            codex: .disconnect
        )) { error in
            guard case CLIConnectionError.mixedConnectionUpdates = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: repository.configURL), configBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexURL.path))
    }

    private func makeManager(fileWriter: @escaping CLIConnectionManager.FileWriter) -> CLIConnectionManager {
        CLIConnectionManager(
            repository: repository,
            environment: [
                "HOME": root.path,
                "CCBUD_CLAUDE_SETTINGS": claudeURL.path,
                "CCBUD_CODEX_CONFIG": codexURL.path,
            ],
            fileWriter: fileWriter
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    private func recoveryTransactionDirectories() throws -> [URL] {
        let recoveryRoot = repository.configURL.deletingLastPathComponent()
            .appendingPathComponent(CLIConnectionManager.recoveryDirectoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: recoveryRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: recoveryRoot,
            includingPropertiesForKeys: nil
        )
    }

    private func decodeJSONObject(at url: URL) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        return try XCTUnwrap(value.objectValue)
    }
}
