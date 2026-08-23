import AppKit
import Foundation
import XCTest
@testable import CCBuddy

@MainActor
final class SelfCheckRunnerTests: XCTestCase {
    func testEnvironmentGateRequiresExplicitIsolatedHomeAndAbsoluteOutput() throws {
        let root = try HistoryTestSupport.temporaryDirectory("selfcheck-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let userHome = root.appendingPathComponent("user", isDirectory: true)
        let defaultHome = userHome.appendingPathComponent(".ccbud", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultHome, withIntermediateDirectories: true)

        XCTAssertEqual(
            SelfCheckEnvironmentGate.evaluate(environment: [:], userHomeDirectory: userHome),
            .disabled
        )
        XCTAssertEqual(
            SelfCheckEnvironmentGate.evaluate(
                environment: ["CCBUD_SELFCHECK": "true"],
                userHomeDirectory: userHome
            ),
            .disabled
        )
        assertGateFailure(
            SelfCheckEnvironmentGate.evaluate(
                environment: ["CCBUD_SELFCHECK": "1"],
                userHomeDirectory: userHome
            ),
            code: .missingIsolatedHome
        )
        assertGateFailure(
            SelfCheckEnvironmentGate.evaluate(
                environment: ["CCBUD_SELFCHECK": "1", "CCBUD_HOME": "relative/home"],
                userHomeDirectory: userHome
            ),
            code: .relativeHome
        )
        assertGateFailure(
            SelfCheckEnvironmentGate.evaluate(
                environment: ["CCBUD_SELFCHECK": "1", "CCBUD_HOME": defaultHome.path],
                userHomeDirectory: userHome
            ),
            code: .unsafeHome
        )
        for unsafeHome in [
            userHome,
            userHome.appendingPathComponent(".claude", isDirectory: true),
            userHome.appendingPathComponent(".codex", isDirectory: true),
            userHome.appendingPathComponent("Documents", isDirectory: true),
            root,
            URL(fileURLWithPath: "/", isDirectory: true),
        ] {
            assertGateFailure(
                SelfCheckEnvironmentGate.evaluate(
                    environment: ["CCBUD_SELFCHECK": "1", "CCBUD_HOME": unsafeHome.path],
                    userHomeDirectory: userHome
                ),
                code: .unsafeHome
            )
        }
        assertGateFailure(
            SelfCheckEnvironmentGate.evaluate(
                environment: [
                    "CCBUD_SELFCHECK": "1",
                    "CCBUD_HOME": defaultHome.appendingPathComponent("selfcheck").path,
                ],
                userHomeDirectory: userHome
            ),
            code: .unsafeHome
        )
        assertGateFailure(
            SelfCheckEnvironmentGate.evaluate(
                environment: [
                    "CCBUD_SELFCHECK": "1",
                    "CCBUD_HOME": root.appendingPathComponent("isolated").path,
                    "CCBUD_SELFCHECK_OUT": "relative/report.json",
                ],
                userHomeDirectory: userHome
            ),
            code: .relativeOutput
        )
        assertGateFailure(
            SelfCheckEnvironmentGate.evaluate(
                environment: [
                    "CCBUD_SELFCHECK": "1",
                    "CCBUD_HOME": root.appendingPathComponent("isolated").path,
                    "CCBUD_SELFCHECK_OUT": root.appendingPathComponent("report.json").path,
                ],
                userHomeDirectory: userHome
            ),
            code: .unsafeOutput
        )

        let symlink = root.appendingPathComponent("linked-home")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: defaultHome)
        assertGateFailure(
            SelfCheckEnvironmentGate.evaluate(
                environment: ["CCBUD_SELFCHECK": "1", "CCBUD_HOME": symlink.path],
                userHomeDirectory: userHome
            ),
            code: .unsafeHome
        )

        let isolated = root.appendingPathComponent("isolated", isDirectory: true)
        let output = isolated.appendingPathComponent("reports/result.json")
        assertGateFailure(
            SelfCheckEnvironmentGate.evaluate(
                environment: [
                    "CCBUD_SELFCHECK": "1",
                    "CCBUD_HOME": isolated.path,
                    "CCBUD_SELFCHECK_OUT": isolated.path,
                ],
                userHomeDirectory: userHome
            ),
            code: .unsafeOutput
        )

        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outputEscape = isolated.appendingPathComponent("report-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: outputEscape, withDestinationURL: outside)
        assertGateFailure(
            SelfCheckEnvironmentGate.evaluate(
                environment: [
                    "CCBUD_SELFCHECK": "1",
                    "CCBUD_HOME": isolated.path,
                    "CCBUD_SELFCHECK_OUT": outputEscape.appendingPathComponent("result.json").path,
                ],
                userHomeDirectory: userHome
            ),
            code: .unsafeOutput
        )

        XCTAssertEqual(
            SelfCheckEnvironmentGate.evaluate(
                environment: [
                    "CCBUD_SELFCHECK": "1",
                    "CCBUD_HOME": "  \(isolated.path)  ",
                    "CCBUD_SELFCHECK_OUT": "  \(output.path)  ",
                ],
                userHomeDirectory: userHome
            ),
            .enabled(SelfCheckRequest(
                homeDirectory: isolated.resolvingSymlinksInPath().standardizedFileURL,
                outputURL: output.resolvingSymlinksInPath().standardizedFileURL
            ))
        )
    }

    func testSuccessfulReportIsSingleLineSortedAndRedactsSensitiveValues() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("selfcheck-redaction")
        defer { try? FileManager.default.removeItem(at: root) }
        let isolated = root.appendingPathComponent("isolated", isDirectory: true)
        let capture = OutputCapture()
        var dependencies = validDependencies(output: capture)
        dependencies.uiProbe = { self.validUISnapshot() }
        dependencies.gatewayProbe = SelfCheckGatewayProbe(
            start: {
                throw ProbeFailure(
                    "token=super-secret marker=deterministic-marker home=\(isolated.path)"
                )
            },
            health: { false },
            stop: {}
        )
        let runner = SelfCheckRunner(dependencies: dependencies)
        let result = await runner.run(
            request: SelfCheckRequest(homeDirectory: isolated, outputURL: nil),
            environment: [
                "CCBUD_HOME": isolated.path,
                "API_TOKEN": "super-secret",
            ],
            userHomeDirectory: root.appendingPathComponent("user")
        )

        XCTAssertEqual(result.exitCode, SelfCheckExitCode.success)
        XCTAssertTrue(result.report.success)
        XCTAssertEqual(result.report.requiredChecks.count, 5)
        XCTAssertTrue(result.report.requiredChecks.allSatisfy { $0.status == .passed })
        XCTAssertEqual(result.report.optionalChecks.first { $0.id == "ui_snapshot" }?.status, .passed)
        XCTAssertEqual(
            result.report.optionalChecks.first { $0.id == "gateway_lifecycle" }?.status,
            .failed
        )
        XCTAssertFalse(result.jsonLine.contains("\n"))
        XCTAssertFalse(result.jsonLine.contains("\r"))
        XCTAssertTrue(result.jsonLine.hasPrefix("{\"appVersion\":"))
        XCTAssertFalse(result.jsonLine.contains("super-secret"))
        XCTAssertFalse(result.jsonLine.contains("deterministic-marker"))
        XCTAssertFalse(result.jsonLine.contains(isolated.path))
        XCTAssertTrue(result.jsonLine.contains("<redacted>"))
        XCTAssertEqual(String(decoding: capture.standardOutput, as: UTF8.self), result.jsonLine + "\n")

        let decoded = try JSONDecoder().decode(SelfCheckReport.self, from: Data(result.jsonLine.utf8))
        XCTAssertEqual(decoded, result.report)
    }

    func testOnlyRequiredFailuresAffectOverallSuccessAndExitCode() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("selfcheck-exit")
        defer { try? FileManager.default.removeItem(at: root) }
        let request = SelfCheckRequest(homeDirectory: root.appendingPathComponent("isolated"), outputURL: nil)

        let optionalCapture = OutputCapture()
        var optionalDependencies = validDependencies(output: optionalCapture)
        optionalDependencies.gatewayProbe = SelfCheckGatewayProbe(
            start: {},
            health: { false },
            stop: {}
        )
        let optionalResult = await SelfCheckRunner(dependencies: optionalDependencies).run(
            request: request
        )
        XCTAssertEqual(optionalResult.exitCode, SelfCheckExitCode.success)
        XCTAssertTrue(optionalResult.report.success)

        let requiredCapture = OutputCapture()
        var requiredDependencies = validDependencies(output: requiredCapture)
        requiredDependencies.gatewayRequirement = .required
        requiredDependencies.gatewayProbe = SelfCheckGatewayProbe(
            start: {},
            health: { false },
            stop: {}
        )
        let requiredResult = await SelfCheckRunner(dependencies: requiredDependencies).run(
            request: request
        )
        XCTAssertEqual(requiredResult.exitCode, SelfCheckExitCode.requiredCheckFailed)
        XCTAssertFalse(requiredResult.report.success)
        XCTAssertEqual(
            requiredResult.report.requiredChecks.first { $0.id == "gateway_lifecycle" }?.status,
            .failed
        )

        let configCapture = OutputCapture()
        var configDependencies = validDependencies(output: configCapture)
        configDependencies.configProbe = { _, _ in
            SelfCheckConfigSnapshot(roundTripSucceeded: false, permissions: 0o644)
        }
        let configResult = await SelfCheckRunner(dependencies: configDependencies).run(
            request: request
        )
        XCTAssertEqual(configResult.exitCode, SelfCheckExitCode.requiredCheckFailed)
        XCTAssertFalse(configResult.report.success)

        let historyCapture = OutputCapture()
        var historyDependencies = validDependencies(output: historyCapture)
        historyDependencies.historyProbe = { _, _ in
            SelfCheckHistorySnapshot(
                discovered: true,
                parsed: true,
                sessionMarkerMatched: true,
                messageMarkerMatched: false
            )
        }
        let historyResult = await SelfCheckRunner(dependencies: historyDependencies).run(
            request: request
        )
        XCTAssertEqual(historyResult.exitCode, SelfCheckExitCode.requiredCheckFailed)
        XCTAssertFalse(historyResult.report.success)
        XCTAssertEqual(
            historyResult.report.requiredChecks.first { $0.id == "history_round_trip" }?.status,
            .failed
        )
    }

    func testGlobalDeadlineBoundsNonCooperativeProbeAndStillAttemptsGatewayStop() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("selfcheck-global-timeout")
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = OutputCapture()
        let lifecycle = GatewayLifecycleRecorder()
        var dependencies = validDependencies(output: capture)
        dependencies.timeoutPolicy = SelfCheckTimeoutPolicy(
            global: .milliseconds(30),
            probe: .seconds(2),
            gatewayStop: .milliseconds(100)
        )
        // Deliberately ignore task cancellation. The runner must finish from its timeout race
        // instead of waiting for structured concurrency to join this blocking operation.
        dependencies.bundleProbe = {
            Thread.sleep(forTimeInterval: 1)
            return SelfCheckBundleSnapshot(
                isMainApplicationBundle: true,
                bundleIdentifier: "dev.ccbud.gateway",
                shortVersion: "2.0.0",
                buildVersion: "1",
                architecture: "arm64"
            )
        }
        dependencies.gatewayRequirement = .required
        dependencies.gatewayProbe = SelfCheckGatewayProbe(
            start: { await lifecycle.recordStart() },
            health: { true },
            stop: { await lifecycle.recordStop() }
        )

        let startedAt = ContinuousClock.now
        let result = await SelfCheckRunner(dependencies: dependencies).run(
            request: SelfCheckRequest(
                homeDirectory: root.appendingPathComponent("isolated"),
                outputURL: nil
            )
        )
        let elapsed = startedAt.duration(to: .now)

        XCTAssertLessThan(elapsed, .milliseconds(500))
        XCTAssertEqual(result.exitCode, SelfCheckExitCode.requiredCheckFailed)
        XCTAssertEqual(
            result.report.requiredChecks.first { $0.id == "main_bundle" }?.status,
            .failed
        )
        XCTAssertTrue(
            result.report.requiredChecks.first { $0.id == "main_bundle" }?.detail
                .contains("timed out") == true
        )
        let lifecycleCounts = await lifecycle.counts()
        XCTAssertEqual(lifecycleCounts.start, 0)
        XCTAssertEqual(lifecycleCounts.stop, 1)
        let gateway = try XCTUnwrap(
            result.report.requiredChecks.first { $0.id == "gateway_lifecycle" }
        )
        XCTAssertEqual(gateway.status, .failed)
        XCTAssertEqual(gateway.values["stopped"], "true")
        XCTAssertTrue(gateway.detail.contains("global deadline"))
    }

    func testHangingGatewayStopIsAttemptedAndBounded() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("selfcheck-stop-timeout")
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = OutputCapture()
        let lifecycle = GatewayLifecycleRecorder()
        var dependencies = validDependencies(output: capture)
        dependencies.timeoutPolicy = SelfCheckTimeoutPolicy(
            global: .seconds(1),
            probe: .milliseconds(200),
            gatewayStop: .milliseconds(25)
        )
        dependencies.gatewayRequirement = .required
        dependencies.gatewayProbe = SelfCheckGatewayProbe(
            start: { await lifecycle.recordStart() },
            health: { true },
            stop: {
                await lifecycle.recordStop()
                try await Task.sleep(for: .seconds(30))
            }
        )

        let startedAt = ContinuousClock.now
        let result = await SelfCheckRunner(dependencies: dependencies).run(
            request: SelfCheckRequest(
                homeDirectory: root.appendingPathComponent("isolated"),
                outputURL: nil
            )
        )
        let elapsed = startedAt.duration(to: .now)

        XCTAssertLessThan(elapsed, .milliseconds(500))
        let lifecycleCounts = await lifecycle.counts()
        XCTAssertEqual(lifecycleCounts.start, 1)
        XCTAssertEqual(lifecycleCounts.stop, 1)
        let gateway = try XCTUnwrap(
            result.report.requiredChecks.first { $0.id == "gateway_lifecycle" }
        )
        XCTAssertEqual(gateway.status, .failed)
        XCTAssertEqual(gateway.values["stopped"], "false")
        XCTAssertTrue(gateway.detail.contains("gateway stop"))
        XCTAssertTrue(gateway.detail.contains("timed out"))
    }

    func testFilesystemAndIntegrityProbesRunOffMainThread() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("selfcheck-background-probes")
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = OutputCapture()
        let threads = ProbeThreadRecorder()
        var dependencies = validDependencies(output: capture)
        dependencies.bundleProbe = {
            threads.record("bundle", isMainThread: Thread.isMainThread)
            return SelfCheckBundleSnapshot(
                isMainApplicationBundle: true,
                bundleIdentifier: "dev.ccbud.gateway",
                shortVersion: "2.0.0",
                buildVersion: "1",
                architecture: "arm64"
            )
        }
        dependencies.bifrostProbe = {
            threads.record("bifrost", isMainThread: Thread.isMainThread)
            return SelfCheckBifrostSnapshot(
                exists: true,
                isRegularFile: true,
                executable: true,
                architecture: "arm64",
                sha256: SelfCheckRunner.expectedBifrostSHA256
            )
        }
        dependencies.configProbe = { _, _ in
            threads.record("config", isMainThread: Thread.isMainThread)
            return SelfCheckConfigSnapshot(roundTripSucceeded: true, permissions: 0o600)
        }
        dependencies.historyProbe = { _, _ in
            threads.record("history", isMainThread: Thread.isMainThread)
            return SelfCheckHistorySnapshot(
                discovered: true,
                parsed: true,
                sessionMarkerMatched: true,
                messageMarkerMatched: true
            )
        }

        let result = await SelfCheckRunner(dependencies: dependencies).run(
            request: SelfCheckRequest(
                homeDirectory: root.appendingPathComponent("isolated"),
                outputURL: nil
            )
        )

        XCTAssertEqual(result.exitCode, SelfCheckExitCode.success)
        XCTAssertEqual(Set(threads.names), Set(["bundle", "bifrost", "config", "history"]))
        XCTAssertTrue(threads.mainThreadValues.allSatisfy { !$0 })
    }

    func testUIValidatorRejectsInvalidContainmentAndPositionerGeometry() {
        let valid = validUISnapshot()
        XCTAssertTrue(SelfCheckUIValidator.evaluate(valid).0)
        let withinTolerance = SelfCheckUISnapshot(
            mainWindowFrame: valid.mainWindowFrame,
            statusItemFrame: valid.statusItemFrame,
            panelFrame: valid.panelFrame.map {
                SelfCheckFrame(
                    x: $0.x - SelfCheckUIValidator.geometryTolerance / 2,
                    y: $0.y,
                    width: $0.width,
                    height: $0.height
                )
            },
            visibleScreenFrame: valid.visibleScreenFrame,
            frontmostApplicationPID: 42
        )
        XCTAssertTrue(SelfCheckUIValidator.evaluate(withinTolerance).0)

        let invalidSnapshots: [(String, SelfCheckUISnapshot, String)] = [
            (
                "non-finite frame",
                SelfCheckUISnapshot(
                    mainWindowFrame: SelfCheckFrame(
                        x: .nan,
                        y: 100,
                        width: 800,
                        height: 600
                    ),
                    statusItemFrame: valid.statusItemFrame,
                    panelFrame: valid.panelFrame,
                    visibleScreenFrame: valid.visibleScreenFrame,
                    frontmostApplicationPID: 42
                ),
                "non-finite"
            ),
            (
                "non-positive frame",
                SelfCheckUISnapshot(
                    mainWindowFrame: valid.mainWindowFrame,
                    statusItemFrame: SelfCheckFrame(x: 1_800, y: 1_080, width: 0, height: 24),
                    panelFrame: valid.panelFrame,
                    visibleScreenFrame: valid.visibleScreenFrame,
                    frontmostApplicationPID: 42
                ),
                "non-positive"
            ),
            (
                "outside screen",
                SelfCheckUISnapshot(
                    mainWindowFrame: valid.mainWindowFrame,
                    statusItemFrame: valid.statusItemFrame,
                    panelFrame: SelfCheckFrame(x: 1_700, y: 900, width: 424, height: 344),
                    visibleScreenFrame: valid.visibleScreenFrame,
                    frontmostApplicationPID: 42
                ),
                "outside the visible screen"
            ),
            (
                "wrong position",
                SelfCheckUISnapshot(
                    mainWindowFrame: valid.mainWindowFrame,
                    statusItemFrame: valid.statusItemFrame,
                    panelFrame: valid.panelFrame.map {
                        SelfCheckFrame(
                            x: $0.x - SelfCheckUIValidator.geometryTolerance - 1,
                            y: $0.y,
                            width: $0.width,
                            height: $0.height
                        )
                    },
                    visibleScreenFrame: valid.visibleScreenFrame,
                    frontmostApplicationPID: 42
                ),
                "positioner geometry"
            ),
            (
                "missing frontmost PID",
                SelfCheckUISnapshot(
                    mainWindowFrame: valid.mainWindowFrame,
                    statusItemFrame: valid.statusItemFrame,
                    panelFrame: valid.panelFrame,
                    visibleScreenFrame: valid.visibleScreenFrame,
                    frontmostApplicationPID: nil
                ),
                "PID is missing"
            ),
        ]

        for (name, snapshot, expectedDetail) in invalidSnapshots {
            let evaluation = SelfCheckUIValidator.evaluate(snapshot)
            XCTAssertFalse(evaluation.0, name)
            XCTAssertTrue(evaluation.1.contains(expectedDetail), "\(name): \(evaluation.1)")
        }
    }

    func testRejectedGateReturnsNonzeroReportWithoutRunningMutatingProbes() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("selfcheck-rejected")
        defer { try? FileManager.default.removeItem(at: root) }
        let userHome = root.appendingPathComponent("user", isDirectory: true)
        let capture = OutputCapture()
        let mutations = MutationRecorder()
        var dependencies = validDependencies(output: capture)
        dependencies.configProbe = { _, _ in
            mutations.recordConfig()
            return SelfCheckConfigSnapshot(roundTripSucceeded: true, permissions: 0o600)
        }
        dependencies.historyProbe = { _, _ in
            mutations.recordHistory()
            return SelfCheckHistorySnapshot(
                discovered: true,
                parsed: true,
                sessionMarkerMatched: true,
                messageMarkerMatched: true
            )
        }

        let outcome = await SelfCheckRunner(dependencies: dependencies).runIfRequested(
            environment: [
                "CCBUD_SELFCHECK": "1",
                "CCBUD_HOME": userHome.appendingPathComponent(".ccbud").path,
            ],
            userHomeDirectory: userHome
        )
        guard case .completed(let result) = outcome else {
            XCTFail("Expected a rejected self-check report")
            return
        }
        XCTAssertFalse(mutations.configMutated)
        XCTAssertFalse(mutations.historyMutated)
        XCTAssertEqual(result.exitCode, SelfCheckExitCode.unsafeEnvironment)
        XCTAssertFalse(result.report.success)
        XCTAssertEqual(result.report.requiredChecks.map(\.id), ["environment_gate"])
    }

    func testReportFileIsAtomicSingleLineAndOwnerOnly() async throws {
        let root = try HistoryTestSupport.temporaryDirectory("selfcheck-output")
        defer { try? FileManager.default.removeItem(at: root) }
        let isolated = root.appendingPathComponent("isolated", isDirectory: true)
        let output = isolated.appendingPathComponent("nested/report.json")
        let capture = OutputCapture()
        var dependencies = validDependencies(output: capture)
        dependencies.writeReportFile = { data, destination in
            try SelfCheckReportFileWriter.write(data, to: destination)
        }
        let result = await SelfCheckRunner(dependencies: dependencies).run(
            request: SelfCheckRequest(
                homeDirectory: isolated,
                outputURL: output
            )
        )

        XCTAssertEqual(result.exitCode, SelfCheckExitCode.success)
        let data = try Data(contentsOf: output)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), result.jsonLine + "\n")
        XCTAssertEqual(data.filter { $0 == 0x0A }.count, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
    }

    func testSystemConfigAndNamedClipboardProbesRoundTripWithoutUserFixtures() throws {
        let root = try HistoryTestSupport.temporaryDirectory("selfcheck-system-probes")
        defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = NSPasteboard(name: .init("dev.ccbud.selfcheck.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original clipboard", forType: .string))
        let dependencies = SelfCheckDependencies.live(pasteboard: pasteboard)

        let isolated = root.appendingPathComponent("isolated")
        let config = try dependencies.configProbe(isolated, "marker")
        XCTAssertTrue(config.roundTripSucceeded)
        XCTAssertEqual(config.permissions.map { $0 & 0o777 }, 0o600)

        let history = try dependencies.historyProbe(isolated, "history-marker")
        XCTAssertTrue(history.discovered)
        XCTAssertTrue(history.parsed)
        XCTAssertTrue(history.sessionMarkerMatched)
        XCTAssertTrue(history.messageMarkerMatched)
        let selfCheckEntries = try FileManager.default.contentsOfDirectory(
            at: isolated,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(selfCheckEntries.contains {
            $0.lastPathComponent.hasPrefix(".ccbud-selfcheck-")
        })

        let clipboard = try dependencies.clipboardProbe("unique-marker")
        XCTAssertTrue(clipboard.writeSucceeded)
        XCTAssertTrue(clipboard.readBackSucceeded)
        XCTAssertTrue(clipboard.restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "original clipboard")
    }

    private func assertGateFailure(
        _ decision: SelfCheckGateDecision,
        code: SelfCheckGateFailure.Code,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .rejected(let failure, _) = decision else {
            XCTFail("Expected rejected gate, got \(decision)", file: file, line: line)
            return
        }
        XCTAssertEqual(failure.code, code, file: file, line: line)
    }

    private func validUISnapshot() -> SelfCheckUISnapshot {
        let status = NSRect(x: 1_800, y: 1_080, width: 24, height: 24)
        let screen = NSRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let panel = MenuBarPanelPositioner.frame(anchor: status, visibleFrame: screen)
        return SelfCheckUISnapshot(
            mainWindowFrame: SelfCheckFrame(x: 100, y: 100, width: 800, height: 600),
            statusItemFrame: SelfCheckFrame(status),
            panelFrame: SelfCheckFrame(panel),
            visibleScreenFrame: SelfCheckFrame(screen),
            frontmostApplicationPID: 42
        )
    }

    private func validDependencies(output: OutputCapture) -> SelfCheckDependencies {
        SelfCheckDependencies(
            now: { Date(timeIntervalSince1970: 1_700_000_000.125) },
            marker: { "deterministic-marker" },
            bundleProbe: {
                SelfCheckBundleSnapshot(
                    isMainApplicationBundle: true,
                    bundleIdentifier: "dev.ccbud.gateway",
                    shortVersion: "2.0.0",
                    buildVersion: "1",
                    architecture: "arm64"
                )
            },
            bifrostProbe: {
                SelfCheckBifrostSnapshot(
                    exists: true,
                    isRegularFile: true,
                    executable: true,
                    architecture: "arm64",
                    sha256: SelfCheckRunner.expectedBifrostSHA256
                )
            },
            configProbe: { _, _ in
                SelfCheckConfigSnapshot(roundTripSucceeded: true, permissions: 0o600)
            },
            historyProbe: { _, _ in
                SelfCheckHistorySnapshot(
                    discovered: true,
                    parsed: true,
                    sessionMarkerMatched: true,
                    messageMarkerMatched: true
                )
            },
            clipboardProbe: { _ in
                SelfCheckClipboardSnapshot(
                    writeSucceeded: true,
                    readBackSucceeded: true,
                    restored: true
                )
            },
            uiProbe: nil,
            uiRequirement: .optional,
            gatewayProbe: nil,
            gatewayRequirement: .optional,
            timeoutPolicy: SelfCheckTimeoutPolicy(
                global: .seconds(2),
                probe: .seconds(1),
                gatewayStop: .seconds(1)
            ),
            writeReportFile: { _, _ in },
            writeStandardOutput: { output.standardOutput.append($0) }
        )
    }
}

@MainActor
private final class OutputCapture {
    var standardOutput = Data()
}

private struct ProbeFailure: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private actor GatewayLifecycleRecorder {
    private var startCount = 0
    private var stopCount = 0

    func recordStart() { startCount += 1 }
    func recordStop() { stopCount += 1 }
    func counts() -> (start: Int, stop: Int) { (startCount, stopCount) }
}

private final class MutationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var didMutateConfig = false
    private var didMutateHistory = false

    var configMutated: Bool { lock.withLock { didMutateConfig } }
    var historyMutated: Bool { lock.withLock { didMutateHistory } }

    func recordConfig() {
        lock.withLock { didMutateConfig = true }
    }

    func recordHistory() {
        lock.withLock { didMutateHistory = true }
    }
}

private final class ProbeThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(String, Bool)] = []

    var names: [String] { lock.withLock { records.map(\.0) } }
    var mainThreadValues: [Bool] { lock.withLock { records.map(\.1) } }

    func record(_ name: String, isMainThread: Bool) {
        lock.withLock { records.append((name, isMainThread)) }
    }
}
