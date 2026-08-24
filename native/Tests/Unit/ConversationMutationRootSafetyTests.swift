import Foundation
import XCTest
@testable import CCBuddy

final class ConversationMutationRootSafetyTests: XCTestCase {
    func testPermanentDeleteRejectsSymlinkedProjectsRoot() throws {
        let fixture = try RootSafetyFixture(name: "projects-root")
        defer { fixture.cleanup() }
        let externalProjects = fixture.root.appendingPathComponent(
            "external-projects",
            isDirectory: true
        )
        let external = try fixture.createExternalImport(projectsRoot: externalProjects)
        try FileManager.default.createDirectory(
            at: fixture.importsRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.projectsRoot,
            withDestinationURL: externalProjects
        )
        let metadata = fixture.metadata(
            file: fixture.projectsRoot.appendingPathComponent("fixture/session.jsonl")
        )

        XCTAssertTrue(fixture.service.canPermanentlyDelete(metadata))
        XCTAssertThrowsError(try fixture.service.permanentlyDelete(metadata)) { error in
            XCTAssertEqual(
                error as? ConversationMutationError,
                .symbolicLink(fixture.projectsRoot)
            )
        }
        fixture.assertExternalImportExists(external)
    }

    func testPermanentDeleteRejectsSymlinkedImportsRoot() throws {
        let fixture = try RootSafetyFixture(name: "imports-root")
        defer { fixture.cleanup() }
        let externalImports = fixture.root.appendingPathComponent(
            "external-imports",
            isDirectory: true
        )
        let external = try fixture.createExternalImport(
            projectsRoot: externalImports.appendingPathComponent("projects", isDirectory: true)
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.importsRoot,
            withDestinationURL: externalImports
        )
        let metadata = fixture.metadata(
            file: fixture.projectsRoot.appendingPathComponent("fixture/session.jsonl")
        )

        XCTAssertTrue(fixture.service.canPermanentlyDelete(metadata))
        XCTAssertThrowsError(try fixture.service.permanentlyDelete(metadata)) { error in
            XCTAssertEqual(
                error as? ConversationMutationError,
                .symbolicLink(fixture.importsRoot)
            )
        }
        fixture.assertExternalImportExists(external)
    }
}

private final class RootSafetyFixture {
    struct ExternalImport {
        var transcript: URL
        var sidecar: URL
        var subagent: URL
    }

    let root: URL
    let importsRoot: URL
    let projectsRoot: URL
    let service: ConversationMutationService

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "conversation-mutation-root-safety-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        importsRoot = root.appendingPathComponent("app/imports", isDirectory: true)
        projectsRoot = importsRoot.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("app", isDirectory: true),
            withIntermediateDirectories: true
        )
        service = ConversationMutationService(configuration: .init(
            historyDirs: [],
            homeDirectory: root,
            importsRoot: importsRoot
        ))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func createExternalImport(projectsRoot: URL) throws -> ExternalImport {
        let directory = projectsRoot.appendingPathComponent("fixture", isDirectory: true)
        let transcript = directory.appendingPathComponent("session.jsonl")
        let sidecar = directory.appendingPathComponent("session.import.json")
        let subagent = directory.appendingPathComponent(
            "session/subagents/agent.jsonl"
        )
        try FileManager.default.createDirectory(
            at: subagent.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"type":"user","message":{"role":"user","content":"keep"}}"#.utf8)
            .write(to: transcript)
        try Data("{}".utf8).write(to: sidecar)
        try Data("external subagent".utf8).write(to: subagent)
        return ExternalImport(transcript: transcript, sidecar: sidecar, subagent: subagent)
    }

    func metadata(file: URL) -> HistorySessionMetadata {
        HistorySessionMetadata(
            id: "claude:root-safety",
            file: file,
            source: .claude,
            dirID: "__imported__",
            dirLabel: "Imported",
            sessionID: "root-safety",
            project: "fixture",
            title: "Root safety",
            autoTitle: "Root safety",
            imported: true,
            createdAt: Date(timeIntervalSince1970: 1),
            lastActivity: Date(timeIntervalSince1970: 2),
            sizeBytes: 1
        )
    }

    func assertExternalImportExists(
        _ external: ExternalImport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.transcript.path), file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.sidecar.path), file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.subagent.path), file: file, line: line)
    }
}
