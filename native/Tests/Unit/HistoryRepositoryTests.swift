import XCTest
@testable import CCBuddy

final class HistoryRepositoryTests: XCTestCase {
    func testActiveFilteringMtimeOrderingLimitProjectsAndPathDeduplication() throws {
        let parent = try HistoryTestSupport.temporaryDirectory("repository-list")
        defer { try? FileManager.default.removeItem(at: parent) }
        let firstRoot = parent.appendingPathComponent("one")
        let secondRoot = parent.appendingPathComponent("two")
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = Date(timeIntervalSince1970: 1_800_000_000)
        let otherDate = Date(timeIntervalSince1970: 1_750_000_000)

        let older = firstRoot.appendingPathComponent("projects/-repo-one/older.jsonl")
        let newer = firstRoot.appendingPathComponent("projects/-repo-one/newer.jsonl")
        let other = secondRoot.appendingPathComponent("projects/-repo-two/other.jsonl")
        try HistoryTestSupport.write([
            HistoryTestSupport.claudeLine(type: "user", role: "user", contentJSON: #""older""#, sessionID: "older", cwd: "/repo/one", timestamp: "2026-01-03T00:00:00Z")
        ], to: older, modifiedAt: oldDate)
        try HistoryTestSupport.write([
            HistoryTestSupport.claudeLine(type: "user", role: "user", contentJSON: #""newer""#, sessionID: "newer", cwd: "/repo/one", timestamp: "2025-01-01T00:00:00Z")
        ], to: newer, modifiedAt: newDate)
        try HistoryTestSupport.write([
            HistoryTestSupport.claudeLine(type: "user", role: "user", contentJSON: #""other""#, sessionID: "other", cwd: "/repo/two", timestamp: "2026-02-01T00:00:00Z")
        ], to: other, modifiedAt: otherDate)

        let active = HistoryRepository(
            historyDirs: [firstRoot.path, secondRoot.path],
            active: firstRoot.path,
            homeDirectory: parent
        )
        XCTAssertEqual(active.listSessions().map(\.sessionID), ["newer", "older"], "mtime, not record timestamp, is the phase-one ordering key")
        XCTAssertEqual(active.listSessions(limit: 1).map(\.sessionID), ["newer"])

        let all = HistoryRepository(
            historyDirs: [firstRoot.path, firstRoot.path, secondRoot.path],
            homeDirectory: parent
        )
        XCTAssertEqual(all.listSessions().map(\.sessionID), ["newer", "other", "older"])
        XCTAssertEqual(all.listProjects().map(\.cwd), ["/repo/one", "/repo/two"])
        XCTAssertEqual(all.listProjects().first?.sessions.count, 2)
    }

    func testCanonicalCodexDuplicatesCollapseWithinDirectory() throws {
        let root = try HistoryTestSupport.temporaryDirectory("repository-dedupe")
        defer { try? FileManager.default.removeItem(at: root) }
        let threadID = "511a7eed-4f83-46ba-afff-4e08b18c12f5"
        let older = root.appendingPathComponent("sessions/2026/08/21/rollout-old.jsonl")
        let newer = root.appendingPathComponent("sessions/2026/08/22/rollout-\(threadID).jsonl")
        let metadata = #"{"id":"\#(threadID)","session_id":"\#(threadID)","cwd":"/dedupe"}"#
        try HistoryTestSupport.write([
            HistoryTestSupport.codexLine(timestamp: "2026-08-21T00:00:00Z", type: "session_meta", payload: metadata),
            HistoryTestSupport.codexLine(timestamp: "2026-08-21T00:00:01Z", type: "response_item", payload: #"{"type":"message","role":"user","content":[{"type":"input_text","text":"old duplicate"}]}"#),
        ], to: older, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try HistoryTestSupport.write([
            HistoryTestSupport.codexLine(timestamp: "2026-08-22T00:00:00Z", type: "session_meta", payload: metadata),
            HistoryTestSupport.codexLine(timestamp: "2026-08-22T00:00:01Z", type: "response_item", payload: #"{"type":"message","role":"user","content":[{"type":"input_text","text":"new duplicate"}]}"#),
        ], to: newer, modifiedAt: Date(timeIntervalSince1970: 1_800_000_000))

        let rows = HistoryRepository(
            historyDirs: [root.path], homeDirectory: root
        ).listSessions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].file, newer.resolvingSymlinksInPath().standardizedFileURL)
        XCTAssertEqual(rows[0].title, "new duplicate")
    }

    func testDirectoryStatisticsCountLogicalSessionsAndRecognizeNonClaudeTrees() throws {
        let parent = try HistoryTestSupport.temporaryDirectory("repository-directory-statistics")
        defer { try? FileManager.default.removeItem(at: parent) }
        let claudeRoot = parent.appendingPathComponent("claude")
        let codexRoot = parent.appendingPathComponent("codex")
        let missingRoot = parent.appendingPathComponent("missing")
        let claude = claudeRoot.appendingPathComponent("projects/-stats/claude.jsonl")
        try HistoryTestSupport.write([
            HistoryTestSupport.claudeLine(
                type: "user",
                role: "user",
                contentJSON: #""stats""#,
                sessionID: "stats-claude",
                cwd: "/stats",
                timestamp: "2026-08-22T00:00:00Z"
            ),
        ], to: claude)

        let threadID = "611a7eed-4f83-46ba-afff-4e08b18c12f5"
        let codex = codexRoot.appendingPathComponent("sessions/2026/08/22/rollout-\(threadID).jsonl")
        try HistoryTestSupport.write([
            HistoryTestSupport.codexLine(
                timestamp: "2026-08-22T00:00:00Z",
                type: "session_meta",
                payload: #"{"id":"\#(threadID)","session_id":"\#(threadID)","cwd":"/stats"}"#
            ),
        ], to: codex)

        let statistics = HistoryRepository(
            historyDirs: [claudeRoot.path, codexRoot.path, missingRoot.path],
            homeDirectory: parent
        ).directoryStatistics()
        let byID = Dictionary(uniqueKeysWithValues: statistics.map { ($0.id, $0) })

        XCTAssertEqual(byID[claudeRoot.path]?.sessionCount, 1)
        XCTAssertEqual(byID[claudeRoot.path]?.exists, true)
        XCTAssertEqual(byID[codexRoot.path]?.sessionCount, 1)
        XCTAssertEqual(byID[codexRoot.path]?.exists, true)
        XCTAssertEqual(byID[missingRoot.path]?.sessionCount, 0)
        XCTAssertEqual(byID[missingRoot.path]?.exists, false)
    }

    func testProjectsKeepCodexTreesTogetherInRootChildDepthFirstOrder() throws {
        let home = try HistoryTestSupport.temporaryDirectory("repository-codex-tree-order")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".codex")
        let rootID = "11111111-1111-4111-8111-111111111111"
        let childID = "22222222-2222-4222-8222-222222222222"
        let grandchildID = "33333333-3333-4333-8333-333333333333"
        let siblingID = "44444444-4444-4444-8444-444444444444"
        let otherRootID = "55555555-5555-4555-8555-555555555555"

        func write(
            _ id: String,
            rootID: String,
            parentID: String? = nil,
            depth: Int? = nil,
            activity: TimeInterval
        ) throws {
            var fields = [
                #""id":"\#(id)""#,
                #""session_id":"\#(rootID)""#,
                #""cwd":"/tree""#,
            ]
            if let parentID { fields.append(#""parent_thread_id":"\#(parentID)""#) }
            if let depth { fields.append(#""agent_depth":\#(depth)"#) }
            if parentID != nil { fields.append(#""thread_source":"subagent""#) }
            let file = root.appendingPathComponent("sessions/2026/08/22/rollout-\(id).jsonl")
            try HistoryTestSupport.write([
                HistoryTestSupport.codexLine(
                    timestamp: "2026-08-22T00:00:00Z",
                    type: "session_meta",
                    payload: "{\(fields.joined(separator: ","))}"
                ),
            ], to: file, modifiedAt: Date(timeIntervalSince1970: activity))
        }

        // Global activity order starts with the child and interleaves the other root. The final
        // project rows should instead show the active tree as one navigable root-first unit.
        try write(rootID, rootID: rootID, activity: 100)
        try write(childID, rootID: rootID, parentID: rootID, depth: 1, activity: 500)
        try write(grandchildID, rootID: rootID, parentID: childID, depth: 2, activity: 300)
        try write(siblingID, rootID: rootID, parentID: rootID, depth: 1, activity: 400)
        try write(otherRootID, rootID: otherRootID, activity: 450)

        let repository = HistoryRepository(
            historyDirs: [root.path],
            homeDirectory: home,
            importsRoot: home.appendingPathComponent("app/imports")
        )
        XCTAssertEqual(repository.listSessions().compactMap(\.threadID), [
            childID, otherRootID, siblingID, grandchildID, rootID,
        ])
        XCTAssertEqual(repository.listProjects().first?.sessions.compactMap(\.threadID), [
            rootID, childID, grandchildID, siblingID, otherRootID,
        ])
    }

    func testSearchFindsClaudeCodexAndToolContentButNotInjectedText() throws {
        let root = try HistoryTestSupport.temporaryDirectory("repository-search")
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("projects/-search/claude.jsonl")
        try HistoryTestSupport.write([
            HistoryTestSupport.claudeLine(type: "user", role: "user", contentJSON: #""Find the Zebra<system-reminder>private-needle</system-reminder>""#, sessionID: "claude", cwd: "/search", timestamp: "2026-08-20T00:00:00Z"),
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Read","input":{"file_path":"kangaroo.swift"}}]},"sessionId":"claude","cwd":"/search","timestamp":"2026-08-20T00:00:01Z"}"#,
        ], to: claude, modifiedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let codex = root.appendingPathComponent("sessions/2026/08/22/codex.jsonl")
        try HistoryTestSupport.write([
            HistoryTestSupport.codexLine(timestamp: "2026-08-22T00:00:00Z", type: "session_meta", payload: #"{"id":"c1","cwd":"/search"}"#),
            HistoryTestSupport.codexLine(timestamp: "2026-08-22T00:00:01Z", type: "response_item", payload: #"{"type":"message","role":"user","content":[{"type":"input_text","text":"codex quokka request"}]}"#),
        ], to: codex, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let repository = HistoryRepository(historyDirs: [root.path], homeDirectory: root)
        XCTAssertEqual(repository.search(query: "zEbRa").map(\.sessionID), ["claude"])
        XCTAssertEqual(repository.search(query: "kangaroo").map(\.sessionID), ["claude"])
        XCTAssertEqual(repository.search(query: "QUOKKA").map(\.sessionID), ["c1"])
        XCTAssertTrue(repository.search(query: "private-needle").isEmpty)
        XCTAssertEqual(repository.search(query: "zebra").first?.count, 1)
    }
}
