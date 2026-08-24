import Foundation
import XCTest
@testable import CCBuddy

final class ConversationMutationServiceTests: XCTestCase {
    func testMetadataEditNormalizesInSQLiteAndNeverRewritesClaudeJSONL() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = "not-json\n" +
            #"{"type":"user","sessionId":"edit","message":{"role":"user","content":"hello"}}"# +
            "\n" + #"{"type":"assistant","message":{"role":"assistant","content":"world"}}"# + "\n"
        let file = try fixture.writeSession(
            name: "edit",
            text: original
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: file.path
        )
        let metadata = fixture.metadata(file: file)

        try fixture.service.updateMetadata(
            for: metadata,
            patch: .init(title: "  新标题  ", tags: [" one ", "one", "", "two"])
        )
        var user = try fixture.database.userMetadata(for: file)
        XCTAssertEqual(user.title, "新标题")
        XCTAssertEqual(user.tags, ["one", "two"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)

        try fixture.service.updateMetadata(
            for: metadata,
            patch: .init(title: "", tags: [], deleted: false)
        )
        user = try fixture.database.userMetadata(for: file)
        XCTAssertNil(user.title)
        XCTAssertEqual(user.tags, [])
        XCTAssertEqual(user.deleted, false)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
    }

    func testMetadataEditsForQoderAndCodexDoNotWriteProducerOrLegacySidecars() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for source in [HistorySource.qoder, .codex] {
            let raw = Self.claudeJSONL(id: source.rawValue)
            let file = try fixture.writeSession(name: source.rawValue, text: raw)
            let metadata = fixture.metadata(file: file, source: source)
            try fixture.service.updateMetadata(
                for: metadata,
                patch: .init(title: "App title", tags: ["owned"], deleted: true)
            )
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), raw)
            let user = try fixture.database.userMetadata(for: file)
            XCTAssertEqual(user.title, "App title")
            XCTAssertEqual(user.tags, ["owned"])
            XCTAssertEqual(user.deleted, true)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.configuration.appDataRoot.appendingPathComponent("agent-meta.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.configuration.appDataRoot.appendingPathComponent("codex-meta.json").path
        ))
    }

    func testScopeAndSymlinkAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let outside = fixture.root.appendingPathComponent("outside.jsonl")
        try Data(Self.claudeJSONL(id: "outside").utf8).write(to: outside)
        XCTAssertThrowsError(try fixture.service.softDelete(fixture.metadata(file: outside))) { error in
            XCTAssertEqual(error as? ConversationMutationError, .outsideAllowedRoots(outside))
        }

        let target = try fixture.writeSession(name: "target", text: Self.claudeJSONL(id: "target"))
        let link = fixture.projectDirectory.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try fixture.service.softDelete(fixture.metadata(file: link))) { error in
            XCTAssertEqual(error as? ConversationMutationError, .symbolicLink(link))
        }
    }

    func testLiveProducerUsesSQLiteAndCannotBePermanentlyDeleted() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try fixture.writeSession(
            name: "rollout-abc",
            text: #"{"type":"session_meta","payload":{"id":"abc","cwd":"/tmp/p"}}"# + "\n"
        )
        var metadata = fixture.metadata(file: file, source: .codex, imported: false)
        metadata.id = "codex:test:rollout-abc"

        try fixture.service.updateMetadata(
            for: metadata,
            patch: .init(title: "Codex title", tags: ["live"], deleted: true)
        )
        XCTAssertFalse(try String(contentsOf: file).contains("__ccbud__"))
        let custom = try fixture.database.userMetadata(for: file)
        XCTAssertEqual(custom.title, "Codex title")
        XCTAssertEqual(custom.tags, ["live"])
        XCTAssertEqual(custom.deleted, true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.configuration.appDataRoot.appendingPathComponent("codex-meta.json").path
        ))

        XCTAssertThrowsError(try fixture.service.permanentlyDelete(metadata)) { error in
            XCTAssertEqual(error as? ConversationMutationError, .foreignPermanentDelete)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testLiveClaudeIsAlsoReadOnlyForPermanentDelete() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try fixture.writeSession(name: "claude-live", text: Self.claudeJSONL(id: "live"))
        let metadata = fixture.metadata(file: file, source: .claude, imported: false)

        XCTAssertFalse(fixture.service.canPermanentlyDelete(metadata))
        XCTAssertThrowsError(try fixture.service.permanentlyDelete(metadata)) { error in
            XCTAssertEqual(error as? ConversationMutationError, .foreignPermanentDelete)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testForgedImportedFlagCannotDeleteAProducerFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try fixture.writeSession(name: "forged-import", text: Self.claudeJSONL(id: "forged"))
        let metadata = fixture.metadata(file: file, source: .claude, imported: true)

        XCTAssertFalse(fixture.service.canPermanentlyDelete(metadata))
        XCTAssertThrowsError(try fixture.service.permanentlyDelete(metadata)) { error in
            XCTAssertEqual(error as? ConversationMutationError, .foreignPermanentDelete)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testStarAndPinTogglesPersistThroughMutationProtocol() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try fixture.writeSession(name: "favorite", text: Self.claudeJSONL(id: "favorite"))
        var metadata = fixture.metadata(file: file)
        let mutating: any ConversationMutating = fixture.service

        try mutating.toggleStarred(metadata)
        try mutating.togglePinned(metadata)
        var user = try fixture.database.userMetadata(for: file)
        XCTAssertTrue(user.starred)
        XCTAssertTrue(user.pinned)

        metadata.starred = true
        metadata.pinned = true
        try mutating.toggleStarred(metadata)
        try mutating.togglePinned(metadata)
        user = try fixture.database.userMetadata(for: file)
        XCTAssertFalse(user.starred)
        XCTAssertFalse(user.pinned)
    }

    func testImportedPermanentDeleteCleansManifestAndSubagents() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let directory = fixture.configuration.importsRoot
            .appendingPathComponent("projects/-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("owned.jsonl")
        try Data(Self.claudeJSONL(id: "owned").utf8).write(to: file)
        let manifest = directory.appendingPathComponent("owned.import.json")
        try Data("{}".utf8).write(to: manifest)
        let subagents = directory.appendingPathComponent("owned/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try Data(Self.claudeJSONL(id: "agent").utf8)
            .write(to: subagents.appendingPathComponent("agent-a.jsonl"))

        let metadata = fixture.metadata(file: file, source: .codex, imported: true)
        try fixture.service.updateMetadata(for: metadata, patch: .init(starred: true, pinned: true))
        XCTAssertTrue(try fixture.database.userMetadata(for: file).starred)
        try fixture.service.permanentlyDelete(metadata)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: subagents.path))
        XCTAssertEqual(try fixture.database.userMetadata(for: file), .init())
    }

    func testJSONLAndZIPSubagentImportRoundTripAndDuplicateSummary() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sourceDirectory = fixture.root.appendingPathComponent("drop", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("source.jsonl")
        try Data(Self.claudeJSONL(id: "roundtrip", cwd: "/tmp/project").utf8).write(to: source)
        let sourceSubs = sourceDirectory.appendingPathComponent("source/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceSubs, withIntermediateDirectories: true)
        try Data(Self.claudeJSONL(id: "agent-a").utf8)
            .write(to: sourceSubs.appendingPathComponent("agent-a.jsonl"))
        try Data(#"{"toolUseId":"tool-a"}"#.utf8)
            .write(to: sourceSubs.appendingPathComponent("agent-a.meta.json"))

        let first = fixture.service.importFile(source)
        guard case .imported(let imported) = first else {
            return XCTFail("expected import, got \(first)")
        }
        guard case .skipped(let skipped) = fixture.service.importFile(source) else {
            return XCTFail("duplicate must be skipped")
        }
        XCTAssertEqual(imported, skipped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
        let importedSubs = imported.deletingLastPathComponent()
            .appendingPathComponent("roundtrip/subagents", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: importedSubs.path).sorted(),
            ["agent-a.jsonl", "agent-a.meta.json"]
        )

        let export = fixture.root.appendingPathComponent("roundtrip.zip")
        let exportMetadata = fixture.metadata(file: imported, imported: true)
        let exportResult = try fixture.service.exportRaw(exportMetadata, to: export)
        XCTAssertTrue(exportResult.bundled)
        let bundle = try ConversationArchive.splitBundle(
            ConversationArchive.read(Data(contentsOf: export))
        )
        XCTAssertEqual(bundle.main.data, Data(Self.claudeJSONL(id: "roundtrip", cwd: "/tmp/project").utf8))
        XCTAssertEqual(bundle.subagents.count, 2)

        let secondImports = fixture.root.appendingPathComponent("second-app/imports", isDirectory: true)
        let second = ConversationMutationService(configuration: .init(
            historyDirs: [fixture.historyRoot.path],
            homeDirectory: fixture.root,
            importsRoot: secondImports
        ))
        guard case .imported(let secondFile) = second.importFile(export) else {
            return XCTFail("exported bundle must import into a fresh store")
        }
        XCTAssertEqual(try Data(contentsOf: secondFile), try Data(contentsOf: imported))
    }

    func testBareForeignJSONLIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("foreign.jsonl")
        try Data(#"{"type":"session.start","data":{"producer":"copilot-agent"}}"#.utf8)
            .write(to: source)
        guard case .failed(_, let reason) = fixture.service.importFile(source) else {
            return XCTFail("foreign transcript must fail")
        }
        XCTAssertTrue(reason.contains("不能作为裸 JSONL 导入"))
    }

    func testImportedQoderMetadataRoundTripUsesInlineMetadataInsteadOfLiveSidecar() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let uuid = "22222222-2222-4222-8222-222222222222"
        let source = fixture.root.appendingPathComponent("qoder.jsonl")
        let transcript = [
            #"{"type":"ai-title","sessionId":"\#(uuid)","aiTitle":"Imported Qoder"}"#,
            #"{"type":"workspace-directories","sessionId":"\#(uuid)","directories":["/tmp/qimport"]}"#,
            #"{"type":"user","sessionId":"\#(uuid)","message":{"role":"user","content":"hello"}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(transcript.utf8).write(to: source)
        guard case .imported(let imported) = fixture.service.importFile(source) else {
            return XCTFail("Qoder transcript should import")
        }

        let sidecar = fixture.configuration.appDataRoot.appendingPathComponent("agent-meta.json")
        let conflicting = #"{"qoder:\#(uuid)":{"title":"Wrong live title","tagList":["wrong"],"delete":true}}"#
        try Data(conflicting.utf8).write(to: sidecar)
        let importedRepository = HistoryRepository(
            historyDirs: [fixture.historyRoot.path],
            active: "__imported__",
            homeDirectory: fixture.root,
            importsRoot: fixture.configuration.importsRoot
        )
        let metadata = try XCTUnwrap(importedRepository.listSessions().first)
        XCTAssertEqual(metadata.file, imported)
        XCTAssertEqual(metadata.source, .qoder)
        XCTAssertTrue(metadata.imported)
        XCTAssertEqual(metadata.title, "Imported Qoder")
        XCTAssertEqual(metadata.tags, [])

        _ = try fixture.database.replace(ConversationIndexedSession(
            metadata: metadata,
            fingerprint: .init(modificationTime: .now, sizeBytes: metadata.sizeBytes),
            documents: []
        ))
        let importedBytes = try Data(contentsOf: imported)
        try fixture.service.updateMetadata(
            for: metadata,
            patch: .init(title: "Edited import", tags: ["local"], deleted: true)
        )
        let trashed = try XCTUnwrap(
            fixture.database.listEntries(deleted: true, limit: .max).first?.metadata
        )
        XCTAssertEqual(trashed.file, imported)
        XCTAssertEqual(trashed.title, "Edited import")
        XCTAssertEqual(trashed.tags, ["local"])
        XCTAssertTrue(trashed.deleted)
        XCTAssertEqual(try Data(contentsOf: imported), importedBytes)
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), conflicting)
    }

    private static func claudeJSONL(id: String, cwd: String = "/tmp/test") -> String {
        #"{"type":"user","sessionId":"\#(id)","cwd":"\#(cwd)","message":{"role":"user","content":"hello"}}"# + "\n"
    }
}

private final class Fixture {
    let root: URL
    let historyRoot: URL
    let projectDirectory: URL
    let configuration: ConversationMutationConfiguration
    let database: ConversationIndexDatabase
    let service: ConversationMutationService

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversation-mutation-\(UUID().uuidString)", isDirectory: true)
        historyRoot = root.appendingPathComponent("history", isDirectory: true)
        projectDirectory = historyRoot.appendingPathComponent("projects/-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        configuration = ConversationMutationConfiguration(
            historyDirs: [historyRoot.path],
            homeDirectory: root,
            importsRoot: root.appendingPathComponent("app/imports", isDirectory: true)
        )
        database = try ConversationIndexDatabase(file: configuration.conversationDatabase)
        service = ConversationMutationService(
            configuration: configuration,
            metadataDatabase: database
        )
    }

    func writeSession(name: String, text: String) throws -> URL {
        let file = projectDirectory.appendingPathComponent("\(name).jsonl")
        try Data(text.utf8).write(to: file)
        return file
    }

    func metadata(
        file: URL,
        source: HistorySource = .claude,
        imported: Bool = false
    ) -> HistorySessionMetadata {
        HistorySessionMetadata(
            id: "\(source.rawValue):\(file.deletingPathExtension().lastPathComponent)",
            file: file,
            source: source,
            dirID: imported ? "__imported__" : historyRoot.path,
            dirLabel: imported ? "导入" : historyRoot.path,
            sessionID: file.deletingPathExtension().lastPathComponent,
            cwd: "/tmp/test",
            project: "test",
            title: "Test",
            autoTitle: "Test",
            imported: imported,
            deleted: false,
            createdAt: Date(timeIntervalSince1970: 1),
            lastActivity: Date(timeIntervalSince1970: 2),
            sizeBytes: 1
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
