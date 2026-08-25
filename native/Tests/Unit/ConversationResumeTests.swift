import XCTest

@testable import CCBuddy

/// The resume dialects are the CLIs' own and are not interchangeable — `claude --resume <id>` and
/// `codex resume <id>` differ in both position and flag form, and Copilot/Antigravity attach the id
/// with `=`. Getting one wrong silently starts a brand-new conversation instead of reopening the
/// one the user was reading, so each form is pinned here.
final class ConversationResumeTests: XCTestCase {
    func testClaudeResumesWithFlagAndRequiresProjectDirectory() throws {
        let dialect = try XCTUnwrap(ConversationResume.dialect(for: .claude, sessionID: "abc-123"))
        XCTAssertEqual(dialect.binary, "claude")
        XCTAssertEqual(dialect.arguments, ["--resume", "abc-123"])
        XCTAssertTrue(dialect.requiresWorkingDirectory)
    }

    func testCodexResumesWithSubcommand() throws {
        let dialect = try XCTUnwrap(ConversationResume.dialect(for: .codex, sessionID: "abc-123"))
        XCTAssertEqual(dialect.binary, "codex")
        XCTAssertEqual(dialect.arguments, ["resume", "abc-123"])
        XCTAssertFalse(dialect.requiresWorkingDirectory)
    }

    func testCopilotAndAntigravityAttachTheIdentifierWithEquals() throws {
        let copilot = try XCTUnwrap(ConversationResume.dialect(for: .copilot, sessionID: "s1"))
        XCTAssertEqual(copilot.arguments, ["--resume=s1"])

        let antigravity = try XCTUnwrap(ConversationResume.dialect(for: .antigravity, sessionID: "s1"))
        XCTAssertEqual(antigravity.binary, "agy")
        XCTAssertEqual(antigravity.arguments, ["--conversation=s1"])
    }

    func testQoderHasNoResumeDialect() {
        // Qoder documents no per-session relaunch flag. Offering the action anyway would start a
        // fresh conversation while claiming to continue the selected one.
        XCTAssertNil(ConversationResume.dialect(for: .qoder, sessionID: "s1"))
        XCTAssertFalse(ConversationResume.isSupported(.qoder))
        XCTAssertTrue(ConversationResume.isSupported(.claude))
    }

    func testCommandChangesDirectoryBeforeInvokingTheAgent() {
        let command = ConversationResume.composeCommand(
            binary: "/opt/homebrew/bin/codex",
            arguments: ["resume", "abc"],
            workingDirectory: "/Users/someone/code/app"
        )
        XCTAssertEqual(
            command,
            "cd '/Users/someone/code/app' && '/opt/homebrew/bin/codex' 'resume' 'abc'"
        )
    }

    func testCommandOmitsDirectoryWhenUnknown() {
        let command = ConversationResume.composeCommand(
            binary: "/usr/local/bin/claude",
            arguments: ["--resume", "abc"],
            workingDirectory: nil
        )
        XCTAssertEqual(command, "'/usr/local/bin/claude' '--resume' 'abc'")
    }

    func testQuotingSurvivesPathsWithSpacesAndApostrophes() {
        // Project directories routinely contain spaces; an apostrophe is the one character that can
        // break out of single quotes, so it must be closed, escaped and reopened.
        let command = ConversationResume.composeCommand(
            binary: "/usr/bin/claude",
            arguments: ["--resume", "id"],
            workingDirectory: "/Users/someone/My Projects/it's here"
        )
        XCTAssertEqual(
            command,
            "cd '/Users/someone/My Projects/it'\\''s here' && '/usr/bin/claude' '--resume' 'id'"
        )
    }

    func testPosixQuoteEscapesEmbeddedSingleQuotes() {
        XCTAssertEqual(ConversationResume.posixQuote("plain"), "'plain'")
        XCTAssertEqual(ConversationResume.posixQuote("a'b"), "'a'\\''b'")
    }

    func testTerminalPreferenceFallsBackToAnInstalledHost() {
        // Terminal.app ships with macOS, so the preference can always resolve to something usable
        // even before the user has picked a host.
        XCTAssertTrue(ConversationResume.installedTerminals.contains(.terminal))
        XCTAssertTrue(
            ConversationResume.installedTerminals.contains(ConversationResume.preferredTerminal)
        )
    }
}
