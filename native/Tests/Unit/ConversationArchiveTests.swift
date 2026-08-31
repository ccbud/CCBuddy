import Darwin
import XCTest
@testable import CCBuddy

final class ConversationArchiveTests: XCTestCase {
    func testBundleRoundTripKeepsMainAndSubagents() throws {
        let entries = [
            ConversationArchiveEntry(name: "wrapper/session.jsonl", data: Data("main\n".utf8)),
            ConversationArchiveEntry(
                name: "wrapper/subagents/agent-a.jsonl",
                data: Data("agent\n".utf8)
            ),
            ConversationArchiveEntry(
                name: "wrapper/subagents/agent-a.meta.json",
                data: Data(#"{"toolUseId":"tool-a"}"#.utf8)
            ),
        ]

        let archive = try ConversationArchive.build(entries: entries)
        let decoded = try ConversationArchive.read(archive)
        XCTAssertEqual(decoded, entries)

        let bundle = try ConversationArchive.splitBundle(decoded)
        XCTAssertEqual(bundle.main.name, "wrapper/session.jsonl")
        XCTAssertEqual(bundle.subagents.map(\.name), ["agent-a.jsonl", "agent-a.meta.json"])
    }

    func testRejectsTraversalEvenWhenLocalAndCentralNamesAgree() throws {
        var archive = try ConversationArchive.build(entries: [
            .init(name: "aaa/evilx", data: Data("x".utf8)),
        ])
        replaceASCII("aaa/evilx", with: "../evil.x", in: &archive)
        XCTAssertThrowsError(try ConversationArchive.read(archive)) { error in
            XCTAssertEqual(error as? ConversationArchiveError, .unsafePath("../evil.x"))
        }
    }

    func testRejectsUnixSymlinkEntry() throws {
        var archive = try ConversationArchive.build(entries: [
            .init(name: "agent.jsonl", data: Data("x".utf8)),
        ])
        let central = try XCTUnwrap(findSignature(0x0201_4b50, in: archive))
        archive.setU32(UInt32(S_IFLNK | 0o777) << 16, at: central + 38)
        XCTAssertThrowsError(try ConversationArchive.read(archive)) { error in
            XCTAssertEqual(error as? ConversationArchiveError, .symbolicLink("agent.jsonl"))
        }
    }

    func testRejectsOversizedDeclarationBeforeExtraction() throws {
        var archive = try ConversationArchive.build(entries: [
            .init(name: "session.jsonl", data: Data("x".utf8)),
        ])
        let local = try XCTUnwrap(findSignature(0x0403_4b50, in: archive))
        let central = try XCTUnwrap(findSignature(0x0201_4b50, in: archive))
        archive.setU32(1_000, at: local + 22)
        archive.setU32(1_000, at: central + 24)
        var limits = ConversationArchiveLimits()
        limits.maximumEntryBytes = 100
        XCTAssertThrowsError(try ConversationArchive.read(archive, limits: limits)) { error in
            XCTAssertEqual(error as? ConversationArchiveError, .entryTooLarge("session.jsonl"))
        }
    }

    func testRejectsCRCFailure() throws {
        var archive = try ConversationArchive.build(entries: [
            .init(name: "session.jsonl", data: Data("payload".utf8)),
        ])
        let local = try XCTUnwrap(findSignature(0x0403_4b50, in: archive))
        let payload = local + 30 + Int(archive.u16(at: local + 26))
            + Int(archive.u16(at: local + 28))
        archive[payload] ^= 0xff
        XCTAssertThrowsError(try ConversationArchive.read(archive)) { error in
            XCTAssertEqual(error as? ConversationArchiveError, .corruptEntry("session.jsonl"))
        }
    }

    func testAcceptsAndOmitsExplicitWrappingDirectoryEntries() throws {
        var archive = try ConversationArchive.build(entries: [
            .init(name: "wrapperX", data: Data()),
            .init(name: "wrapper/session.jsonl", data: Data("main\n".utf8)),
        ])
        // Keep both ZIP header lengths stable while turning the empty STORE file into the
        // explicit directory record emitted by common ZIP tools.
        replaceASCII("wrapperX", with: "wrapper/", in: &archive)
        let decoded = try ConversationArchive.read(archive)
        XCTAssertEqual(decoded, [
            .init(name: "wrapper/session.jsonl", data: Data("main\n".utf8)),
        ])
        XCTAssertEqual(try ConversationArchive.splitBundle(decoded).main.name, "wrapper/session.jsonl")
    }

    private func replaceASCII(_ old: String, with new: String, in data: inout Data) {
        XCTAssertEqual(old.utf8.count, new.utf8.count)
        let needle = Data(old.utf8)
        let replacement = Data(new.utf8)
        var cursor = data.startIndex
        while cursor < data.endIndex,
              let range = data.range(of: needle, in: cursor..<data.endIndex) {
            data.replaceSubrange(range, with: replacement)
            cursor = range.lowerBound + replacement.count
        }
    }

    private func findSignature(_ signature: UInt32, in data: Data) -> Int? {
        let bytes = Data([
            UInt8(truncatingIfNeeded: signature),
            UInt8(truncatingIfNeeded: signature >> 8),
            UInt8(truncatingIfNeeded: signature >> 16),
            UInt8(truncatingIfNeeded: signature >> 24),
        ])
        return data.range(of: bytes)?.lowerBound
    }
}

private extension Data {
    func u16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    mutating func setU32(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
