import CryptoKit
import Foundation
import XCTest
@testable import CCBuddy

final class UpdateSemanticVersionTests: XCTestCase {
    func testSemVerPrecedenceAndBuildMetadata() throws {
        let ordered = [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
            "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1",
            "1.1.0", "2.0.0",
        ].compactMap(UpdateSemanticVersion.init)

        XCTAssertEqual(ordered.count, 11)
        XCTAssertEqual(ordered.sorted(), ordered)
        XCTAssertEqual(UpdateSemanticVersion("v1.2.3")?.description, "1.2.3")
        XCTAssertEqual(UpdateSemanticVersion("1.2.3+arm64"), UpdateSemanticVersion("1.2.3+x64"))
        XCTAssertFalse(
            try XCTUnwrap(UpdateSemanticVersion("1.2.3+arm64"))
                < XCTUnwrap(UpdateSemanticVersion("1.2.3+x64"))
        )
    }

    func testRejectsMalformedSemVer() {
        let invalid = [
            "", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "1.2.-1",
            "1.2.3-", "1.2.3+", "1.2.3-alpha..1", "1.2.3-alpha_1", "V1.2.3",
            "1.2.3+meta+again", String(repeating: "1", count: 129),
        ]
        for source in invalid {
            XCTAssertNil(UpdateSemanticVersion(source), source)
        }
    }
}

final class UpdateCryptographyTests: XCTestCase {
    private let publicKey = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3"
    private let signatureText = """
    untrusted comment: signature from minisign secret key
    RUQf6LRCGA9i559r3g7V1qNyJDApGip8MfqcadIgT9CuhV3EMhHoN1mGTkUidF/z7SrlQgXdy8ofjb7bNJJylDOocrCo8KLzZwo=
    trusted comment: timestamp:1556193335\tfile:test
    y/rUw2y8/hOUYjZU71eHp/Wo1KZ40fGy2VJEDl34XMJM+TX48Ss/17u3IvIfbVR1FkZZSNCisQbuQY+bHwhEBg==
    """

    func testBlake2b512KnownVectors() {
        XCTAssertEqual(hex(Blake2b512.hash(Data())),
            "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d" +
            "25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce")
        XCTAssertEqual(hex(Blake2b512.hash(Data("test".utf8))),
            "a71079d42853dea26e453004338670a53814b78137ffbed07603a41d76a483aa9" +
            "bc33b582f77d30a65e6f29a896c0411f38312e1d66e0bf16386c86a89bea572")
    }

    func testKnownMinisignVectorAndTampering() throws {
        let verifier = try MinisignUpdateVerifier(encodedPublicKey: publicKey)
        let encoded = Data(signatureText.utf8).base64EncodedString()

        XCTAssertTrue(verifier.verify(artifact: Data("test".utf8), encodedSignature: encoded))
        XCTAssertFalse(verifier.verify(artifact: Data("tent".utf8), encodedSignature: encoded))
        XCTAssertFalse(verifier.verify(artifact: Data("test".utf8), encodedSignature: "not-base64"))
    }

    func testSignedVerifierRequiresSignatureAndMatchingOptionalSHA256() throws {
        let verifier = try SignedUpdateArtifactVerifier(encodedPublicKey: publicKey)
        let artifact = Data("test".utf8)
        let encoded = Data(signatureText.utf8).base64EncodedString()
        let digest = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

        XCTAssertEqual(
            try verifier.verify(
                artifact: artifact,
                encodedSignature: encoded,
                expectedSHA256: "sha256:\(digest.uppercased())"
            ),
            digest
        )
        XCTAssertThrowsError(try verifier.verify(
            artifact: artifact,
            encodedSignature: encoded,
            expectedSHA256: String(repeating: "0", count: 64)
        )) { XCTAssertEqual($0 as? UpdateServiceError, .digestMismatch) }
        XCTAssertThrowsError(try verifier.verify(
            artifact: Data("tampered".utf8),
            encodedSignature: encoded,
            expectedSHA256: nil
        )) { XCTAssertEqual($0 as? UpdateServiceError, .invalidSignature) }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

final class UpdateServiceTests: XCTestCase {
    private var root: URL!
    private var currentApplication: URL!
    private var sessions: [URLSession] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ccbud-update-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        currentApplication = root.appendingPathComponent("Current.app", isDirectory: true)
        try FileManager.default.createDirectory(at: currentApplication, withIntermediateDirectories: true)
        UpdateURLProtocolStub.setHandler(nil)
    }

    override func tearDownWithError() throws {
        sessions.forEach { $0.invalidateAndCancel() }
        sessions = []
        UpdateURLProtocolStub.setHandler(nil)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testCheckReportsAvailableAndUpToDateUsingSemVer() async throws {
        UpdateURLProtocolStub.setHandler { _ in
            .json(self.manifest(version: "1.2.0"))
        }
        let availableService = makeService(currentVersion: "1.1.9")
        guard case .available(let release) = await availableService.check() else {
            return XCTFail("Expected available")
        }
        XCTAssertEqual(release.version.description, "1.2.0")
        XCTAssertEqual(release.notes, "Security update")

        let currentService = makeService(currentVersion: "1.2.0+native")
        guard case .upToDate(let version, _) = await currentService.check() else {
            return XCTFail("Expected up to date")
        }
        XCTAssertEqual(version, "1.2.0+native")
    }

    func testRejectsInsecureMetadataAndEveryRedirectDestination() async throws {
        let insecure = makeService(
            currentVersion: "1.0.0",
            metadataURL: URL(string: "http://updates.example/latest.json")!
        )
        guard case .manualDownload(nil, let reason) = await insecure.check() else {
            return XCTFail("Expected manual fallback")
        }
        XCTAssertTrue(reason.contains("HTTPS"))

        XCTAssertThrowsError(try UpdateURLTrust.validate(
            URL(string: "http://updates.example/artifact")!,
            trustedHosts: ["updates.example"]
        )) { XCTAssertEqual($0 as? UpdateServiceError, .insecureURL("http://updates.example/artifact")) }
        XCTAssertThrowsError(try UpdateURLTrust.validate(
            URL(string: "https://attacker.example/artifact")!,
            trustedHosts: ["updates.example"]
        )) { XCTAssertEqual($0 as? UpdateServiceError, .untrustedHost("attacker.example")) }
        XCTAssertThrowsError(try UpdateURLTrust.validate(
            URL(string: "https://updates.example:8443/artifact")!,
            trustedHosts: ["updates.example"]
        )) { XCTAssertEqual($0 as? UpdateServiceError, .insecureURL("https://updates.example:8443/artifact")) }

        let delegate = HTTPSOnlyRedirectDelegate(trustedHosts: ["updates.example"])
        let redirectRequest = URLRequest(url: URL(string: "http://updates.example/artifact")!)
        let task = makeSession().dataTask(with: redirectRequest)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://updates.example/start")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        ))
        let rejected = expectation(description: "redirect rejected")
        delegate.urlSession(makeSession(), task: task, willPerformHTTPRedirection: response,
            newRequest: redirectRequest) { request in
                XCTAssertNil(request)
                rejected.fulfill()
            }
        await fulfillment(of: [rejected], timeout: 1)
        XCTAssertEqual(delegate.violation, .insecureURL("http://updates.example/artifact"))
    }

    func testMissingPlatformSignatureAndSecureArtifactURLUseManualFallback() async throws {
        UpdateURLProtocolStub.setHandler { _ in .json(self.manifest(version: "2.0.0", platform: nil)) }
        guard case .manualDownload(let missingPlatformRelease, _) = await makeService().check() else {
            return XCTFail("Expected missing-platform fallback")
        }
        XCTAssertEqual(missingPlatformRelease?.version.description, "2.0.0")

        UpdateURLProtocolStub.setHandler { _ in
            .json(self.manifest(version: "2.0.0", signature: ""))
        }
        guard case .manualDownload(let unsignedRelease, let unsignedReason) = await makeService().check()
        else { return XCTFail("Expected unsigned fallback") }
        XCTAssertEqual(unsignedRelease?.version.description, "2.0.0")
        XCTAssertTrue(unsignedReason.contains("签名"))

        UpdateURLProtocolStub.setHandler { _ in
            .json(self.manifest(version: "2.0.0", artifactURL: "http://updates.example/app.tar.gz"))
        }
        guard case .manualDownload(_, let insecureReason) = await makeService().check()
        else { return XCTFail("Expected insecure-artifact fallback") }
        XCTAssertTrue(insecureReason.contains("HTTPS"))
    }

    func testResponseSizeLimitsFailClosed() async throws {
        UpdateURLProtocolStub.setHandler { _ in
            UpdateURLProtocolStub.Response(statusCode: 200, data: Data(repeating: 0x61, count: 65))
        }
        let metadataService = makeService(maximumMetadataBytes: 64)
        guard case .failed(_, let metadataError) = await metadataService.check() else {
            return XCTFail("Expected oversized metadata failure")
        }
        XCTAssertTrue(metadataError.contains("超过"))

        UpdateURLProtocolStub.setHandler { request in
            if request.url?.path == "/latest.json" {
                return .json(self.manifest(version: "2.0.0"))
            }
            return UpdateURLProtocolStub.Response(statusCode: 200, data: Data(repeating: 0x61, count: 65))
        }
        let artifactService = makeService(maximumArtifactBytes: 64)
        guard case .available = await artifactService.check() else {
            return XCTFail("Expected available")
        }
        guard case .failed(_, let artifactError) = await artifactService.downloadAndStage() else {
            return XCTFail("Expected oversized artifact failure")
        }
        XCTAssertTrue(artifactError.contains("超过"))
    }

    func testSuccessfulDownloadStagesPrivateVerifiedApplicationAndReceipt() async throws {
        let artifact = Data("signed archive".utf8)
        UpdateURLProtocolStub.setHandler { request in
            request.url?.path == "/latest.json"
                ? .json(self.manifest(version: "2.0.0"))
                : .init(statusCode: 200, data: artifact)
        }
        let service = makeService(
            artifactVerifier: ArtifactVerifierStub { received, signature, digest in
                XCTAssertEqual(received, artifact)
                XCTAssertEqual(signature, "publisher-signature")
                XCTAssertNil(digest)
                return String(repeating: "a", count: 64)
            },
            archiveExtractor: CreatingExtractor(),
            applicationVerifier: AcceptingApplicationVerifier()
        )

        guard case .available = await service.check() else { return XCTFail("Expected available") }
        guard case .staged(let staged) = await service.downloadAndStage() else {
            return XCTFail("Expected staged")
        }

        XCTAssertTrue(staged.applicationURL.path.hasPrefix(staged.directoryURL.path + "/"))
        XCTAssertEqual(staged.artifactSHA256, String(repeating: "a", count: 64))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: staged.directoryURL.appendingPathComponent("receipt.json").path
        ))
        let rootMode = try FileManager.default.attributesOfItem(
            atPath: configuration().stagingRoot.path
        )[.posixPermissions] as? Int
        XCTAssertEqual(rootMode, 0o700)
    }

    func testSignatureAndApplicationVerificationFailuresFallBackToFullDownload() async throws {
        UpdateURLProtocolStub.setHandler { request in
            request.url?.path == "/latest.json"
                ? .json(self.manifest(version: "2.0.0"))
                : .init(statusCode: 200, data: Data("archive".utf8))
        }
        let badSignature = makeService(
            artifactVerifier: ArtifactVerifierStub { _, _, _ in
                throw UpdateServiceError.invalidSignature
            },
            archiveExtractor: CreatingExtractor(),
            applicationVerifier: AcceptingApplicationVerifier()
        )
        _ = await badSignature.check()
        guard case .manualDownload(let signatureRelease, let signatureReason) =
                await badSignature.downloadAndStage()
        else { return XCTFail("Expected invalid-signature fallback") }
        XCTAssertEqual(signatureRelease?.version.description, "2.0.0")
        XCTAssertTrue(signatureReason.contains("签名"))

        let badApplication = makeService(
            artifactVerifier: AcceptingArtifactVerifier(),
            archiveExtractor: CreatingExtractor(),
            applicationVerifier: ApplicationVerifierStub { _, _ in
                throw UpdateServiceError.codeSignature("wrong team")
            }
        )
        _ = await badApplication.check()
        guard case .manualDownload(_, let applicationReason) = await badApplication.downloadAndStage()
        else { return XCTFail("Expected code-signature fallback") }
        XCTAssertTrue(applicationReason.contains("Developer ID") || applicationReason.contains("公证"))
    }

    func testExtractorCannotReturnApplicationOutsideOperationStaging() async throws {
        let outside = root.appendingPathComponent("Outside.app", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        UpdateURLProtocolStub.setHandler { request in
            request.url?.path == "/latest.json"
                ? .json(self.manifest(version: "2.0.0"))
                : .init(statusCode: 200, data: Data("archive".utf8))
        }
        let service = makeService(
            artifactVerifier: AcceptingArtifactVerifier(),
            archiveExtractor: ReturningExtractor(applicationURL: outside),
            applicationVerifier: AcceptingApplicationVerifier()
        )

        _ = await service.check()
        guard case .manualDownload(_, let reason) = await service.downloadAndStage() else {
            return XCTFail("Expected outside-staging fallback")
        }
        XCTAssertTrue(reason.contains("暂存目录之外"))
        let stagingContents = (try? FileManager.default.contentsOfDirectory(
            at: configuration().stagingRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertFalse(stagingContents.contains { $0.lastPathComponent.hasPrefix("staging-") })
    }

    func testPrivateStagingRootCannotBeReplacedBySymlink() async throws {
        let stagingRoot = configuration().stagingRoot
        let target = root.appendingPathComponent("attacker-controlled", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: stagingRoot, withDestinationURL: target)
        UpdateURLProtocolStub.setHandler { request in
            request.url?.path == "/latest.json"
                ? .json(self.manifest(version: "2.0.0"))
                : .init(statusCode: 200, data: Data("archive".utf8))
        }
        let service = makeService(
            artifactVerifier: AcceptingArtifactVerifier(),
            archiveExtractor: CreatingExtractor(),
            applicationVerifier: AcceptingApplicationVerifier()
        )

        _ = await service.check()
        guard case .manualDownload(_, let reason) = await service.downloadAndStage() else {
            return XCTFail("Expected unsafe-staging fallback")
        }
        XCTAssertTrue(reason.contains("暂存"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    func testTarExtractorAcceptsOneApplicationAndRejectsExternalSymlinkOrSecondRoot() throws {
        let source = root.appendingPathComponent("tar-source", isDirectory: true)
        let app = source.appendingPathComponent("CCBuddy.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: contents.appendingPathComponent("marker"))
        let validArchive = try createTar(from: source, entries: ["CCBuddy.app"])
        let validDestination = root.appendingPathComponent("valid-extraction", isDirectory: true)

        let extracted = try TarGzipUpdateExtractor().extract(
            archiveURL: validArchive,
            destinationURL: validDestination
        )
        XCTAssertEqual(extracted.lastPathComponent, "CCBuddy.app")
        XCTAssertEqual(
            try String(contentsOf: extracted.appendingPathComponent("Contents/marker")),
            "safe"
        )

        try FileManager.default.createSymbolicLink(
            at: app.appendingPathComponent("escape"),
            withDestinationURL: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )
        let symlinkArchive = try createTar(from: source, entries: ["CCBuddy.app"])
        XCTAssertThrowsError(try TarGzipUpdateExtractor().extract(
            archiveURL: symlinkArchive,
            destinationURL: root.appendingPathComponent("symlink-extraction", isDirectory: true)
        )) { error in
            guard case .archiveExtraction = error as? UpdateServiceError else {
                return XCTFail("Expected archive-extraction error, got \(error)")
            }
        }

        let second = source.appendingPathComponent("Other.app", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let multipleArchive = try createTar(from: source, entries: ["CCBuddy.app", "Other.app"])
        XCTAssertThrowsError(try TarGzipUpdateExtractor().extract(
            archiveURL: multipleArchive,
            destinationURL: root.appendingPathComponent("multiple-extraction", isDirectory: true)
        )) { error in
            guard case .archiveExtraction = error as? UpdateServiceError else {
                return XCTFail("Expected archive-extraction error, got \(error)")
            }
        }
    }

    func testInstallCommitAndRollbackStateMachine() async throws {
        UpdateURLProtocolStub.setHandler { request in
            request.url?.path == "/latest.json"
                ? .json(self.manifest(version: "2.0.0"))
                : .init(statusCode: 200, data: Data("archive".utf8))
        }
        let installer = InstallerSpy()
        let service = makeService(
            artifactVerifier: AcceptingArtifactVerifier(),
            archiveExtractor: CreatingExtractor(),
            applicationVerifier: AcceptingApplicationVerifier(),
            installer: installer
        )
        _ = await service.check()
        guard case .staged = await service.downloadAndStage() else {
            return XCTFail("Expected staged")
        }
        guard case .installed(let installed) = await service.installStaged() else {
            return XCTFail("Expected installed")
        }
        XCTAssertEqual(installed.applicationURL, currentApplication)
        XCTAssertEqual(installer.prepareCount, 1)
        XCTAssertEqual(installer.commitCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: configuration().stagingRoot.appendingPathComponent("installed.json").path
        ))

        guard case .staged = await service.rollbackInstalledUpdate() else {
            return XCTFail("Expected restored staged state")
        }
        XCTAssertEqual(installer.rollbackCount, 1)
        XCTAssertEqual(installer.discardCount, 1)
    }

    func testReceiptAndRollbackDoubleFailurePreservesOnlyOldApplicationBackup() async throws {
        UpdateURLProtocolStub.setHandler { request in
            request.url?.path == "/latest.json"
                ? .json(self.manifest(version: "2.0.0"))
                : .init(statusCode: 200, data: Data("archive".utf8))
        }
        let installer = InstallerSpy(rollbackError: UpdateServiceError.installation("rollback failed"))
        let service = makeService(
            artifactVerifier: AcceptingArtifactVerifier(),
            archiveExtractor: CreatingExtractor(),
            applicationVerifier: AcceptingApplicationVerifier(),
            installer: installer
        )
        _ = await service.check()
        guard case .staged = await service.downloadAndStage() else {
            return XCTFail("Expected staged")
        }

        let receiptURL = configuration().stagingRoot.appendingPathComponent(
            "installed.json",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: receiptURL, withIntermediateDirectories: false)

        guard case .manualDownload(_, let reason) = await service.installStaged() else {
            return XCTFail("Expected manual fallback after receipt and rollback failure")
        }
        XCTAssertEqual(installer.commitCount, 1)
        XCTAssertEqual(installer.rollbackCount, 1)
        XCTAssertEqual(
            installer.discardCount,
            0,
            "The backup is the only old application after rollback fails and must be preserved"
        )
        XCTAssertTrue(reason.contains("rollback failed"))
        XCTAssertTrue(reason.contains(".CCBuddy.update-test.app"))
    }

    func testUntrustedRunningApplicationIsNeverPreparedForReplacement() async throws {
        UpdateURLProtocolStub.setHandler { request in
            request.url?.path == "/latest.json"
                ? .json(self.manifest(version: "2.0.0"))
                : .init(statusCode: 200, data: Data("archive".utf8))
        }
        let installer = InstallerSpy()
        let verifier = ApplicationVerifierStub { [currentApplication] applicationURL, version in
            if applicationURL == currentApplication {
                throw UpdateServiceError.codeSignature("running build is ad-hoc")
            }
            return VerifiedUpdateApplication(
                bundleIdentifier: DeveloperIDUpdateVerifier.bundleIdentifier,
                version: version,
                teamIdentifier: DeveloperIDUpdateVerifier.teamIdentifier
            )
        }
        let service = makeService(
            artifactVerifier: AcceptingArtifactVerifier(),
            archiveExtractor: CreatingExtractor(),
            applicationVerifier: verifier,
            installer: installer
        )
        _ = await service.check()
        guard case .staged = await service.downloadAndStage() else {
            return XCTFail("Expected staged")
        }
        guard case .manualDownload(_, let reason) = await service.installStaged() else {
            return XCTFail("Expected manual fallback")
        }
        XCTAssertTrue(reason.contains("Developer ID") || reason.contains("公证"))
        XCTAssertEqual(installer.prepareCount, 0)
        XCTAssertEqual(installer.commitCount, 0)
    }

    func testNextVerifiedLaunchFinalizesBackupAndInstallationReceipt() async throws {
        UpdateURLProtocolStub.setHandler { request in
            request.url?.path == "/latest.json"
                ? .json(self.manifest(version: "2.0.0"))
                : .init(statusCode: 200, data: Data("archive".utf8))
        }
        let service = makeService(
            artifactVerifier: AcceptingArtifactVerifier(),
            archiveExtractor: CreatingExtractor(),
            applicationVerifier: AcceptingApplicationVerifier(),
            installer: AtomicUpdateInstaller()
        )
        _ = await service.check()
        _ = await service.downloadAndStage()
        guard case .installed(let installed) = await service.installStaged() else {
            return XCTFail("Expected installed")
        }
        let receipt = configuration().stagingRoot.appendingPathComponent("installed.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.backupApplicationURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.path))

        let relaunchedService = UpdateService(
            configuration: configuration(currentVersion: "2.0.0"),
            session: makeSession(),
            artifactVerifier: AcceptingArtifactVerifier(),
            archiveExtractor: CreatingExtractor(),
            applicationVerifier: AcceptingApplicationVerifier(),
            installer: AtomicUpdateInstaller()
        )
        await relaunchedService.finalizePreviousInstallation()

        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.backupApplicationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
    }

    @MainActor
    func testAppModelPublishesUpdaterFlowAndSchedulesRelaunchAfterCommit() async throws {
        UpdateURLProtocolStub.setHandler { request in
            request.url?.path == "/latest.json"
                ? .json(self.manifest(version: "2.0.0"))
                : .init(statusCode: 200, data: Data("archive".utf8))
        }
        let service = makeService(
            artifactVerifier: AcceptingArtifactVerifier(),
            archiveExtractor: CreatingExtractor(),
            applicationVerifier: AcceptingApplicationVerifier(),
            installer: InstallerSpy()
        )
        let scheduler = RelaunchSchedulerSpy()
        let termination = TerminationFlag()
        let model = AppModel(
            repository: ConfigRepository(configURL: root.appendingPathComponent("model/config.json")),
            supervisor: GatewaySupervisor(environment: ["CCBUD_HOME": root.path]),
            environment: ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"],
            updateService: service,
            updateRelaunchScheduler: scheduler,
            terminateAfterUpdate: { termination.value = true }
        )

        await model.checkForUpdates()
        guard case .available = model.updateState else { return XCTFail("Expected available") }
        await model.downloadUpdate()
        guard case .staged = model.updateState else { return XCTFail("Expected staged") }
        await model.installUpdateAndRelaunch()

        guard case .installed = model.updateState else { return XCTFail("Expected installed") }
        XCTAssertEqual(scheduler.applicationURL, currentApplication)
        XCTAssertEqual(scheduler.processID, ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(termination.value)
    }

    func testAutomaticLifecycleChecksOncePerLocalDayAndPersistsAcrossInstances() async throws {
        let requests = LockedCounter()
        UpdateURLProtocolStub.setHandler { _ in
            requests.increment()
            return .json(self.manifest(version: "1.0.0"))
        }
        let stampURL = automaticUpdateStampURL
        let service = makeService()
        let lifecycle = AutomaticUpdateLifecycle(
            updateService: service,
            stampFileURL: stampURL,
            calendar: utcCalendar
        )

        guard case .state(.upToDate) = await lifecycle.applicationBecameVisible(
            at: automaticCheckDate,
            checkEnabled: true,
            autoDownload: true
        ) else { return XCTFail("Expected a successful daily check") }
        XCTAssertEqual(requests.value, 1)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(contentsOf: stampURL)) as? [String: String],
            ["lastAutoCheckDay": "2026-08-22"]
        )
        let permissions = try FileManager.default.attributesOfItem(atPath: stampURL.path)[.posixPermissions]
            as? Int
        XCTAssertEqual(permissions, 0o600)

        let repeatedVisibility = await lifecycle.applicationBecameVisible(
            at: automaticCheckDate.addingTimeInterval(60),
            checkEnabled: true,
            autoDownload: true
        )
        XCTAssertEqual(repeatedVisibility, .skipped)
        let relaunchedLifecycle = AutomaticUpdateLifecycle(
            updateService: makeService(),
            stampFileURL: stampURL,
            calendar: utcCalendar
        )
        let persistedVisibility = await relaunchedLifecycle.applicationBecameVisible(
            at: automaticCheckDate.addingTimeInterval(120),
            checkEnabled: true,
            autoDownload: true
        )
        XCTAssertEqual(persistedVisibility, .skipped)
        XCTAssertEqual(requests.value, 1)

        guard case .state(.upToDate) = await relaunchedLifecycle.applicationBecameVisible(
            at: automaticCheckDate.addingTimeInterval(24 * 60 * 60),
            checkEnabled: true,
            autoDownload: true
        ) else { return XCTFail("Expected a check on the next local day") }
        XCTAssertEqual(requests.value, 2)
    }

    func testAutomaticLifecycleRetriesOfflineCheckAtExactlyTenMinutes() async {
        let requests = LockedCounter()
        UpdateURLProtocolStub.setHandler { _ in
            requests.increment()
            throw URLError(.notConnectedToInternet)
        }
        let service = makeService()
        let lifecycle = AutomaticUpdateLifecycle(
            updateService: service,
            stampFileURL: automaticUpdateStampURL,
            calendar: utcCalendar
        )

        guard case .state(.failed) = await lifecycle.applicationBecameVisible(
            at: automaticCheckDate,
            checkEnabled: true,
            autoDownload: true
        ) else { return XCTFail("Expected offline failure") }
        let earlyRetry = await lifecycle.applicationBecameVisible(
            at: automaticCheckDate.addingTimeInterval(599),
            checkEnabled: true,
            autoDownload: true
        )
        XCTAssertEqual(earlyRetry, .skipped)
        XCTAssertEqual(requests.value, 1)
        guard case .state(.failed) = await lifecycle.applicationBecameVisible(
            at: automaticCheckDate.addingTimeInterval(600),
            checkEnabled: true,
            autoDownload: true
        ) else { return XCTFail("Expected retry at ten minutes") }
        XCTAssertEqual(requests.value, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: automaticUpdateStampURL.path))
    }

    func testAutomaticLifecycleRetriesFailedDownloadWithoutBurningDay() async {
        let metadataRequests = LockedCounter()
        let artifactRequests = LockedCounter()
        UpdateURLProtocolStub.setHandler { request in
            if request.url?.path == "/latest.json" {
                metadataRequests.increment()
                return .json(self.manifest(version: "2.0.0"))
            }
            artifactRequests.increment()
            throw URLError(.networkConnectionLost)
        }
        let lifecycle = AutomaticUpdateLifecycle(
            updateService: makeService(),
            stampFileURL: automaticUpdateStampURL,
            calendar: utcCalendar
        )

        guard case .state(.failed) = await lifecycle.applicationBecameVisible(
            at: automaticCheckDate,
            checkEnabled: true,
            autoDownload: true
        ) else { return XCTFail("Expected download failure") }
        let earlyRetry = await lifecycle.applicationBecameVisible(
            at: automaticCheckDate.addingTimeInterval(599),
            checkEnabled: true,
            autoDownload: true
        )
        XCTAssertEqual(earlyRetry, .skipped)
        guard case .state(.failed) = await lifecycle.applicationBecameVisible(
            at: automaticCheckDate.addingTimeInterval(600),
            checkEnabled: true,
            autoDownload: true
        ) else { return XCTFail("Expected failed download to retry") }
        XCTAssertEqual(metadataRequests.value, 2)
        XCTAssertEqual(artifactRequests.value, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: automaticUpdateStampURL.path))
    }

    func testAutomaticLifecycleStampsAvailableReleaseWhenAutoDownloadIsOff() async throws {
        let requests = LockedCounter()
        UpdateURLProtocolStub.setHandler { _ in
            requests.increment()
            return .json(self.manifest(version: "2.0.0"))
        }
        let lifecycle = AutomaticUpdateLifecycle(
            updateService: makeService(),
            stampFileURL: automaticUpdateStampURL,
            calendar: utcCalendar
        )

        guard case .state(.available) = await lifecycle.applicationBecameVisible(
            at: automaticCheckDate,
            checkEnabled: true,
            autoDownload: false
        ) else { return XCTFail("Expected available release") }
        XCTAssertEqual(requests.value, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: automaticUpdateStampURL.path))
    }

    func testAutomaticLifecycleAutoDownloadReturnsRestartPromptAndPreservesStage() async {
        let metadataRequests = LockedCounter()
        let artifactRequests = LockedCounter()
        UpdateURLProtocolStub.setHandler { request in
            if request.url?.path == "/latest.json" {
                metadataRequests.increment()
                return .json(self.manifest(version: "2.0.0"))
            }
            artifactRequests.increment()
            return .init(statusCode: 200, data: Data("archive".utf8))
        }
        let service = makeService()
        let lifecycle = AutomaticUpdateLifecycle(
            updateService: service,
            stampFileURL: automaticUpdateStampURL,
            calendar: utcCalendar
        )

        guard case .restartPrompt(let staged) = await lifecycle.applicationBecameVisible(
            at: automaticCheckDate,
            checkEnabled: true,
            autoDownload: true
        ) else { return XCTFail("Expected restart prompt") }
        XCTAssertEqual(staged.release.version.description, "2.0.0")
        XCTAssertEqual(metadataRequests.value, 1)
        XCTAssertEqual(artifactRequests.value, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: automaticUpdateStampURL.path))

        let nextDayLifecycle = AutomaticUpdateLifecycle(
            updateService: service,
            stampFileURL: automaticUpdateStampURL,
            calendar: utcCalendar
        )
        guard case .restartPrompt = await nextDayLifecycle.applicationBecameVisible(
            at: automaticCheckDate.addingTimeInterval(24 * 60 * 60),
            checkEnabled: true,
            autoDownload: true
        ) else { return XCTFail("Expected an existing stage to be prompted again") }
        XCTAssertEqual(metadataRequests.value, 2)
        XCTAssertEqual(artifactRequests.value, 1, "An existing verified stage must not be downloaded twice")
    }

    func testAutomaticLifecycleDeduplicatesConcurrentVisibilityEvents() async {
        let requests = LockedCounter()
        let requestStarted = expectation(description: "metadata request started")
        let releaseRequest = DispatchSemaphore(value: 0)
        UpdateURLProtocolStub.setHandler { _ in
            requests.increment()
            requestStarted.fulfill()
            _ = releaseRequest.wait(timeout: .now() + 5)
            return .json(self.manifest(version: "1.0.0"))
        }
        let lifecycle = AutomaticUpdateLifecycle(
            updateService: makeService(),
            stampFileURL: automaticUpdateStampURL,
            calendar: utcCalendar
        )
        let first = Task {
            await lifecycle.applicationBecameVisible(
                at: automaticCheckDate,
                checkEnabled: true,
                autoDownload: true
            )
        }
        await fulfillment(of: [requestStarted], timeout: 2)

        let duplicate = await lifecycle.applicationBecameVisible(
            at: automaticCheckDate,
            checkEnabled: true,
            autoDownload: true
        )
        XCTAssertEqual(duplicate, .skipped)
        releaseRequest.signal()
        guard case .state(.upToDate) = await first.value else {
            return XCTFail("Expected first visibility event to finish")
        }
        XCTAssertEqual(requests.value, 1)
    }

    func testRestartPromptMatchesEveryLegacyLanguage() {
        let version = "2.3.4"
        let expected: [(AppLanguage, UpdateRestartPrompt)] = [
            (.simplifiedChinese, .init(language: .simplifiedChinese, version: version)),
            (.traditionalChinese, .init(language: .traditionalChinese, version: version)),
            (.english, .init(language: .english, version: version)),
            (.japanese, .init(language: .japanese, version: version)),
            (.korean, .init(language: .korean, version: version)),
        ]
        XCTAssertEqual(promptValues(expected[0].1), [
            "更新已就绪", "新版本 2.3.4 已自动下载完成。是否立即重启以应用新版本？", "立即重启", "稍后",
        ])
        XCTAssertEqual(promptValues(expected[1].1), [
            "更新已就緒", "新版本 2.3.4 已自動下載完成。要立即重新啟動以套用新版本嗎？", "立即重啟", "稍後",
        ])
        XCTAssertEqual(promptValues(expected[2].1), [
            "Update ready",
            "Version 2.3.4 has been downloaded. Restart now to switch to the new version?",
            "Restart now", "Later",
        ])
        XCTAssertEqual(promptValues(expected[3].1), [
            "アップデートの準備ができました",
            "新しいバージョン 2.3.4 のダウンロードが完了しました。今すぐ再起動して適用しますか？",
            "今すぐ再起動", "後で",
        ])
        XCTAssertEqual(promptValues(expected[4].1), [
            "업데이트 준비 완료",
            "새 버전 2.3.4 다운로드가 완료되었습니다. 지금 다시 시작하여 적용할까요?",
            "지금 다시 시작", "나중에",
        ])
    }

    @MainActor
    func testAutomaticPromptRestartChoiceInstallsSchedulesRelaunchAndTerminates() async {
        UpdateURLProtocolStub.setHandler { request in
            request.url?.path == "/latest.json"
                ? .json(self.manifest(version: "2.0.0"))
                : .init(statusCode: 200, data: Data("archive".utf8))
        }
        let installer = InstallerSpy()
        let service = makeService(installer: installer)
        let scheduler = RelaunchSchedulerSpy()
        let termination = TerminationFlag()
        let prompts = UpdatePromptRecorder(choice: .restartNow)
        let model = makeAutomaticUpdateModel(
            service: service,
            scheduler: scheduler,
            termination: termination,
            promptRecorder: prompts
        )

        await model.applicationBecameVisible(at: automaticCheckDate)

        guard case .installed = model.updateState else { return XCTFail("Expected installed") }
        XCTAssertEqual(installer.commitCount, 1)
        XCTAssertEqual(scheduler.applicationURL, currentApplication)
        XCTAssertTrue(termination.value)
        XCTAssertEqual(prompts.values.count, 1)
    }

    @MainActor
    func testAutomaticPromptLaterCommitsReplacementWithoutRelaunch() async {
        UpdateURLProtocolStub.setHandler { request in
            request.url?.path == "/latest.json"
                ? .json(self.manifest(version: "2.0.0"))
                : .init(statusCode: 200, data: Data("archive".utf8))
        }
        let installer = InstallerSpy()
        let service = makeService(installer: installer)
        let scheduler = RelaunchSchedulerSpy()
        let termination = TerminationFlag()
        let prompts = UpdatePromptRecorder(choice: .later)
        let model = makeAutomaticUpdateModel(
            service: service,
            scheduler: scheduler,
            termination: termination,
            promptRecorder: prompts
        )

        await model.applicationBecameVisible(at: automaticCheckDate)

        guard case .installedAwaitingRestart(let installed) = model.updateState else {
            return XCTFail("Expected installed update awaiting a normal restart")
        }
        XCTAssertEqual(installed.applicationURL, currentApplication)
        XCTAssertEqual(installer.commitCount, 1, "Later must still commit the verified replacement")
        XCTAssertNil(scheduler.applicationURL)
        XCTAssertFalse(termination.value)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: configuration().stagingRoot.appendingPathComponent("installed.json").path
        ))
        XCTAssertEqual(prompts.values.count, 1)
    }

    func testDeveloperIDVerifierRejectsUnsignedApplication() throws {
        let app = root.appendingPathComponent("Unsigned.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": DeveloperIDUpdateVerifier.bundleIdentifier,
            "CFBundleShortVersionString": "2.0.0",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        XCTAssertThrowsError(try DeveloperIDUpdateVerifier().verify(
            applicationURL: app,
            expectedVersion: try XCTUnwrap(UpdateSemanticVersion("2.0.0"))
        )) { error in
            guard case .codeSignature = error as? UpdateServiceError else {
                return XCTFail("Expected code-signature error, got \(error)")
            }
        }
    }

    func testAtomicInstallerSwapsAndRollsBackApplicationDirectories() throws {
        let installer = AtomicUpdateInstaller()
        let staged = root.appendingPathComponent("Staged.app", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: currentApplication.appendingPathComponent("marker"))
        try Data("new".utf8).write(to: staged.appendingPathComponent("marker"))

        let prepared = try installer.prepare(
            stagedApplicationURL: staged,
            currentApplicationURL: currentApplication
        )
        let backup = try installer.commit(
            preparedApplicationURL: prepared,
            currentApplicationURL: currentApplication
        )
        XCTAssertEqual(try String(contentsOf: currentApplication.appendingPathComponent("marker")), "new")
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("marker")), "old")

        try installer.rollback(backupApplicationURL: backup, currentApplicationURL: currentApplication)
        XCTAssertEqual(try String(contentsOf: currentApplication.appendingPathComponent("marker")), "old")
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("marker")), "new")
        installer.discardPreparedApplication(at: backup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    private func makeService(
        currentVersion: String = "1.0.0",
        metadataURL: URL? = nil,
        maximumMetadataBytes: Int = 64 * 1_024,
        maximumArtifactBytes: Int = 64 * 1_024,
        artifactVerifier: any UpdateArtifactVerifying = AcceptingArtifactVerifier(),
        archiveExtractor: any UpdateArchiveExtracting = CreatingExtractor(),
        applicationVerifier: any UpdateApplicationVerifying = AcceptingApplicationVerifier(),
        installer: any UpdateApplicationInstalling = InstallerSpy()
    ) -> UpdateService {
        UpdateService(
            configuration: configuration(
                currentVersion: currentVersion,
                metadataURL: metadataURL,
                maximumMetadataBytes: maximumMetadataBytes,
                maximumArtifactBytes: maximumArtifactBytes
            ),
            session: makeSession(),
            artifactVerifier: artifactVerifier,
            archiveExtractor: archiveExtractor,
            applicationVerifier: applicationVerifier,
            installer: installer
        )
    }

    @MainActor
    private func makeAutomaticUpdateModel(
        service: UpdateService,
        scheduler: RelaunchSchedulerSpy,
        termination: TerminationFlag,
        promptRecorder: UpdatePromptRecorder
    ) -> AppModel {
        let lifecycle = AutomaticUpdateLifecycle(
            updateService: service,
            stampFileURL: automaticUpdateStampURL,
            calendar: utcCalendar
        )
        return AppModel(
            repository: ConfigRepository(configURL: root.appendingPathComponent("model/config.json")),
            supervisor: GatewaySupervisor(environment: ["CCBUD_HOME": root.path]),
            environment: ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"],
            updateService: service,
            automaticUpdateLifecycle: lifecycle,
            automaticUpdatesEnabled: true,
            updateRelaunchScheduler: scheduler,
            terminateAfterUpdate: { termination.value = true },
            automaticUpdatePrompt: { prompt in promptRecorder.respond(to: prompt) }
        )
    }

    private var automaticUpdateStampURL: URL {
        root.appendingPathComponent("update-check.json")
    }

    private var automaticCheckDate: Date {
        ISO8601DateFormatter().date(from: "2026-08-22T03:00:00Z")!
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func promptValues(_ prompt: UpdateRestartPrompt) -> [String] {
        [prompt.title, prompt.message, prompt.restartButtonTitle, prompt.laterButtonTitle]
    }

    private func configuration(
        currentVersion: String = "1.0.0",
        metadataURL: URL? = nil,
        maximumMetadataBytes: Int = 64 * 1_024,
        maximumArtifactBytes: Int = 64 * 1_024
    ) -> UpdateServiceConfiguration {
        UpdateServiceConfiguration(
            metadataURL: metadataURL ?? URL(string: "https://updates.example/latest.json")!,
            releasePageURL: URL(string: "https://updates.example/releases/latest")!,
            currentVersion: currentVersion,
            platformKeys: ["darwin-test"],
            stagingRoot: root.appendingPathComponent("updates", isDirectory: true),
            currentApplicationURL: currentApplication,
            trustedHosts: ["updates.example"],
            maximumMetadataBytes: maximumMetadataBytes,
            maximumArtifactBytes: maximumArtifactBytes
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        sessions.append(session)
        return session
    }

    private func manifest(
        version: String,
        platform: String? = "darwin-test",
        signature: String = "publisher-signature",
        artifactURL: String = "https://updates.example/app.tar.gz"
    ) -> Data {
        var object: [String: Any] = [
            "version": version,
            "notes": "  Security update  ",
            "pub_date": "2026-08-22T03:00:00Z",
            "platforms": [String: Any](),
        ]
        if let platform {
            object["platforms"] = [platform: ["url": artifactURL, "signature": signature]]
        }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func createTar(from source: URL, entries: [String]) throws -> URL {
        let archive = root.appendingPathComponent("\(UUID().uuidString).tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", archive.path, "-C", source.path] + entries
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateServiceError.archiveExtraction("test archive creation failed")
        }
        return archive
    }
}

private struct ArtifactVerifierStub: UpdateArtifactVerifying {
    let body: @Sendable (Data, String, String?) throws -> String

    func verify(artifact: Data, encodedSignature: String, expectedSHA256: String?) throws -> String {
        try body(artifact, encodedSignature, expectedSHA256)
    }
}

private struct AcceptingArtifactVerifier: UpdateArtifactVerifying {
    func verify(artifact: Data, encodedSignature: String, expectedSHA256: String?) throws -> String {
        SHA256.hash(data: artifact).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CreatingExtractor: UpdateArchiveExtracting {
    func extract(archiveURL: URL, destinationURL: URL) throws -> URL {
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false)
        let application = destinationURL.appendingPathComponent("CCBuddy.app", isDirectory: true)
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: false)
        return application
    }
}

private struct ReturningExtractor: UpdateArchiveExtracting {
    let applicationURL: URL
    func extract(archiveURL: URL, destinationURL: URL) throws -> URL { applicationURL }
}

private struct AcceptingApplicationVerifier: UpdateApplicationVerifying {
    func verify(applicationURL: URL, expectedVersion: UpdateSemanticVersion) throws
        -> VerifiedUpdateApplication
    {
        VerifiedUpdateApplication(
            bundleIdentifier: DeveloperIDUpdateVerifier.bundleIdentifier,
            version: expectedVersion,
            teamIdentifier: DeveloperIDUpdateVerifier.teamIdentifier
        )
    }
}

private struct ApplicationVerifierStub: UpdateApplicationVerifying {
    let body: @Sendable (URL, UpdateSemanticVersion) throws -> VerifiedUpdateApplication

    func verify(applicationURL: URL, expectedVersion: UpdateSemanticVersion) throws
        -> VerifiedUpdateApplication
    {
        try body(applicationURL, expectedVersion)
    }
}

private final class InstallerSpy: UpdateApplicationInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var counts = [Int](repeating: 0, count: 4)
    private let rollbackError: Error?

    init(rollbackError: Error? = nil) {
        self.rollbackError = rollbackError
    }

    var prepareCount: Int { count(0) }
    var commitCount: Int { count(1) }
    var rollbackCount: Int { count(2) }
    var discardCount: Int { count(3) }

    func prepare(stagedApplicationURL: URL, currentApplicationURL: URL) throws -> URL {
        increment(0)
        return currentApplicationURL.deletingLastPathComponent()
            .appendingPathComponent(".CCBuddy.update-test.app", isDirectory: true)
    }

    func commit(preparedApplicationURL: URL, currentApplicationURL: URL) throws -> URL {
        increment(1)
        return preparedApplicationURL
    }

    func rollback(backupApplicationURL: URL, currentApplicationURL: URL) throws {
        increment(2)
        if let rollbackError { throw rollbackError }
    }

    func discardPreparedApplication(at url: URL) { increment(3) }

    private func increment(_ index: Int) {
        lock.lock()
        counts[index] += 1
        lock.unlock()
    }

    private func count(_ index: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[index]
    }
}

private final class RelaunchSchedulerSpy: UpdateRelaunchScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var storedApplicationURL: URL?
    private var storedProcessID: Int32?

    var applicationURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return storedApplicationURL
    }

    var processID: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return storedProcessID
    }

    func scheduleRelaunch(of applicationURL: URL, afterProcess processID: Int32) throws {
        lock.lock()
        storedApplicationURL = applicationURL
        storedProcessID = processID
        lock.unlock()
    }
}

@MainActor
private final class TerminationFlag {
    var value = false
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }
}

@MainActor
private final class UpdatePromptRecorder {
    let choice: UpdateRestartChoice
    private(set) var values: [UpdateRestartPrompt] = []

    init(choice: UpdateRestartChoice) {
        self.choice = choice
    }

    func respond(to prompt: UpdateRestartPrompt) -> UpdateRestartChoice {
        values.append(prompt)
        return choice
    }
}

private final class UpdateURLProtocolStub: URLProtocol {
    struct Response: Sendable {
        let statusCode: Int
        let data: Data
        var headers: [String: String] = [:]

        static func json(_ data: Data, statusCode: Int = 200) -> Response {
            Response(statusCode: statusCode, data: data, headers: ["Content-Type": "application/json"])
        }
    }

    private static let lock = NSLock()
    // Access is serialized by lock; the annotation makes that synchronization contract explicit
    // to complete strict-concurrency checking.
    nonisolated(unsafe) private static var storedHandler: (@Sendable (URLRequest) throws -> Response)?

    static func setHandler(_ handler: (@Sendable (URLRequest) throws -> Response)?) {
        lock.lock()
        storedHandler = handler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.storedHandler
        Self.lock.unlock()
        do {
            let handler = try XCTUnwrap(handler)
            let result = try handler(request)
            var headers = result.headers
            headers["Content-Length"] = String(result.data.count)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: result.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { }
}
