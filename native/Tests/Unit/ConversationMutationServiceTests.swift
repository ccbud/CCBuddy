import Foundation
import SQLite3
import XCTest
@testable import CCBuddy

final class ConversationMutationServiceTests: XCTestCase {
    func testEverySourceMetadataMutationSurvivesRawRepositoryReload() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sources: [HistorySource] = [.qoder, .grok, .copilot, .antigravity, .codex, .claude]

        for source in sources {
            let file = try fixture.writeProducerSession(source: source, id: "round-trip")
            let original = try Data(contentsOf: file)
            let metadata = try fixture.repository().getSession(file: file).metadata
            XCTAssertEqual(metadata.source, source)
            let title = "Edited \(source.rawValue)"
            try fixture.service.updateMetadata(
                for: metadata,
                patch: .init(title: title, tags: [" keep ", "keep"], deleted: true,
                    starred: true, pinned: true)
            )

            // A new raw repository deliberately bypasses all catalog/in-memory metadata.
            let reloaded = try fixture.repository().getSession(file: file).metadata
            XCTAssertEqual(reloaded.title, title, source.rawValue)
            XCTAssertEqual(reloaded.tags, ["keep"], source.rawValue)
            XCTAssertTrue(reloaded.deleted, source.rawValue)
            XCTAssertTrue(reloaded.starred, source.rawValue)
            XCTAssertTrue(reloaded.pinned, source.rawValue)
            XCTAssertFalse(fixture.repository().listSessions().contains { $0.file == file })
            XCTAssertTrue(fixture.repository(active: "__trash__").listSessions()
                .contains { $0.file == file })
            if source != .claude {
                XCTAssertEqual(try Data(contentsOf: file), original,
                    "live foreign transcript must remain untouched: \(source.rawValue)")
            }

            try fixture.service.updateMetadata(
                for: reloaded,
                patch: .init(title: "", tags: [], deleted: false, starred: false, pinned: false)
            )
            let restored = try fixture.repository().getSession(file: file).metadata
            XCTAssertEqual(restored.title, restored.autoTitle, source.rawValue)
            XCTAssertEqual(restored.tags, [], source.rawValue)
            XCTAssertFalse(restored.deleted, source.rawValue)
            XCTAssertFalse(restored.starred, source.rawValue)
            XCTAssertFalse(restored.pinned, source.rawValue)
            XCTAssertTrue(fixture.repository().listSessions().contains { $0.file == file })
            XCTAssertFalse(fixture.repository(active: "__trash__").listSessions()
                .contains { $0.file == file })
        }
    }

    func testForeignMetadataWithSharedProducerIDStaysSourceScopedAndPreservesLegacyKeys() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sources: [HistorySource] = [.qoder, .grok, .copilot, .antigravity]
        let id = "shared-producer-id"
        let files = try sources.map { try fixture.writeProducerSession(source: $0, id: id) }
        let sidecar = fixture.configuration.appDataRoot.appendingPathComponent("agent-meta.json")
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let legacy: [String: Any] = ["title": "Ambiguous legacy title", "starred": true]
        try JSONSerialization.data(withJSONObject: [id: legacy]).write(to: sidecar)

        for (index, file) in files.enumerated() {
            let metadata = try fixture.repository().getSession(file: file).metadata
            XCTAssertFalse(metadata.starred, "unscoped legacy facts cannot be attributed safely")
            try fixture.service.updateMetadata(
                for: metadata,
                patch: .init(title: "Owned by \(sources[index].rawValue)", tags: [sources[index].rawValue],
                    deleted: index.isMultiple(of: 2), starred: true, pinned: index.isMultiple(of: 2))
            )
        }

        for (index, file) in files.enumerated() {
            let metadata = try fixture.repository().getSession(file: file).metadata
            XCTAssertEqual(metadata.title, "Owned by \(sources[index].rawValue)")
            XCTAssertEqual(metadata.tags, [sources[index].rawValue])
            XCTAssertEqual(metadata.deleted, index.isMultiple(of: 2))
            XCTAssertTrue(metadata.starred)
            XCTAssertEqual(metadata.pinned, index.isMultiple(of: 2))
        }
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar))
            as? [String: Any])
        XCTAssertEqual(Set(root.keys), Set([id] + sources.map { "\($0.rawValue):\(id)" }))
        XCTAssertEqual(root[id] as? NSDictionary, legacy as NSDictionary,
            "do not delete or guess a source for an existing unscoped record")
    }

    func testForeignMetadataFallbackSessionIDKeepsItsSourcePrefix() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try fixture.writeProducerSession(source: .qoder, id: "fallback")
        var metadata = try fixture.repository().getSession(file: file).metadata
        metadata.id = "nonstandard-producer-identity"
        try fixture.service.updateMetadata(for: metadata, patch: .init(starred: true))
        XCTAssertTrue(try fixture.repository().getSession(file: file).metadata.starred)
    }

    func testInlineMetadataEditNormalizesAndClearsFields() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try fixture.writeSession(
            name: "edit",
            text: "not-json\n" +
                #"{"type":"user","sessionId":"edit","message":{"role":"user","content":"hello"}}"# +
                "\n" + #"{"type":"assistant","message":{"role":"assistant","content":"world"}}"# + "\n"
        )
        let metadata = fixture.metadata(file: file)

        try fixture.service.updateMetadata(
            for: metadata,
            patch: .init(title: "  新标题  ", tags: [" one ", "one", "", "two"])
        )
        var first = try firstJSONObject(file)
        let custom = try XCTUnwrap(first["__ccbud__"] as? [String: Any])
        XCTAssertEqual(custom["title"] as? String, "新标题")
        XCTAssertEqual(custom["tagList"] as? [String], ["one", "two"])

        try fixture.service.updateMetadata(
            for: metadata,
            patch: .init(title: "", tags: [], deleted: false)
        )
        first = try firstJSONObject(file)
        XCTAssertNil(first["__ccbud__"])
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("not-json\n"), "malformed prefix must remain in place")
        XCTAssertTrue(text.hasSuffix("\n"), "trailing newline must be preserved")
    }

    /// Starring is CC Buddy's own fact about a session, so it is written into the app's metadata
    /// record and is absent — not `false` — when the session is not starred. Persisting a false flag
    /// for every session the user ever opened would grow the record for no information.
    func testStarRoundTripsAndClearsTheKeyWhenRemoved() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try fixture.writeSession(name: "star", text: Self.claudeJSONL(id: "star"))
        let metadata = fixture.metadata(file: file)

        try fixture.service.updateMetadata(for: metadata, patch: .init(starred: true))
        var custom = try XCTUnwrap(firstJSONObject(file)["__ccbud__"] as? [String: Any])
        XCTAssertEqual(custom["starred"] as? Bool, true)

        XCTAssertTrue(
            HistoryParsingSupport.customMetadata([
                ["__ccbud__": .object(["starred": .bool(true)])],
            ]).starred,
            "the parser must read back what the mutation wrote"
        )

        try fixture.service.updateMetadata(for: metadata, patch: .init(starred: false))
        let record = firstJSONObjectIfPresent(file)?["__ccbud__"] as? [String: Any]
        custom = record ?? [:]
        XCTAssertNil(custom["starred"])
    }

    func testStarIsIndependentOfTitleAndTags() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try fixture.writeSession(name: "star-independent", text: Self.claudeJSONL(id: "si"))
        let metadata = fixture.metadata(file: file)

        try fixture.service.updateMetadata(for: metadata, patch: .init(title: "保留", tags: ["keep"]))
        try fixture.service.updateMetadata(for: metadata, patch: .init(starred: true))

        // A patch carries only the fields it names; starring must not erase an edited title.
        let custom = try XCTUnwrap(firstJSONObject(file)["__ccbud__"] as? [String: Any])
        XCTAssertEqual(custom["title"] as? String, "保留")
        XCTAssertEqual(custom["tagList"] as? [String], ["keep"])
        XCTAssertEqual(custom["starred"] as? Bool, true)
    }

    /// Star and pin are independent facts about the same session. A patch names only the fields it
    /// carries, so setting one must leave the other alone.
    func testStarAndPinAreIndependent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try fixture.writeSession(name: "star-pin", text: Self.claudeJSONL(id: "sp"))
        let metadata = fixture.metadata(file: file)

        try fixture.service.updateMetadata(for: metadata, patch: .init(starred: true))
        try fixture.service.updateMetadata(for: metadata, patch: .init(pinned: true))
        var custom = try XCTUnwrap(firstJSONObject(file)["__ccbud__"] as? [String: Any])
        XCTAssertEqual(custom["starred"] as? Bool, true)
        XCTAssertEqual(custom["pinned"] as? Bool, true)

        try fixture.service.updateMetadata(for: metadata, patch: .init(starred: false))
        custom = try XCTUnwrap(firstJSONObject(file)["__ccbud__"] as? [String: Any])
        XCTAssertNil(custom["starred"])
        XCTAssertEqual(custom["pinned"] as? Bool, true, "unstarring must not also unpin")

        let parsed = HistoryParsingSupport.customMetadata([
            ["__ccbud__": .object(["pinned": .bool(true)])],
        ])
        XCTAssertTrue(parsed.pinned)
        XCTAssertFalse(parsed.starred)
    }

    func testEditDetectsConcurrentReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try fixture.writeSession(name: "conflict", text: Self.claudeJSONL(id: "conflict"))
        let service = ConversationMutationService(
            configuration: fixture.configuration,
            beforeCommit: { target in
                try? Data(Self.claudeJSONL(id: "other").utf8).write(to: target, options: [.atomic])
            }
        )
        XCTAssertThrowsError(try service.updateMetadata(
            for: fixture.metadata(file: file),
            patch: .init(title: "must not win")
        )) { error in
            XCTAssertEqual(error as? ConversationMutationError, .conflict(file))
        }
        XCTAssertFalse(try String(contentsOf: file).contains("must not win"))
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

    func testLiveForeignUsesSidecarAndCannotBePermanentlyDeleted() throws {
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
        let sidecar = fixture.configuration.appDataRoot.appendingPathComponent("codex-meta.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any]
        let custom = root?["rollout-abc"] as? [String: Any]
        XCTAssertEqual(custom?["title"] as? String, "Codex title")
        XCTAssertEqual(custom?["delete"] as? Bool, true)

        XCTAssertThrowsError(try fixture.service.permanentlyDelete(metadata)) { error in
            XCTAssertEqual(error as? ConversationMutationError, .foreignPermanentDelete)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
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
        try fixture.service.permanentlyDelete(metadata)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: subagents.path))
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

        try fixture.service.updateMetadata(
            for: metadata,
            patch: .init(title: "Edited import", tags: ["local"], deleted: true)
        )
        let trashRepository = HistoryRepository(
            historyDirs: [fixture.historyRoot.path],
            active: "__trash__",
            homeDirectory: fixture.root,
            importsRoot: fixture.configuration.importsRoot
        )
        let trashed = try XCTUnwrap(trashRepository.listSessions().first)
        XCTAssertEqual(trashed.file, imported)
        XCTAssertEqual(trashed.title, "Edited import")
        XCTAssertEqual(trashed.tags, ["local"])
        XCTAssertTrue(trashed.deleted)
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), conflicting)
    }

    /// The metadata record disappears entirely once its last field is cleared, so a caller checking
    /// for a removed key must tolerate there being no record at all.
    private func firstJSONObjectIfPresent(_ file: URL) -> [String: Any]? {
        try? firstJSONObject(file)
    }

    private func firstJSONObject(_ file: URL) throws -> [String: Any] {
        for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") {
            guard let data = line.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data),
                  let object = value as? [String: Any] else { continue }
            return object
        }
        throw ConversationMutationError.noConversationRecords
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
        service = ConversationMutationService(configuration: configuration)
    }

    func writeSession(name: String, text: String) throws -> URL {
        let file = projectDirectory.appendingPathComponent("\(name).jsonl")
        try Data(text.utf8).write(to: file)
        return file
    }

    func repository(active: String = "all") -> HistoryRepository {
        HistoryRepository(historyDirs: configuration.historyDirs, active: active,
            homeDirectory: configuration.homeDirectory, importsRoot: configuration.importsRoot)
    }

    func writeProducerSession(source: HistorySource, id: String) throws -> URL {
        let relativePath: String
        let text: String
        switch source {
        case .claude:
            relativePath = "projects/-tmp-claude/\(id).jsonl"
            text = #"{"type":"user","sessionId":"\#(id)","message":{"role":"user","content":"hello"}}"#
        case .codex:
            relativePath = "sessions/\(id).jsonl"
            text = #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp/test"}}"# + "\n"
                + #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}"#
        case .qoder:
            relativePath = "projects/-tmp-qoder/\(id).jsonl"
            text = #"{"type":"ai-title","sessionId":"\#(id)","aiTitle":"Qoder fixture"}"# + "\n"
                + #"{"type":"user","sessionId":"\#(id)","message":{"role":"user","content":"hello"}}"#
        case .grok:
            relativePath = "sessions/%2Ftmp%2Ftest/\(id)/chat_history.jsonl"
            text = #"{"type":"user","content":"hello"}"#
        case .copilot:
            relativePath = "session-state/\(id)/events.jsonl"
            text = #"{"type":"session.start","data":{"sessionId":"\#(id)"}}"# + "\n"
                + #"{"type":"user.message","data":{"content":"hello"}}"#
        case .antigravity:
            relativePath = "conversations/\(id).db"
            text = ""
        }
        let file = historyRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if source == .antigravity {
            // Producer-owned SQLite fixture: protobuf field 19 contains user field 2, "hello".
            var database: OpaquePointer?
            let status = sqlite3_open(file.path, &database)
            defer { if let database { sqlite3_close(database) } }
            guard status == SQLITE_OK, let database,
                  sqlite3_exec(database, "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_payload BLOB); "
                    + "INSERT INTO steps VALUES (0, X'9A0107120568656C6C6F')", nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "ConversationMutationServiceTests", code: 1)
            }
        } else {
            try Data((text + "\n").utf8).write(to: file)
        }
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
