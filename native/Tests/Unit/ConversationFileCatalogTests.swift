import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import CCBuddy

final class ConversationFileCatalogTests: XCTestCase {
    func testCompressedFilesRoundTripAllMetadataDocumentsAndUTF16Anchors() throws {
        let fixture = try Fixture()
        let text = String(repeating: "系统代理 e\u{301}👩‍💻 Straße\n", count: 9_000)
        var input = makeSession(fixture, id: "complete", text: text)
        input.metadata.tags = ["中文", "tag"]
        input.metadata.starred = true
        input.metadata.pinned = true
        input.metadata.threadID = "thread"
        input.metadata.parentThreadID = "parent"
        input.metadata.forkedFromID = "fork"
        input.metadata.canonicalThreadIDValid = true
        input.metadata.summary = .object(["nested": .array([.number(2), .bool(true)])])
        input.metadata.diagnostics = .init(decodedLines: 19, malformedLines: 1)
        input.fingerprint.dependencyFingerprint = "stable-sidecars"
        input.documents.append(.init(transcriptID: "child", agentType: "Explore", sortOrder: 1,
            text: "subagent 当前版本", messageSpans: [.init(sequence: 0, messageIndex: 0,
                utf16Location: 0, utf16Length: 15, role: "assistant")]))
        // Use the exact computed UTF-16 size, rather than depending on scalar width.
        input.documents[1].messageSpans[0].utf16Length = input.documents[1].text.utf16.count
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        XCTAssertEqual(try catalog.replace(input), 1)
        XCTAssertEqual(try catalog.documents(for: input.metadata.file), input.documents)
        let reopened = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        XCTAssertEqual(try reopened.loadAllMetadata(), [input.metadata])
        XCTAssertEqual(try reopened.documents(for: input.metadata.file), input.documents)
        XCTAssertEqual(try reopened.storedFingerprints(), [input.metadata.file.path: input.fingerprint])
        XCTAssertEqual(try reopened.generation(), 1)
        let files = try FileManager.default.contentsOfDirectory(at: fixture.objects,
            includingPropertiesForKeys: nil)
        let packs = files.filter { $0.pathExtension == "pack" }
        XCTAssertEqual(packs.count, 1)
        let bytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: packs[0].path)[.size] as? NSNumber)
        XCTAssertLessThan(bytes.intValue, text.utf8.count / 4)
        XCTAssertFalse(files.contains { $0.pathExtension == "sqlite3" || $0.pathExtension == "sqlite" })
        for directory in [fixture.catalog, fixture.objects] {
            XCTAssertEqual(try permissions(directory), 0o700)
        }
        for file in files + [fixture.catalog.appendingPathComponent("manifest.json"),
                             fixture.catalog.appendingPathComponent(".catalog.lock")] {
            XCTAssertEqual(try permissions(file), 0o600)
        }
    }

    func testMetadataOnlyBatchRetainsPacksIDsAndContentTokens() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        var input = makeSession(fixture, id: "one", text: "stable transcript")
        try catalog.replace(input)
        let before = try catalog.catalogSearchSnapshot(deleted: nil)
        let packNames = try objectNames(fixture).filter { $0.hasSuffix(".pack") }
        input.metadata.title = "renamed"
        input.metadata.starred = true
        input.metadata.tags = ["retained"]
        input.documents = []
        input.fingerprint = .init(modificationTime: .distantPast, sizeBytes: 0)
        XCTAssertEqual(try catalog.replaceMetadata([input]), 2)
        let after = try catalog.catalogSearchSnapshot(deleted: nil)
        XCTAssertEqual(after.documents.map(\.contentToken), before.documents.map(\.contentToken))
        XCTAssertEqual(after.documents.map(\.chunkIDs), before.documents.map(\.chunkIDs))
        XCTAssertEqual(try objectNames(fixture).filter { $0.hasSuffix(".pack") }, packNames)
        XCTAssertEqual(try catalog.documents(for: input.metadata.file).first?.text, "stable transcript")
        XCTAssertEqual(try catalog.loadAllMetadata(), [input.metadata])
    }

#if DEBUG
    func testMetadataCASRetriesEntireBatchAndKeepsConcurrentReplacementContent() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let writer = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let original = makeSession(fixture, id: "one", text: "old body")
        let companion = makeSession(fixture, id: "two", text: "unchanged companion")
        try catalog.replace(original)
        try catalog.replace(companion)
        var update = original
        update.metadata.title = "metadata wins, latest body retained"
        update.documents = []
        var companionUpdate = companion
        companionUpdate.metadata.title = "atomic companion title"
        companionUpdate.documents = []
        let concurrent = makeSession(fixture, id: "one", text: "new concurrent body 👩‍💻")
        let calls = LockedValue(0)
        let latestContent = LockedValue<ConversationFileCatalog.SearchDocument?>(nil)
        catalog.metadataPreparationDidFinishForTesting = {
            let call = calls.modify { $0 += 1; return $0 }
            if call == 1 {
                // This also proves preparation released this instance's state lock.
                XCTAssertEqual(try catalog.generation(), 2)
                try writer.replace(concurrent)
                let replacement = try writer.catalogSearchSnapshot().documents.first {
                    $0.reference.sessionPath == original.metadata.file.path
                }
                latestContent.modify { $0 = replacement }
            }
            XCTAssertEqual(try writer.entry(for: companion.metadata.file)?.metadata.title,
                companion.metadata.title, "A failed CAS must not publish part of the batch")
        }
        XCTAssertEqual(try catalog.replaceMetadata([update, companionUpdate]), 4)
        XCTAssertEqual(calls.value, 2)
        let retained = try XCTUnwrap(catalog.catalogSearchSnapshot().documents.first {
            $0.reference.sessionPath == original.metadata.file.path
        })
        let expected = try XCTUnwrap(latestContent.value)
        XCTAssertEqual(retained.contentToken, expected.contentToken)
        XCTAssertEqual(retained.reference.documentID, expected.reference.documentID)
        XCTAssertEqual(retained.chunkIDs, expected.chunkIDs)
        XCTAssertEqual(try catalog.documents(for: original.metadata.file), concurrent.documents)
        XCTAssertEqual(try catalog.entry(for: original.metadata.file)?.metadata.title, update.metadata.title)
        XCTAssertEqual(try catalog.entry(for: companion.metadata.file)?.metadata.title,
            companionUpdate.metadata.title)
        XCTAssertFalse(try objectNames(fixture).contains { $0.hasSuffix(".partial") })
    }

    func testMetadataCASIgnoresUnrelatedGenerationChangeAndKeepsLastDuplicate() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let writer = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let original = makeSession(fixture, id: "one", text: "stable body")
        let unrelated = makeSession(fixture, id: "unrelated", text: "independent body")
        try catalog.replace(original)
        var update = original
        update.metadata.title = "last duplicate wins"
        update.documents = []
        let calls = LockedValue(0)
        catalog.metadataPreparationDidFinishForTesting = {
            if calls.modify({ $0 += 1; return $0 }) == 1 { try writer.replace(unrelated) }
        }
        XCTAssertEqual(try catalog.replaceMetadata([original, update]), 3)
        XCTAssertEqual(calls.value, 1, "Unrelated writes must not waste a prepared large header")
        XCTAssertEqual(try catalog.entry(for: original.metadata.file)?.metadata.title, update.metadata.title)
        XCTAssertEqual(try catalog.documents(for: unrelated.metadata.file), unrelated.documents)
        XCTAssertEqual(try catalog.documents(for: original.metadata.file), original.documents)
    }

    func testMetadataCASRejectsChangedCatalogIdentityEvenWithSameObjectsAndGeneration() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        var update = makeSession(fixture, id: "one", text: "retained body")
        try catalog.replace(update)
        let oldIdentity = try catalog.catalogIdentity()
        update.metadata.title = "new title"
        update.documents = []
        let calls = LockedValue(0)
        catalog.metadataPreparationDidFinishForTesting = {
            guard calls.modify({ $0 += 1; return $0 }) == 1 else { return }
            let manifest = fixture.catalog.appendingPathComponent("manifest.json")
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with:
                Data(contentsOf: manifest)) as? [String: Any])
            object["identity"] = UUID().uuidString.lowercased()
            object.removeValue(forKey: "checksum")
            let canonical = try JSONSerialization.data(withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes])
            object["checksum"] = Data(SHA256.hash(data: canonical)).base64EncodedString()
            try JSONSerialization.data(withJSONObject: object).write(to: manifest)
        }
        XCTAssertEqual(try catalog.replaceMetadata([update]), 2)
        XCTAssertEqual(calls.value, 2)
        XCTAssertNotEqual(try catalog.catalogIdentity(), oldIdentity)
        XCTAssertEqual(try catalog.documents(for: update.metadata.file).first?.text, "retained body")
        XCTAssertFalse(try objectNames(fixture).contains { $0.hasSuffix(".partial") })
    }

    func testMetadataCASCannotRestoreRemovedContentFromStaleSnapshot() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let writer = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        var update = makeSession(fixture, id: "one", text: "removed body")
        try catalog.replace(update)
        let file = update.metadata.file
        update.metadata.title = "metadata after removal"
        update.documents = []
        let calls = LockedValue(0)
        catalog.metadataPreparationDidFinishForTesting = {
            if calls.modify({ $0 += 1; return $0 }) == 1 {
                XCTAssertEqual(try writer.remove(files: [file]), 1)
                try writer.finishFullScanMaintenance()
            }
        }
        XCTAssertEqual(try catalog.replaceMetadata([update]), 3)
        XCTAssertEqual(calls.value, 2)
        XCTAssertTrue(try catalog.documents(for: file).isEmpty)
        XCTAssertTrue(try catalog.catalogSearchSnapshot().documents.isEmpty)
        XCTAssertEqual(try catalog.entry(for: file)?.metadata.title, update.metadata.title)
    }

    func testMetadataCancellationAfterPreparationCleansOnlyOwnPartialsAndPublishesNothing() async throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let original = makeSession(fixture, id: "one", text: "stable body")
        try catalog.replace(original)
        var update = original
        update.metadata.title = "cancelled title"
        update.documents = []
        let insertion = makeSession(fixture, id: "new", text: "must not appear")
        let manifest = fixture.catalog.appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: manifest)
        let foreignPartial = fixture.objects.appendingPathComponent(".\(UUID().uuidString.lowercased()).partial")
        try Data("unrelated writer bytes".utf8).write(to: foreignPartial)
        let objectsBefore = try objectNames(fixture)
        let prepared = expectation(description: "durable batch prepared")
        let resume = DispatchSemaphore(value: 0)
        catalog.metadataPreparationDidFinishForTesting = {
            prepared.fulfill()
            guard resume.wait(timeout: .now() + 5) == .success else {
                throw NSError(domain: "metadata-test-resume-timeout", code: 1)
            }
            try Task.checkCancellation()
        }
        let inputs = [update, insertion]
        let task = Task.detached { try catalog.replaceMetadata(inputs) }
        await fulfillment(of: [prepared], timeout: 3)
        task.cancel()
        resume.signal()
        do { _ = try await task.value; XCTFail("Cancelled batch was published") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(try Data(contentsOf: manifest), before)
        XCTAssertEqual(try objectNames(fixture), objectsBefore)
        XCTAssertEqual(try catalog.loadAllMetadata(), [original.metadata])
        XCTAssertEqual(try catalog.documents(for: original.metadata.file), original.documents)
        XCTAssertEqual(try String(contentsOf: foreignPartial), "unrelated writer bytes")
    }

    func testMetadataPreparationFailureCannotPublishPartOfBatchOrRetry() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let original = makeSession(fixture, id: "one", text: "stable body")
        try catalog.replace(original)
        var update = original
        update.metadata.title = "must not publish"
        let insertion = makeSession(fixture, id: "new", text: "must not appear")
        let manifest = fixture.catalog.appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: manifest)
        let objectsBefore = try objectNames(fixture)
        let calls = LockedValue(0)
        catalog.metadataPreparationDidFinishForTesting = {
            calls.modify { $0 += 1 }
            throw POSIXError(.ENOSPC)
        }
        XCTAssertThrowsError(try catalog.replaceMetadata([update, insertion])) {
            XCTAssertEqual(($0 as? POSIXError)?.code, .ENOSPC)
        }
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(try Data(contentsOf: manifest), before)
        XCTAssertEqual(try objectNames(fixture), objectsBefore)
        XCTAssertEqual(try catalog.loadAllMetadata(), [original.metadata])
    }

    func testMetadataPreparedHeadersSurviveConcurrentGCWithLifetimeLeases() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let collector = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        var first = makeSession(fixture, id: "one", text: "first retained body")
        var second = makeSession(fixture, id: "two", text: "second retained body")
        try catalog.replace(first)
        try catalog.replace(second)
        first.metadata.pinned = true
        second.metadata.starred = true
        first.documents = []
        second.documents = []
        let packs = try objectNames(fixture).filter { $0.hasSuffix(".pack") }
        catalog.metadataPreparationDidFinishForTesting = {
            let partials = try FileManager.default.contentsOfDirectory(atPath: fixture.objects.path)
                .filter { $0.hasSuffix(".partial") }
            XCTAssertEqual(partials.count, 2)
            for partial in partials {
                let file = fixture.objects.appendingPathComponent(partial)
                XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: file)))
                let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                XCTAssertGreaterThanOrEqual(descriptor, 0)
                if descriptor >= 0 {
                    XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), -1)
                    XCTAssertEqual(errno, EWOULDBLOCK)
                    close(descriptor)
                }
            }
            try collector.finishFullScanMaintenance()
            let retained = try FileManager.default.contentsOfDirectory(atPath: fixture.objects.path)
            XCTAssertTrue(partials.allSatisfy { retained.contains($0) })
            XCTAssertEqual(try catalog.generation(), 2)
        }
        XCTAssertEqual(try catalog.replaceMetadata([first, second]), 3)
        try collector.finishFullScanMaintenance()
        let after = try objectNames(fixture)
        XCTAssertEqual(after.filter { $0.hasSuffix(".pack") }, packs)
        XCTAssertEqual(after.filter { $0.hasSuffix(".header") }.count, 2)
        XCTAssertFalse(after.contains { $0.hasSuffix(".partial") })
        XCTAssertEqual(try catalog.documents(for: first.metadata.file).first?.text, "first retained body")
        XCTAssertEqual(try catalog.documents(for: second.metadata.file).first?.text, "second retained body")
    }
#endif

    func testInvalidReplacementCannotPublishPartialMetadataOrText() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let original = makeSession(fixture, id: "one", text: "old body")
        try catalog.replace(original)
        let manifest = try Data(contentsOf: fixture.catalog.appendingPathComponent("manifest.json"))
        var invalid = original
        invalid.metadata.title = "must not publish"
        invalid.documents.append(invalid.documents[0])
        XCTAssertThrowsError(try catalog.replace(invalid))
        XCTAssertEqual(try catalog.generation(), 1)
        XCTAssertEqual(try catalog.loadAllMetadata(), [original.metadata])
        XCTAssertEqual(try catalog.documents(for: original.metadata.file), original.documents)
        XCTAssertEqual(try Data(contentsOf: fixture.catalog.appendingPathComponent("manifest.json")), manifest)
    }

    func testIndependentInstancesMergeWritesAndNeverReuseRemovedIDs() throws {
        let fixture = try Fixture()
        let first = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let second = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let a = makeSession(fixture, id: "a", text: "alpha")
        let b = makeSession(fixture, id: "b", text: "beta")
        try first.replace(a)
        let old = try XCTUnwrap(first.catalogSearchSnapshot().documents.first)
        try second.replace(b)
        XCTAssertEqual(Set(try first.loadAllMetadata().map(\.sessionID)), ["a", "b"])
        XCTAssertEqual(try first.remove(files: [a.metadata.file]), 1)
        try second.replace(a)
        let replacement = try XCTUnwrap(first.catalogSearchSnapshot().documents.first {
            $0.reference.sessionPath == a.metadata.file.path
        })
        XCTAssertGreaterThan(replacement.reference.documentID, old.reference.documentID)
        XCTAssertGreaterThan(try XCTUnwrap(replacement.chunkIDs.first), try XCTUnwrap(old.chunkIDs.last))
        XCTAssertNotEqual(replacement.contentToken, old.contentToken)
        XCTAssertEqual(try second.generation(), 4)
    }

    func testConcurrentOpenAndWritesDoNotLoseSessions() throws {
        let fixture = try Fixture()
        let inputs = (0..<12).map { makeSession(fixture, id: "session-\($0)", text: "body \($0)") }
        let errors = Errors()
        DispatchQueue.concurrentPerform(iterations: inputs.count) { index in
            do {
                let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
                try catalog.replace(inputs[index])
            } catch { errors.append(error) }
        }
        XCTAssertTrue(errors.values.isEmpty, "\(errors.values)")
        let reopened = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        XCTAssertEqual(try reopened.loadAllMetadata().count, inputs.count)
        XCTAssertEqual(try reopened.generation(), Int64(inputs.count))
        let documents = try reopened.catalogSearchSnapshot().documents
        XCTAssertEqual(Set(documents.map(\.reference.documentID)).count, inputs.count)
        XCTAssertEqual(Set(documents.flatMap(\.chunkIDs)).count, inputs.count)
    }

    func testConcurrentFirstOpenStressKeepsAllCommittedWrites() throws {
        for round in 0..<16 {
            let fixture = try Fixture()
            let inputs = (0..<8).map { makeSession(fixture, id: "session-\($0)", text: "round \(round)") }
            let errors = Errors()
            DispatchQueue.concurrentPerform(iterations: inputs.count) { index in
                do {
                    let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
                    try catalog.replace(inputs[index])
                } catch { errors.append(error) }
            }
            XCTAssertTrue(errors.values.isEmpty, "Round \(round): \(errors.values)")
            let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
            XCTAssertEqual(try catalog.loadAllMetadata().count, inputs.count, "Round \(round)")
            XCTAssertEqual(try catalog.generation(), Int64(inputs.count), "Round \(round)")
        }
    }

    func testFailedInitializersCannotCloseConcurrentCatalogFileDescriptors() throws {
        let valid = try Fixture()
        let invalid = try Fixture()
        _ = try ConversationFileCatalog(file: invalid.catalog, enableTgrep: false)
        try Data("corrupt manifest".utf8).write(to: invalid.catalog.appendingPathComponent("manifest.json"))
        let inputs = (0..<24).map { makeSession(valid, id: "session-\($0)", text: "survives failed open") }
        let errors = Errors()
        DispatchQueue.concurrentPerform(iterations: inputs.count * 2) { index in
            if index.isMultiple(of: 2) {
                for _ in 0..<8 {
                    do {
                        _ = try ConversationFileCatalog(file: invalid.catalog, enableTgrep: false)
                        errors.append(NSError(domain: "invalid-catalog-opened", code: 1))
                    } catch { /* expected; descriptor ownership must still be exact */ }
                }
            } else {
                do {
                    let catalog = try ConversationFileCatalog(file: valid.catalog, enableTgrep: false)
                    try catalog.replace(inputs[index / 2])
                    XCTAssertNotNil(try catalog.entry(for: inputs[index / 2].metadata.file))
                } catch { errors.append(error) }
            }
        }
        XCTAssertTrue(errors.values.isEmpty, "\(errors.values)")
        let reopened = try ConversationFileCatalog(file: valid.catalog, enableTgrep: false)
        XCTAssertEqual(try reopened.loadAllMetadata().count, inputs.count)
        XCTAssertEqual(try reopened.generation(), Int64(inputs.count))
    }

    func testScopedReconciliationRequiresExplicitEmptyAndKeepsOtherScopes() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        var a = makeSession(fixture, id: "a", text: "alpha")
        a.scope = "a"
        var b = makeSession(fixture, id: "b", text: "beta")
        b.scope = "b"
        try catalog.replace(a)
        try catalog.replace(b)
        XCTAssertThrowsError(try catalog.reconcile(scope: "a", seenPaths: []))
        XCTAssertEqual(try catalog.reconcile(scope: "a", seenPaths: [], allowEmpty: true).removedPaths,
            [a.metadata.file.path])
        XCTAssertEqual(try catalog.loadAllMetadata(), [b.metadata])
        XCTAssertEqual(try catalog.scopeSummaries().map(\.scope), ["b"])
    }

    func testFutureManifestIsRejectedWithoutChangingItsBytes() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        try catalog.replace(makeSession(fixture, id: "old", text: "retained"))
        let manifest = fixture.catalog.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        object["version"] = 999
        let bytes = try JSONSerialization.data(withJSONObject: object)
        try bytes.write(to: manifest)
        XCTAssertThrowsError(try ConversationFileCatalog(file: fixture.catalog))
        XCTAssertEqual(try Data(contentsOf: manifest), bytes)
    }

    func testCorruptRootManifestIsNotReplacedWithAnEmptyCatalog() throws {
        let fixture = try Fixture()
        _ = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let manifest = fixture.catalog.appendingPathComponent("manifest.json")
        let bytes = Data("not a catalog".utf8)
        try bytes.write(to: manifest)
        XCTAssertThrowsError(try ConversationFileCatalog(file: fixture.catalog))
        XCTAssertEqual(try Data(contentsOf: manifest), bytes)
    }

    func testValidJSONCounterCorruptionCannotReuseIDsOrOverwritePublishedManifest() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        try catalog.replace(makeSession(fixture, id: "one", text: "body"))
        let manifest = fixture.catalog.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        object["nextChunkID"] = 1
        let bytes = try JSONSerialization.data(withJSONObject: object)
        try bytes.write(to: manifest)
        XCTAssertThrowsError(try catalog.replace(makeSession(fixture, id: "two", text: "new")))
        XCTAssertThrowsError(try ConversationFileCatalog(file: fixture.catalog))
        XCTAssertEqual(try Data(contentsOf: manifest), bytes)
    }

    func testCorruptNewestHeaderIsReportedAndDoesNotConsumeVisibleLimit() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let good = makeSession(fixture, id: "good", text: "valid")
        var bad = makeSession(fixture, id: "bad", text: "broken")
        bad.metadata.lastActivity = good.metadata.lastActivity.addingTimeInterval(100)
        try catalog.replace(good)
        try catalog.replace(bad)
        let header = try headerURL(fixture, source: bad.metadata.file)
        try Data("damaged header".utf8).write(to: header)
        let reopened = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        XCTAssertEqual(try reopened.listEntries(limit: 1).map(\.metadata.sessionID), ["good"])
        XCTAssertNil(try reopened.entry(for: bad.metadata.file))
        XCTAssertEqual(reopened.catalogCorruptRecordCount, 1)
        XCTAssertEqual(try reopened.catalogSearchSnapshot().documents.count, 1)
        try reopened.replace(bad)
        XCTAssertEqual(try reopened.loadAllMetadata().count, 2)
        XCTAssertEqual(reopened.catalogCorruptRecordCount, 0)
    }

    func testMissingPackIsRecoverableButSymlinkIsRejected() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let input = makeSession(fixture, id: "one", text: "payload")
        try catalog.replace(input)
        let pack = try packURL(fixture, source: input.metadata.file)
        try FileManager.default.removeItem(at: pack)
        let reopened = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        XCTAssertTrue(try reopened.listEntries().isEmpty)
        XCTAssertEqual(reopened.catalogCorruptRecordCount, 1)
        let outside = fixture.root.appendingPathComponent("outside")
        try Data("not ours".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: pack, withDestinationURL: outside)
        let unsafe = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        XCTAssertThrowsError(try unsafe.listEntries())
        XCTAssertEqual(try String(contentsOf: outside), "not ours")
    }

    func testFIFOCatalogObjectsAreRejectedWithoutBlocking() throws {
        for kind in ["manifest", "header", "lock"] {
            let fixture = try Fixture()
            var catalog: ConversationFileCatalog? = try .init(file: fixture.catalog, enableTgrep: false)
            let input = makeSession(fixture, id: "one", text: "body")
            try catalog?.replace(input)
            let target: URL
            switch kind {
            case "manifest": target = fixture.catalog.appendingPathComponent("manifest.json")
            case "lock": target = fixture.catalog.appendingPathComponent(".catalog.lock")
            default: target = try headerURL(fixture, source: input.metadata.file)
            }
            catalog = nil
            try FileManager.default.removeItem(at: target)
            XCTAssertEqual(mkfifo(target.path, 0o600), 0)
            let finished = DispatchSemaphore(value: 0)
            let errors = Errors()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { finished.signal() }
                do {
                    let reopened = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
                    _ = try reopened.listEntries()
                    errors.append(NSError(domain: "unsafe-fifo-was-accepted", code: 1))
                } catch ConversationFileCatalog.Failure.unsafeFile {
                    // The ordinary-private-file requirement remains in force.
                } catch { errors.append(error) }
            }
            let status = finished.wait(timeout: .now() + .milliseconds(500))
            if status == .timedOut {
                // A regression must fail, not leave a blocked worker behind in the test host.
                let writer = open(target.path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                if writer >= 0 { close(writer) }
                _ = finished.wait(timeout: .now() + 2)
            }
            XCTAssertEqual(status, .success, "\(kind) FIFO blocked before the file-type check")
            XCTAssertTrue(errors.values.isEmpty, "\(kind): \(errors.values)")
        }
    }

    func testChecksumDetectsDamagedCompressedPackBeforePublishingText() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let input = makeSession(fixture, id: "one", text: String(repeating: "payload", count: 10_000))
        try catalog.replace(input)
        let pack = try packURL(fixture, source: input.metadata.file)
        var bytes = try Data(contentsOf: pack)
        bytes[bytes.count / 2] ^= 0x80
        try bytes.write(to: pack)
        let reference = try XCTUnwrap(catalog.allDocumentReferences().references.first)
        XCTAssertThrowsError(try catalog.searchChunkWindows(reference: reference, query: "payload"))
        XCTAssertNil(try catalog.storedFingerprints()[input.metadata.file.path],
            "The scanner must reparse unchanged source files after detecting damaged derived bytes")
        XCTAssertTrue(try catalog.scannerEntries().isEmpty)
        XCTAssertEqual(catalog.catalogCorruptRecordCount, 1)
        try catalog.replace(input)
        XCTAssertEqual(try catalog.documents(for: input.metadata.file), input.documents)
        XCTAssertEqual(try catalog.storedFingerprints()[input.metadata.file.path], input.fingerprint)
    }

    func testLongUnicodeQueryAndNonoverlappingCountsAcrossChunkBoundaries() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let query = "unique/" + String(repeating: "世界e\u{301}👩‍💻", count: 8_000) + "/end"
        let text = String(repeating: "x", count: ConversationSearchChunk.targetBytes - 2) + query + " tail"
        try catalog.replace(makeSession(fixture, id: "long", text: text))
        let reference = try XCTUnwrap(catalog.allDocumentReferences().references.first)
        let first = try XCTUnwrap(catalog.searchChunkWindows(reference: reference, query: query).windows.first)
        let match = try XCTUnwrap(first.text.range(of: query, options: .caseInsensitive))
        XCTAssertEqual(match.lowerBound.utf16Offset(in: first.text), ConversationSearchChunk.targetBytes - 2)
        XCTAssertLessThan(match.lowerBound.utf16Offset(in: first.text), first.ownedUTF16Length)
        XCTAssertTrue(try XCTUnwrap(catalog.searchChunkSnippet(reference: reference,
            offsetUTF16: ConversationSearchChunk.targetBytes - 2, matchLengthUTF16: query.utf16.count))
            .contains("/end"))
    }

    func testSparseCandidatePaginationVisitsOnlySelectedOwnedChunks() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let text = String(repeating: "a", count: ConversationSearchChunk.targetBytes * 20)
        try catalog.replace(makeSession(fixture, id: "many", text: text))
        let document = try XCTUnwrap(catalog.catalogSearchSnapshot().documents.first)
        var reference = document.reference
        reference.candidateChunkIDs = [document.chunkIDs[1], document.chunkIDs[9], document.chunkIDs[19]]
        var cursor: ConversationIndexSearchCursor?
        var visited: [Int64] = []
        repeat {
            let page = try catalog.searchChunkWindows(reference: reference, query: "a", cursor: cursor, limit: 1)
            visited.append(contentsOf: page.windows.map(\.chunkID))
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(visited, reference.candidateChunkIDs)
    }

    func testMetadataRevisionRejectsForegroundCursorButNotUnchangedBackgroundContent() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        var input = makeSession(fixture, id: "one", text: String(repeating: "body", count: 30_000))
        try catalog.replace(input)
        let snapshot = try catalog.catalogSearchSnapshot()
        let document = try XCTUnwrap(snapshot.documents.first)
        let page = try catalog.searchChunkWindows(reference: document.reference, query: "body")
        input.metadata.pinned = true
        input.documents = []
        try catalog.replaceMetadata([input])
        XCTAssertThrowsError(try catalog.searchChunkWindows(reference: document.reference,
            query: "body", cursor: page.nextCursor))
        XCTAssertFalse(try catalog.searchIndexGroup(document: document, firstOrdinal: 0,
            generation: snapshot.generation).isEmpty)
        XCTAssertThrowsError(try catalog.refinementGeneration(reference: document.reference))
    }

    func testRebuildPreservesIdentifierMonotonicityAndOriginalHistoryFiles() throws {
        let fixture = try Fixture()
        let original = fixture.root.appendingPathComponent("conversation-index-v1.sqlite3")
        let bytes = Data("untouched obsolete cache".utf8)
        try bytes.write(to: original)
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let input = makeSession(fixture, id: "one", text: "body")
        try Data("producer bytes".utf8).write(to: input.metadata.file)
        try catalog.replace(input)
        let before = try XCTUnwrap(catalog.catalogSearchSnapshot().documents.first)
        XCTAssertEqual(try catalog.rebuild(), 2)
        try catalog.replace(input)
        let after = try XCTUnwrap(catalog.catalogSearchSnapshot().documents.first)
        XCTAssertGreaterThan(after.reference.documentID, before.reference.documentID)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try String(contentsOf: input.metadata.file), "producer bytes")
    }

    func testGarbageCollectionKeepsPublishedObjectsAndOpenReaderFDAlive() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        var input = makeSession(fixture, id: "one", text: "old unique body")
        try catalog.replace(input)
        let oldPack = try packURL(fixture, source: input.metadata.file)
        let expected = try Data(contentsOf: oldPack)
        let descriptor = open(oldPack.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        input.documents = [.init(transcriptID: "main", sortOrder: 0, text: "new body")]
        try catalog.replace(input)
        let currentPack = try packURL(fixture, source: input.metadata.file)
        let generation = try catalog.generation()
        for _ in 0..<10 where try catalog.maintenanceIsPending() { try catalog.finishFullScanMaintenance() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPack.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentPack.path))
        var actual = Data(count: expected.count)
        let readCount = actual.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(readCount, expected.count)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(try catalog.generation(), generation)
        XCTAssertEqual(try catalog.documents(for: input.metadata.file).first?.text, "new body")
        // A second pass must start a fresh directory stream, not inherit readdir's EOF.
        input.documents[0].text = "third body"
        try catalog.replace(input)
        for _ in 0..<10 where try catalog.maintenanceIsPending() { try catalog.finishFullScanMaintenance() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentPack.path))
    }

    func testMaintenanceCancellationWinsOverActivityAndLeavesPublishedData() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let input = makeSession(fixture, id: "one", text: "body")
        try catalog.replace(input)
        XCTAssertThrowsError(try catalog.finishFullScanMaintenance(shouldYield: { true }, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(try catalog.documents(for: input.metadata.file), input.documents)
        XCTAssertTrue(try catalog.maintenanceIsPending())
    }

    func testOrphanPartialCleanupHonorsLiveLeaseAndPreservesUnknownFilesAndLinks() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let name = ".\(UUID().uuidString.lowercased()).partial"
        let partial = fixture.objects.appendingPathComponent(name)
        let descriptor = open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let outside = fixture.root.appendingPathComponent("do-not-touch.txt")
        try Data("original".utf8).write(to: outside)
        let unknown = fixture.objects.appendingPathComponent("not-an-owned-pack.txt")
        try Data("keep".utf8).write(to: unknown)
        let link = fixture.objects.appendingPathComponent("\(UUID().uuidString.lowercased()).pack")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try catalog.finishFullScanMaintenance()
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        try catalog.finishFullScanMaintenance()
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try String(contentsOf: outside), "original")
        XCTAssertEqual(try String(contentsOf: unknown), "keep")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), outside.path)
        XCTAssertEqual(try catalog.generation(), 0)
    }

    func testSameRevisionCatalogIdentityReplacementRejectsOldReferences() throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        try catalog.replace(makeSession(fixture, id: "one", text: "body"))
        let old = try XCTUnwrap(catalog.allDocumentReferences().references.first)
        let manifest = fixture.catalog.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        object["identity"] = UUID().uuidString.lowercased()
        object.removeValue(forKey: "checksum")
        let canonical = try JSONSerialization.data(withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
        object["checksum"] = Data(SHA256.hash(data: canonical)).base64EncodedString()
        try JSONSerialization.data(withJSONObject: object).write(to: manifest)
        XCTAssertEqual(try catalog.generation(), 1)
        XCTAssertNotEqual(try catalog.catalogIdentity(), old.catalogIdentity)
        XCTAssertThrowsError(try catalog.refinementGeneration(reference: old))
        XCTAssertThrowsError(try catalog.searchChunkWindows(reference: old, query: "body"))
    }

    func testWriterWaitingForOtherProcessLockCancelsPromptly() async throws {
        let fixture = try Fixture()
        let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
        let input = makeSession(fixture, id: "one", text: "body")
        let descriptor = open(fixture.catalog.appendingPathComponent(".catalog.lock").path,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { _ = flock(descriptor, LOCK_UN); close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let task = Task.detached { try catalog.replace(input) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled write was published") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        _ = flock(descriptor, LOCK_UN)
        XCTAssertEqual(try catalog.generation(), 0)
        XCTAssertFalse(try catalog.hasRows())
    }

    func testRepeatedOpenReadReleaseKeepsOneCommittedRevision() throws {
        let fixture = try Fixture()
        let input = makeSession(fixture, id: "one", text: "body")
        try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false).replace(input)
        for _ in 0..<16 {
            let catalog = try ConversationFileCatalog(file: fixture.catalog, enableTgrep: false)
            XCTAssertEqual(try catalog.generation(), 1)
            XCTAssertEqual(try catalog.documents(for: input.metadata.file), input.documents)
        }
    }

    private func makeSession(_ fixture: Fixture, id: String, text: String) -> ConversationIndexedSession {
        let metadata = HistorySessionMetadata(id: "claude:\(id)",
            file: fixture.root.appendingPathComponent("\(id).jsonl"), source: .claude,
            dirID: "scope", dirLabel: "Scope", sessionID: id, project: "Project", title: id,
            autoTitle: id, createdAt: Date(timeIntervalSince1970: 1_800_000_000.125),
            lastActivity: Date(timeIntervalSince1970: 1_800_000_100.75), sizeBytes: UInt64(text.utf8.count))
        return .init(metadata: metadata,
            fingerprint: .init(modificationTime: Date(timeIntervalSince1970: 1_800_000_101.5),
                sizeBytes: UInt64(text.utf8.count)),
            documents: [.init(transcriptID: "main", sortOrder: 0, text: text,
                messageSpans: [.init(sequence: 0, messageIndex: 0, utf16Location: 0,
                    utf16Length: text.utf16.count, role: "user", timestamp: metadata.createdAt)])])
    }

    private func permissions(_ file: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
            .intValue & 0o777
    }

    private func objectNames(_ fixture: Fixture) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixture.objects.path).sorted()
    }

    private func headerURL(_ fixture: Fixture, source: URL) throws -> URL {
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: fixture.catalog.appendingPathComponent("manifest.json"))) as? [String: Any])
        let objects = try XCTUnwrap(manifest["objects"] as? [String: [String: Any]])
        let name = try XCTUnwrap(objects[source.path]?["name"] as? String)
        return fixture.objects.appendingPathComponent(name)
    }

    private func packURL(_ fixture: Fixture, source: URL) throws -> URL {
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: headerURL(fixture, source: source))) as? [String: Any])
        return fixture.objects.appendingPathComponent(try XCTUnwrap(header["pack"] as? String))
    }

    private final class Errors: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var values: [String] { lock.withLock { stored } }
        func append(_ error: Error) { lock.withLock { stored.append(String(describing: error)) } }
    }

    private final class LockedValue<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value { lock.withLock { stored } }
        @discardableResult
        func modify<Result>(_ body: (inout Value) -> Result) -> Result {
            lock.withLock { body(&stored) }
        }
    }

    private final class Fixture {
        let root: URL
        var catalog: URL { root.appendingPathComponent("catalog-v1", isDirectory: true) }
        var objects: URL { catalog.appendingPathComponent("objects", isDirectory: true) }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ccbuddy-file-catalog-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }
}
