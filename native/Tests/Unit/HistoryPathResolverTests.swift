import XCTest
@testable import CCBuddy

final class HistoryPathResolverTests: XCTestCase {
    func testTildeExpansionAndClaudeCodexDiscovery() throws {
        let home = try HistoryTestSupport.temporaryDirectory("paths-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let base = home.appendingPathComponent(".assistant", isDirectory: true)
        let claude = base.appendingPathComponent("projects/-tmp-my-project/claude.jsonl")
        let codex = base.appendingPathComponent("sessions/2026/08/22/rollout-codex.jsonl")
        try HistoryTestSupport.write([#"{"type":"user","message":{"role":"user","content":"hello"}}"#], to: claude)
        try HistoryTestSupport.write([#"{"type":"session_meta","payload":{"id":"c"}}"#], to: codex)
        try HistoryTestSupport.write(["{}"], to: claude.deletingLastPathComponent().appendingPathComponent("ignored.txt"))

        let resolver = HistoryPathResolver(configuration: .init(
            historyDirs: ["~/.assistant"],
            homeDirectory: home
        ))
        XCTAssertEqual(
            HistoryPathResolver.expandTilde("~/.assistant", homeDirectory: home).path,
            base.path
        )
        XCTAssertEqual(HistoryPathResolver.decodeProjectDirectoryName("-tmp-my-project"), "/tmp/my/project")

        let files = resolver.discoverSessionFiles()
        XCTAssertEqual(Set(files.map(\.file.lastPathComponent)), ["claude.jsonl", "rollout-codex.jsonl"])
        XCTAssertEqual(files.first(where: { $0.file.lastPathComponent == "claude.jsonl" })?.projectDirectoryName, "-tmp-my-project")
        XCTAssertEqual(
            resolver.watchRoots().map(\.lastPathComponent),
            [
                "projects", "sessions", "archived_sessions", "session-state", "conversations",
                "projects", "sessions", "archived_sessions", "session-state", "conversations",
            ]
        )
    }

    func testTraversalAndSymlinkEscapesAreRejected() throws {
        let root = try HistoryTestSupport.temporaryDirectory("path-safety")
        let outside = try HistoryTestSupport.temporaryDirectory("path-outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let projects = root.appendingPathComponent("projects/-safe")
        let safe = projects.appendingPathComponent("safe.jsonl")
        let external = outside.appendingPathComponent("private.jsonl")
        try HistoryTestSupport.write([#"{"type":"user","message":{"role":"user","content":"safe"}}"#], to: safe)
        try HistoryTestSupport.write([#"{"type":"user","message":{"role":"user","content":"secret"}}"#], to: external)
        let link = projects.appendingPathComponent("escape.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)

        let repository = HistoryRepository(historyDirs: [root.path])
        XCTAssertEqual(repository.listSessions().map(\.file.lastPathComponent), ["safe.jsonl"])
        XCTAssertThrowsError(try repository.getSession(file: external)) { error in
            guard case HistoryError.pathOutsideConfiguredRoots = error else {
                return XCTFail("Expected outside-root rejection, got \(error)")
            }
        }
        XCTAssertThrowsError(try repository.getSession(file: link)) { error in
            guard case HistoryError.notARegularJSONLFile = error else {
                return XCTFail("Expected symlink rejection, got \(error)")
            }
        }
    }
}
