import AppKit
import CryptoKit
import Darwin
import Foundation

enum SelfCheckExitCode {
    static let success: Int32 = 0
    static let requiredCheckFailed: Int32 = 1
    static let unsafeEnvironment: Int32 = 2
    static let reportEmissionFailed: Int32 = 3
}

enum SelfCheckCheckStatus: String, Codable, Equatable, Sendable {
    case passed
    case failed
    case skipped
}

enum SelfCheckProbeRequirement: String, Codable, Equatable, Sendable {
    case required
    case optional
}

struct SelfCheckCheckReport: Codable, Equatable, Sendable {
    let id: String
    let status: SelfCheckCheckStatus
    let detail: String
    let values: [String: String]
}

struct SelfCheckReport: Codable, Equatable, Sendable {
    static let currentSchema = "dev.ccbud.self-check"
    static let currentVersion = 1

    let schema: String
    let version: Int
    let timestamp: String
    let appVersion: String
    var requiredChecks: [SelfCheckCheckReport]
    var optionalChecks: [SelfCheckCheckReport]
    var success: Bool
}

struct SelfCheckExecution: Equatable, Sendable {
    let report: SelfCheckReport
    /// Sorted-key JSON without a trailing newline. The output sink receives exactly this plus LF.
    let jsonLine: String
    let exitCode: Int32
}

enum SelfCheckLaunchResult: Equatable, Sendable {
    case disabled
    case completed(SelfCheckExecution)
}

struct SelfCheckRequest: Equatable, Sendable {
    let homeDirectory: URL
    let outputURL: URL?
}

struct SelfCheckGateFailure: Error, Equatable, Sendable {
    enum Code: String, Codable, Equatable, Sendable {
        case missingIsolatedHome = "missing_isolated_home"
        case relativeHome = "relative_home"
        case unsafeHome = "unsafe_home"
        case relativeOutput = "relative_output"
        case unsafeOutput = "unsafe_output"
    }

    let code: Code
    let message: String
}

enum SelfCheckGateDecision: Equatable, Sendable {
    case disabled
    case enabled(SelfCheckRequest)
    case rejected(SelfCheckGateFailure, outputURL: URL?)
}

enum SelfCheckEnvironmentGate {
    static let enabledKey = "CCBUD_SELFCHECK"
    static let outputKey = "CCBUD_SELFCHECK_OUT"
    static let homeKey = "CCBUD_HOME"

    static func evaluate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> SelfCheckGateDecision {
        guard environment[enabledKey] == "1" else { return .disabled }

        let requestedOutputURL: URL?
        if let rawOutput = trimmed(environment[outputKey]), !rawOutput.isEmpty {
            guard rawOutput.hasPrefix("/") else {
                return .rejected(
                    SelfCheckGateFailure(
                        code: .relativeOutput,
                        message: "CCBUD_SELFCHECK_OUT must be an absolute file path"
                    ),
                    outputURL: nil
                )
            }
            requestedOutputURL = URL(fileURLWithPath: rawOutput).standardizedFileURL
        } else {
            requestedOutputURL = nil
        }

        let userHome = userHomeDirectory.standardizedFileURL
        let canonicalUserHome = canonicalizingExistingPrefix(userHome)

        guard let rawHome = trimmed(environment[homeKey]), !rawHome.isEmpty else {
            return .rejected(
                SelfCheckGateFailure(
                        code: .missingIsolatedHome,
                        message: "Self-check requires an explicit isolated CCBUD_HOME"
                    ),
                outputURL: nil
            )
        }
        guard rawHome.hasPrefix("/") else {
            return .rejected(
                SelfCheckGateFailure(
                        code: .relativeHome,
                        message: "Self-check CCBUD_HOME must be an absolute path"
                    ),
                outputURL: nil
            )
        }

        let requestedHome = URL(fileURLWithPath: rawHome, isDirectory: true).standardizedFileURL
        let canonicalRequested = canonicalizingExistingPrefix(requestedHome)

        // The probes create directories, chmod files, and launch a helper. An "isolated" root
        // therefore cannot be the filesystem root, any part of the user's real home tree, or a
        // broad ancestor that contains the real home. Check both the spelling supplied by the
        // caller and the symlink-resolved spelling before performing any mutation.
        let unsafe = canonicalRequested.path == "/"
            || pathsIntersect(requestedHome, userHome)
            || pathsIntersect(canonicalRequested, canonicalUserHome)
        guard !unsafe else {
            return .rejected(
                SelfCheckGateFailure(
                    code: .unsafeHome,
                    message: "Self-check requires a dedicated root outside the real user home tree"
                ),
                outputURL: nil
            )
        }

        let canonicalOutput: URL?
        if let requestedOutputURL {
            let resolvedOutput = canonicalizingExistingPrefix(requestedOutputURL)
            guard isStrictDescendant(requestedOutputURL, of: requestedHome),
                  isStrictDescendant(resolvedOutput, of: canonicalRequested) else {
                return .rejected(
                    SelfCheckGateFailure(
                        code: .unsafeOutput,
                        message: "Self-check report output must stay inside the isolated CCBUD_HOME"
                    ),
                    outputURL: nil
                )
            }
            canonicalOutput = resolvedOutput
        } else {
            canonicalOutput = nil
        }

        return .enabled(SelfCheckRequest(
            homeDirectory: canonicalRequested,
            outputURL: canonicalOutput
        ))
    }

    private static func trimmed(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isEqualOrDescendant(_ child: URL, of root: URL) -> Bool {
        let childComponents = child.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        return childComponents.count >= rootComponents.count
            && childComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    private static func isStrictDescendant(_ child: URL, of root: URL) -> Bool {
        let childComponents = child.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        return childComponents.count > rootComponents.count
            && childComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    private static func pathsIntersect(_ lhs: URL, _ rhs: URL) -> Bool {
        isEqualOrDescendant(lhs, of: rhs) || isEqualOrDescendant(rhs, of: lhs)
    }

    /// `resolvingSymlinksInPath()` does not reliably resolve an intermediate symlink when the
    /// final report file does not exist yet. Resolve the deepest existing path component first,
    /// then append the still-missing suffix so containment checks cannot be bypassed that way.
    private static func canonicalizingExistingPrefix(_ input: URL) -> URL {
        var cursor = input.standardizedFileURL
        var suffix: [String] = []
        while cursor.path != "/" {
            var metadata = stat()
            if cursor.path.withCString({ Darwin.lstat($0, &metadata) }) == 0 { break }
            suffix.insert(cursor.lastPathComponent, at: 0)
            cursor.deleteLastPathComponent()
        }
        var resolved = cursor.resolvingSymlinksInPath().standardizedFileURL
        for component in suffix {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }
}

struct SelfCheckFrame: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var reportValue: String {
        [x, y, width, height].map { String(format: "%.1f", $0) }.joined(separator: ",")
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var isFiniteAndPositive: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && width > 0 && height > 0
    }
}

struct SelfCheckUISnapshot: Codable, Equatable, Sendable {
    let mainWindowFrame: SelfCheckFrame?
    let statusItemFrame: SelfCheckFrame?
    let panelFrame: SelfCheckFrame?
    let visibleScreenFrame: SelfCheckFrame?
    let frontmostApplicationPID: Int32?
}

struct SelfCheckBundleSnapshot: Equatable, Sendable {
    let isMainApplicationBundle: Bool
    let bundleIdentifier: String?
    let shortVersion: String?
    let buildVersion: String?
    let architecture: String
}

/// One Mach-O slice of the bundled helper.
///
/// A universal helper is two published downloads joined by lipo, so the file as a whole has a
/// digest that nobody upstream ever published and that could not be pinned. Each slice, on the
/// other hand, is exactly the bytes that were downloaded.
struct SelfCheckMachOSlice: Equatable, Sendable {
    let architecture: String
    let sha256: String
}

struct SelfCheckBifrostSnapshot: Equatable, Sendable {
    let exists: Bool
    let isRegularFile: Bool
    let executable: Bool
    let slices: [SelfCheckMachOSlice]
}

struct SelfCheckConfigSnapshot: Equatable, Sendable {
    let roundTripSucceeded: Bool
    let permissions: Int?
}

struct SelfCheckHistorySnapshot: Equatable, Sendable {
    let discovered: Bool
    let parsed: Bool
    let sessionMarkerMatched: Bool
    let messageMarkerMatched: Bool
}

struct SelfCheckClipboardSnapshot: Equatable, Sendable {
    let writeSucceeded: Bool
    let readBackSucceeded: Bool
    let restored: Bool
}

typealias SelfCheckClipboardProbe = @MainActor @Sendable (String) throws -> SelfCheckClipboardSnapshot
typealias SelfCheckUIProbe = @MainActor @Sendable () async throws -> SelfCheckUISnapshot
typealias SelfCheckBundleProbe = @Sendable () throws -> SelfCheckBundleSnapshot
typealias SelfCheckBifrostProbe = @Sendable () throws -> SelfCheckBifrostSnapshot
typealias SelfCheckConfigProbe = @Sendable (URL, String) throws -> SelfCheckConfigSnapshot
typealias SelfCheckHistoryProbe = @Sendable (URL, String) throws -> SelfCheckHistorySnapshot

struct SelfCheckTimeoutPolicy: Equatable, Sendable {
    /// All ordinary probes share this wall-clock budget. Gateway cleanup deliberately receives a
    /// separate, bounded allowance so reaching the deadline can never suppress the stop attempt.
    var global: Duration
    var probe: Duration
    var gatewayStop: Duration

    static let live = SelfCheckTimeoutPolicy(
        global: .seconds(90),
        probe: .seconds(65),
        gatewayStop: .seconds(5)
    )
}

struct SelfCheckGatewayProbe: Sendable {
    var start: @MainActor @Sendable () async throws -> Void
    var health: @MainActor @Sendable () async throws -> Bool
    var stop: @MainActor @Sendable () async throws -> Void
}

@MainActor
struct SelfCheckDependencies {
    var now: () -> Date
    var marker: () -> String
    var bundleProbe: SelfCheckBundleProbe
    var bifrostProbe: SelfCheckBifrostProbe
    var configProbe: SelfCheckConfigProbe
    var historyProbe: SelfCheckHistoryProbe
    var clipboardProbe: SelfCheckClipboardProbe
    var uiProbe: SelfCheckUIProbe?
    var uiRequirement: SelfCheckProbeRequirement
    var gatewayProbe: SelfCheckGatewayProbe?
    var gatewayRequirement: SelfCheckProbeRequirement
    var timeoutPolicy: SelfCheckTimeoutPolicy
    var writeReportFile: (Data, URL) throws -> Void
    var writeStandardOutput: (Data) throws -> Void

    static func live(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        pasteboard: NSPasteboard = .general,
        uiProbe: SelfCheckUIProbe? = nil,
        uiRequirement: SelfCheckProbeRequirement = .optional,
        gatewayProbe: SelfCheckGatewayProbe? = nil,
        gatewayRequirement: SelfCheckProbeRequirement = .optional
    ) -> SelfCheckDependencies {
        // Foundation's Bundle and FileManager APIs used here are safe for concurrent reads, but
        // neither dependency needs to cross isolation directly. The immutable boxes make that
        // boundary explicit while the actual probes execute on utility tasks.
        let bundleBox = SelfCheckSendableBox(bundle)
        let fileManagerBox = SelfCheckSendableBox(fileManager)
        return SelfCheckDependencies(
            now: Date.init,
            marker: { "ccbud-selfcheck-\(UUID().uuidString)" },
            bundleProbe: { SelfCheckSystemProbe.bundle(bundleBox.value) },
            bifrostProbe: {
                try SelfCheckSystemProbe.bifrost(
                    bundle: bundleBox.value,
                    fileManager: fileManagerBox.value
                )
            },
            configProbe: { home, marker in
                try SelfCheckSystemProbe.configRoundTrip(
                    homeDirectory: home,
                    marker: marker,
                    fileManager: fileManagerBox.value
                )
            },
            historyProbe: { home, marker in
                try SelfCheckSystemProbe.historyRoundTrip(
                    homeDirectory: home,
                    marker: marker,
                    fileManager: fileManagerBox.value
                )
            },
            clipboardProbe: { marker in
                SelfCheckSystemProbe.clipboardRoundTrip(marker: marker, pasteboard: pasteboard)
            },
            uiProbe: uiProbe,
            uiRequirement: uiRequirement,
            gatewayProbe: gatewayProbe,
            gatewayRequirement: gatewayRequirement,
            timeoutPolicy: .live,
            writeReportFile: { data, destination in
                try SelfCheckReportFileWriter.write(
                    data,
                    to: destination,
                    fileManager: fileManagerBox.value
                )
            },
            writeStandardOutput: { data in try FileHandle.standardOutput.write(contentsOf: data) }
        )
    }
}

@MainActor
struct SelfCheckRunner {
    /// The pinned digest of each shipped slice, matching `native/Scripts/verify-bifrost.sh`.
    /// Intel is the deterministic, notarization-compatible normalization of the upstream binary.
    nonisolated static let expectedBifrostSliceSHA256: [String: String] = [
        "arm64": "422eea68b860dd069d1b9989ff494a7bc566b7e11920632624cb6e85ca2c5263",
        "x86_64": "cff62f56fc2bb8274f0b5eb97e663d6d1db953fcd710bb9ef9add1b7d27f75b3",
    ]

    var dependencies: SelfCheckDependencies

    static func live(
        uiProbe: SelfCheckUIProbe? = nil,
        uiRequirement: SelfCheckProbeRequirement = .optional,
        gatewayProbe: SelfCheckGatewayProbe? = nil,
        gatewayRequirement: SelfCheckProbeRequirement = .optional
    ) -> SelfCheckRunner {
        SelfCheckRunner(dependencies: .live(
            uiProbe: uiProbe,
            uiRequirement: uiRequirement,
            gatewayProbe: gatewayProbe,
            gatewayRequirement: gatewayRequirement
        ))
    }

    func runIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> SelfCheckLaunchResult {
        let gate = SelfCheckEnvironmentGate.evaluate(
            environment: environment,
            userHomeDirectory: userHomeDirectory
        )
        switch gate {
        case .disabled:
            return .disabled
        case .rejected(let failure, let outputURL):
            let redactor = SelfCheckRedactor(
                environment: environment,
                userHomeDirectory: userHomeDirectory,
                request: nil
            )
            let check = SelfCheckCheckReport(
                id: "environment_gate",
                status: .failed,
                detail: redactor.redact(failure.message),
                values: ["code": failure.code.rawValue]
            )
            return .completed(finalize(
                appVersion: "unknown",
                required: [check],
                optional: [],
                outputURL: outputURL,
                baseFailureExitCode: SelfCheckExitCode.unsafeEnvironment,
                redactor: redactor
            ))
        case .enabled(let request):
            return .completed(await run(
                request: request,
                environment: environment,
                userHomeDirectory: userHomeDirectory
            ))
        }
    }

    func run(
        request: SelfCheckRequest,
        environment: [String: String] = [:],
        userHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> SelfCheckExecution {
        let gateRedactor = SelfCheckRedactor(
            environment: environment,
            userHomeDirectory: userHomeDirectory,
            request: request
        )
        var validationEnvironment = [
            SelfCheckEnvironmentGate.enabledKey: "1",
            SelfCheckEnvironmentGate.homeKey: request.homeDirectory.path,
        ]
        if let outputURL = request.outputURL {
            validationEnvironment[SelfCheckEnvironmentGate.outputKey] = outputURL.path
        }
        let validationDecision = SelfCheckEnvironmentGate.evaluate(
            environment: validationEnvironment,
            userHomeDirectory: userHomeDirectory
        )
        guard case .enabled(let validatedRequest) = validationDecision else {
            let failure: SelfCheckGateFailure
            if case .rejected(let rejectedFailure, _) = validationDecision {
                failure = rejectedFailure
            } else {
                failure = SelfCheckGateFailure(
                    code: .unsafeHome,
                    message: "Self-check request does not use an isolated home"
                )
            }
            return finalize(
                appVersion: "unknown",
                required: [SelfCheckCheckReport(
                    id: "environment_gate",
                    status: .failed,
                    detail: gateRedactor.redact(failure.message),
                    values: ["code": failure.code.rawValue]
                )],
                optional: [],
                // A rejected destination is never used to emit the rejection report.
                outputURL: nil,
                baseFailureExitCode: SelfCheckExitCode.unsafeEnvironment,
                redactor: gateRedactor
            )
        }
        // Validation canonicalizes both paths. Use only those canonical values for every live
        // probe so whitespace or symlink spellings cannot send different components elsewhere.
        let request = validatedRequest
        let marker = dependencies.marker()
        let redactor = SelfCheckRedactor(
            environment: environment,
            userHomeDirectory: userHomeDirectory,
            request: request,
            additionalSecrets: [marker]
        )
        var required: [SelfCheckCheckReport] = []
        var optional: [SelfCheckCheckReport] = []
        var appVersion = "unknown"
        let deadline = ContinuousClock.now.advanced(by: dependencies.timeoutPolicy.global)

        do {
            let snapshot = try await runBackgroundProbe(
                id: "main_bundle",
                deadline: deadline,
                operation: dependencies.bundleProbe
            )
            appVersion = snapshot.shortVersion ?? "unknown"
            let passed = snapshot.isMainApplicationBundle
                && !(snapshot.bundleIdentifier ?? "").isEmpty
                && !(snapshot.shortVersion ?? "").isEmpty
                && !(snapshot.buildVersion ?? "").isEmpty
                // Either slice of the universal build is a valid thing to be running.
                && ["arm64", "x86_64"].contains(snapshot.architecture)
            required.append(check(
                id: "main_bundle",
                passed: passed,
                detail: passed ? "main application bundle metadata is valid" : "invalid bundle, version, or architecture",
                values: [
                    "bundleIdentifier": snapshot.bundleIdentifier ?? "missing",
                    "shortVersion": snapshot.shortVersion ?? "missing",
                    "buildVersion": snapshot.buildVersion ?? "missing",
                    "architecture": snapshot.architecture,
                ],
                redactor: redactor
            ))
        } catch {
            required.append(failedCheck(id: "main_bundle", error: error, redactor: redactor))
        }

        do {
            let snapshot = try await runBackgroundProbe(
                id: "bundled_bifrost",
                deadline: deadline,
                operation: dependencies.bifrostProbe
            )
            let digests = Dictionary(
                snapshot.slices.map { ($0.architecture, $0.sha256) },
                uniquingKeysWith: { first, _ in first }
            )
            let passed = snapshot.exists && snapshot.isRegularFile && snapshot.executable
                && snapshot.slices.count == Self.expectedBifrostSliceSHA256.count
                && digests == Self.expectedBifrostSliceSHA256
            var values = [
                "exists": String(snapshot.exists),
                "regularFile": String(snapshot.isRegularFile),
                "executable": String(snapshot.executable),
                "architectures": snapshot.slices.isEmpty
                    ? "missing"
                    : snapshot.slices.map(\.architecture).sorted().joined(separator: "+"),
            ]
            for slice in snapshot.slices { values["sha256.\(slice.architecture)"] = slice.sha256 }
            required.append(check(
                id: "bundled_bifrost",
                passed: passed,
                detail: passed
                    ? "bundled bifrost-http matches the pinned universal artifact"
                    : "bundled bifrost-http failed integrity checks",
                values: values,
                redactor: redactor
            ))
        } catch {
            required.append(failedCheck(id: "bundled_bifrost", error: error, redactor: redactor))
        }

        do {
            let configProbe = dependencies.configProbe
            let homeDirectory = request.homeDirectory
            let snapshot = try await runBackgroundProbe(
                id: "config_atomic_round_trip",
                deadline: deadline
            ) {
                try configProbe(homeDirectory, marker)
            }
            let passed = snapshot.roundTripSucceeded && snapshot.permissions == 0o600
            required.append(check(
                id: "config_atomic_round_trip",
                passed: passed,
                detail: passed ? "secure atomic config round-trip succeeded" : "config round-trip or mode check failed",
                values: [
                    "roundTrip": String(snapshot.roundTripSucceeded),
                    "permissions": snapshot.permissions.map { String(format: "%04o", $0) } ?? "missing",
                ],
                redactor: redactor
            ))
        } catch {
            required.append(failedCheck(
                id: "config_atomic_round_trip",
                error: error,
                redactor: redactor
            ))
        }

        do {
            let historyProbe = dependencies.historyProbe
            let homeDirectory = request.homeDirectory
            let snapshot = try await runBackgroundProbe(
                id: "history_round_trip",
                deadline: deadline
            ) {
                try historyProbe(homeDirectory, marker)
            }
            let passed = snapshot.discovered
                && snapshot.parsed
                && snapshot.sessionMarkerMatched
                && snapshot.messageMarkerMatched
            required.append(check(
                id: "history_round_trip",
                passed: passed,
                detail: passed
                    ? "isolated synthetic history discovery and parse round-trip succeeded"
                    : "history discovery, parse, or marker verification failed",
                values: [
                    "discovered": String(snapshot.discovered),
                    "parsed": String(snapshot.parsed),
                    "sessionMarker": String(snapshot.sessionMarkerMatched),
                    "messageMarker": String(snapshot.messageMarkerMatched),
                ],
                redactor: redactor
            ))
        } catch {
            required.append(failedCheck(id: "history_round_trip", error: error, redactor: redactor))
        }

        do {
            let clipboardProbe = dependencies.clipboardProbe
            let snapshot = try await runMainActorProbe(
                id: "clipboard_round_trip",
                deadline: deadline
            ) {
                try clipboardProbe(marker)
            }
            let passed = snapshot.writeSucceeded && snapshot.readBackSucceeded && snapshot.restored
            required.append(check(
                id: "clipboard_round_trip",
                passed: passed,
                detail: passed ? "unique clipboard marker round-trip and restoration succeeded" : "clipboard write, read-back, or restoration failed",
                values: [
                    "write": String(snapshot.writeSucceeded),
                    "readBack": String(snapshot.readBackSucceeded),
                    "restored": String(snapshot.restored),
                ],
                redactor: redactor
            ))
        } catch {
            required.append(failedCheck(id: "clipboard_round_trip", error: error, redactor: redactor))
        }

        let uiCheck = await evaluateOptionalProbe(
            id: "ui_snapshot",
            requirement: dependencies.uiRequirement,
            probe: dependencies.uiProbe,
            deadline: deadline,
            redactor: redactor
        ) { snapshot in
            SelfCheckUIValidator.evaluate(snapshot)
        }
        append(uiCheck, requirement: dependencies.uiRequirement, required: &required, optional: &optional)

        let gatewayCheck = await evaluateGatewayProbe(
            requirement: dependencies.gatewayRequirement,
            probe: dependencies.gatewayProbe,
            deadline: deadline,
            redactor: redactor
        )
        append(
            gatewayCheck,
            requirement: dependencies.gatewayRequirement,
            required: &required,
            optional: &optional
        )

        return finalize(
            appVersion: appVersion,
            required: required,
            optional: optional,
            outputURL: request.outputURL,
            baseFailureExitCode: SelfCheckExitCode.requiredCheckFailed,
            redactor: redactor
        )
    }

    private func evaluateOptionalProbe<Snapshot>(
        id: String,
        requirement: SelfCheckProbeRequirement,
        probe: (@MainActor @Sendable () async throws -> Snapshot)?,
        deadline: ContinuousClock.Instant,
        redactor: SelfCheckRedactor,
        evaluate: (Snapshot) -> (Bool, String, [String: String])
    ) async -> SelfCheckCheckReport where Snapshot: Sendable {
        guard let probe else {
            return SelfCheckCheckReport(
                id: id,
                status: requirement == .required ? .failed : .skipped,
                detail: requirement == .required ? "required probe is not installed" : "probe is not installed",
                values: [:]
            )
        }
        do {
            let snapshot = try await runMainActorProbe(
                id: id,
                deadline: deadline,
                operation: probe
            )
            let result = evaluate(snapshot)
            return check(
                id: id,
                passed: result.0,
                detail: result.1,
                values: result.2,
                redactor: redactor
            )
        } catch {
            return failedCheck(id: id, error: error, redactor: redactor)
        }
    }

    private func evaluateGatewayProbe(
        requirement: SelfCheckProbeRequirement,
        probe: SelfCheckGatewayProbe?,
        deadline: ContinuousClock.Instant,
        redactor: SelfCheckRedactor
    ) async -> SelfCheckCheckReport {
        guard let probe else {
            return SelfCheckCheckReport(
                id: "gateway_lifecycle",
                status: requirement == .required ? .failed : .skipped,
                detail: requirement == .required ? "required probe is not installed" : "probe is not installed",
                values: [:]
            )
        }

        var started = false
        var healthy = false
        var stopped = false
        var failures: [String] = []
        do {
            try await runMainActorProbe(
                id: "gateway start",
                deadline: deadline,
                operation: probe.start
            )
            started = true
            healthy = try await runMainActorProbe(
                id: "gateway health",
                deadline: deadline,
                operation: probe.health
            )
            if !healthy { failures.append("gateway health probe returned false") }
        } catch {
            failures.append(error.localizedDescription)
        }
        // Always ask the injected lifecycle to stop: start may have partially succeeded before
        // throwing, and a self-check must not leave its isolated gateway running.
        do {
            try await SelfCheckProbeExecutor.mainActor(
                id: "gateway stop",
                timeout: dependencies.timeoutPolicy.gatewayStop,
                operation: probe.stop
            )
            stopped = true
        } catch {
            failures.append(error.localizedDescription)
        }
        let passed = started && healthy && stopped && failures.isEmpty
        return check(
            id: "gateway_lifecycle",
            passed: passed,
            detail: passed
                ? "gateway start, health, and stop succeeded"
                : failures.joined(separator: "; "),
            values: [
                "started": String(started),
                "healthy": String(healthy),
                "stopped": String(stopped),
            ],
            redactor: redactor
        )
    }

    private func runBackgroundProbe<Snapshot: Sendable>(
        id: String,
        deadline: ContinuousClock.Instant,
        operation: @escaping @Sendable () throws -> Snapshot
    ) async throws -> Snapshot {
        let timeout = try remainingProbeBudget(id: id, deadline: deadline)
        return try await SelfCheckProbeExecutor.background(
            id: id,
            timeout: timeout,
            operation: operation
        )
    }

    private func runMainActorProbe<Snapshot: Sendable>(
        id: String,
        deadline: ContinuousClock.Instant,
        operation: @escaping @MainActor @Sendable () async throws -> Snapshot
    ) async throws -> Snapshot {
        let timeout = try remainingProbeBudget(id: id, deadline: deadline)
        return try await SelfCheckProbeExecutor.mainActor(
            id: id,
            timeout: timeout,
            operation: operation
        )
    }

    private func remainingProbeBudget(
        id: String,
        deadline: ContinuousClock.Instant
    ) throws -> Duration {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else {
            throw SelfCheckProbeTimeoutError(id: id, scope: .global)
        }
        let perProbe = dependencies.timeoutPolicy.probe
        guard perProbe > .zero else {
            throw SelfCheckProbeTimeoutError(id: id, scope: .probe)
        }
        return min(remaining, perProbe)
    }

    private func append(
        _ check: SelfCheckCheckReport,
        requirement: SelfCheckProbeRequirement,
        required: inout [SelfCheckCheckReport],
        optional: inout [SelfCheckCheckReport]
    ) {
        if requirement == .required { required.append(check) } else { optional.append(check) }
    }

    private func check(
        id: String,
        passed: Bool,
        detail: String,
        values: [String: String],
        redactor: SelfCheckRedactor
    ) -> SelfCheckCheckReport {
        SelfCheckCheckReport(
            id: id,
            status: passed ? .passed : .failed,
            detail: redactor.redact(detail),
            values: values.mapValues(redactor.redact)
        )
    }

    private func failedCheck(
        id: String,
        error: Error,
        redactor: SelfCheckRedactor
    ) -> SelfCheckCheckReport {
        SelfCheckCheckReport(
            id: id,
            status: .failed,
            detail: redactor.redact(error.localizedDescription),
            values: [:]
        )
    }

    private func finalize(
        appVersion: String,
        required: [SelfCheckCheckReport],
        optional: [SelfCheckCheckReport],
        outputURL: URL?,
        baseFailureExitCode: Int32,
        redactor: SelfCheckRedactor
    ) -> SelfCheckExecution {
        var report = SelfCheckReport(
            schema: SelfCheckReport.currentSchema,
            version: SelfCheckReport.currentVersion,
            timestamp: Self.timestamp(dependencies.now()),
            appVersion: redactor.redact(appVersion),
            requiredChecks: required.sorted { $0.id < $1.id },
            optionalChecks: optional.sorted { $0.id < $1.id },
            success: required.allSatisfy { $0.status == .passed }
        )
        var exitCode = report.success ? SelfCheckExitCode.success : baseFailureExitCode
        var line = encode(report)

        if let outputURL {
            do {
                try dependencies.writeReportFile(Data(line.utf8) + Data([0x0A]), outputURL)
            } catch {
                report.requiredChecks.append(SelfCheckCheckReport(
                    id: "report_output",
                    status: .failed,
                    detail: redactor.redact(error.localizedDescription),
                    values: [:]
                ))
                report.requiredChecks.sort { $0.id < $1.id }
                report.success = false
                exitCode = SelfCheckExitCode.reportEmissionFailed
                line = encode(report)
            }
        }

        do {
            try dependencies.writeStandardOutput(Data(line.utf8) + Data([0x0A]))
        } catch {
            exitCode = SelfCheckExitCode.reportEmissionFailed
        }
        return SelfCheckExecution(report: report, jsonLine: line, exitCode: exitCode)
    }

    private func encode(_ report: SelfCheckReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(report)) ?? Data("{}".utf8), as: UTF8.self)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

enum SelfCheckUIValidator {
    static let geometryTolerance = 1.0

    static func evaluate(
        _ snapshot: SelfCheckUISnapshot
    ) -> (Bool, String, [String: String]) {
        var values = [
            "frontmostPID": snapshot.frontmostApplicationPID.map(String.init) ?? "missing",
            "mainWindowFrame": snapshot.mainWindowFrame?.reportValue ?? "missing",
            "statusItemFrame": snapshot.statusItemFrame?.reportValue ?? "missing",
            "panelFrame": snapshot.panelFrame?.reportValue ?? "missing",
            "visibleScreenFrame": snapshot.visibleScreenFrame?.reportValue ?? "missing",
        ]
        var failures: [String] = []

        let frames: [(String, SelfCheckFrame?)] = [
            ("main window", snapshot.mainWindowFrame),
            ("status item", snapshot.statusItemFrame),
            ("panel", snapshot.panelFrame),
            ("visible screen", snapshot.visibleScreenFrame),
        ]
        for (name, frame) in frames {
            guard let frame else {
                failures.append("\(name) frame is missing")
                continue
            }
            if !frame.isFiniteAndPositive {
                failures.append("\(name) frame is non-finite or non-positive")
            }
        }
        if (snapshot.frontmostApplicationPID ?? 0) <= 0 {
            failures.append("frontmost application PID is missing or invalid")
        }

        if let status = snapshot.statusItemFrame,
           let panel = snapshot.panelFrame,
           let screen = snapshot.visibleScreenFrame,
           status.isFiniteAndPositive,
           panel.isFiniteAndPositive,
           screen.isFiniteAndPositive {
            let tolerance = geometryTolerance
            let panelRect = panel.rect
            let screenRect = screen.rect
            let contained = panelRect.minX >= screenRect.minX - tolerance
                && panelRect.maxX <= screenRect.maxX + tolerance
                && panelRect.minY >= screenRect.minY - tolerance
                && panelRect.maxY <= screenRect.maxY + tolerance
            if !contained {
                failures.append("panel frame is outside the visible screen")
            }

            let expected = MenuBarPanelPositioner.frame(
                anchor: status.rect,
                visibleFrame: screen.rect
            )
            values["expectedPanelFrame"] = SelfCheckFrame(expected).reportValue
            if !approximatelyEqual(panelRect, expected, tolerance: tolerance) {
                failures.append("panel frame does not match menu-bar positioner geometry")
            }
        } else {
            values["expectedPanelFrame"] = "unavailable"
        }

        let passed = failures.isEmpty
        return (
            passed,
            passed
                ? "UI snapshot frames, containment, position, and frontmost PID are valid"
                : failures.joined(separator: "; "),
            values
        )
    }

    private static func approximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: Double
    ) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.size.width - rhs.size.width) <= tolerance
            && abs(lhs.size.height - rhs.size.height) <= tolerance
    }
}

private struct SelfCheckProbeTimeoutError: LocalizedError, Sendable {
    enum Scope: Sendable {
        case global
        case probe
    }

    let id: String
    let scope: Scope

    var errorDescription: String? {
        switch scope {
        case .global: "self-check global deadline exceeded before \(id) completed"
        case .probe: "self-check probe timed out: \(id)"
        }
    }
}

private enum SelfCheckProbeOutcome<Value: Sendable>: @unchecked Sendable {
    case success(Value)
    case failure(Error)
}

private final class SelfCheckProbeCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SelfCheckProbeOutcome<Value>, Never>?

    init(_ continuation: CheckedContinuation<SelfCheckProbeOutcome<Value>, Never>) {
        self.continuation = continuation
    }

    func resolve(_ outcome: SelfCheckProbeOutcome<Value>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }
}

private enum SelfCheckProbeExecutor {
    static func background<Value: Sendable>(
        id: String,
        timeout: Duration,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let outcome: SelfCheckProbeOutcome<Value> = await withCheckedContinuation { continuation in
            let completion = SelfCheckProbeCompletion(continuation)
            let operationTask = Task.detached(priority: .utility) {
                do {
                    completion.resolve(.success(try operation()))
                } catch {
                    completion.resolve(.failure(error))
                }
            }
            Task.detached(priority: .utility) {
                if timeout > .zero { try? await Task.sleep(for: timeout) }
                completion.resolve(.failure(SelfCheckProbeTimeoutError(id: id, scope: .probe)))
                operationTask.cancel()
            }
        }
        return try value(from: outcome)
    }

    static func mainActor<Value: Sendable>(
        id: String,
        timeout: Duration,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        let outcome: SelfCheckProbeOutcome<Value> = await withCheckedContinuation { continuation in
            let completion = SelfCheckProbeCompletion(continuation)
            let operationTask = Task { @MainActor in
                do {
                    completion.resolve(.success(try await operation()))
                } catch {
                    completion.resolve(.failure(error))
                }
            }
            Task.detached(priority: .utility) {
                if timeout > .zero { try? await Task.sleep(for: timeout) }
                completion.resolve(.failure(SelfCheckProbeTimeoutError(id: id, scope: .probe)))
                operationTask.cancel()
            }
        }
        return try value(from: outcome)
    }

    private static func value<Value: Sendable>(
        from outcome: SelfCheckProbeOutcome<Value>
    ) throws -> Value {
        switch outcome {
        case .success(let value): value
        case .failure(let error): throw error
        }
    }
}

private final class SelfCheckSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

enum SelfCheckSystemProbe {
    static func bundle(_ bundle: Bundle) -> SelfCheckBundleSnapshot {
        SelfCheckBundleSnapshot(
            isMainApplicationBundle: bundle.bundleURL.pathExtension == "app"
                && bundle.executableURL != nil,
            bundleIdentifier: bundle.bundleIdentifier,
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            architecture: runtimeArchitecture
        )
    }

    static func bifrost(bundle: Bundle, fileManager: FileManager) throws -> SelfCheckBifrostSnapshot {
        guard let file = bundle.url(forAuxiliaryExecutable: "bifrost-http") else {
            return SelfCheckBifrostSnapshot(
                exists: false,
                isRegularFile: false,
                executable: false,
                slices: []
            )
        }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let regular = values.isRegularFile == true && values.isSymbolicLink != true
        let executable = fileManager.isExecutableFile(atPath: file.path)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return SelfCheckBifrostSnapshot(
            exists: true,
            isRegularFile: regular,
            executable: executable,
            slices: (try? machOSlices(in: handle)) ?? []
        )
    }

    /// Digests any Mach-O file one architecture at a time. Exposed so the fat-header walk can be
    /// tested against real universal and thin binaries rather than only through a packaged app.
    static func machOSlices(at url: URL) throws -> [SelfCheckMachOSlice] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try machOSlices(in: handle)
    }

    /// Digests the helper one architecture at a time.
    ///
    /// A fat header is stored big-endian regardless of the host, and its entries are the only
    /// record of where each slice begins and ends. A thin file is reported as the single slice it
    /// is, so a local single-architecture build still produces a comparable answer.
    private static func machOSlices(in handle: FileHandle) throws -> [SelfCheckMachOSlice] {
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: 8) ?? Data()
        guard header.count == 8 else { return [] }
        let magic = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }

        switch magic {
        case FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64:
            let is64 = magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64
            let count = header
                .withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
                .bigEndian
            // A plausible ceiling. A fat header claiming millions of slices is a malformed file,
            // not something to allocate for.
            guard count > 0, count <= 32 else { return [] }

            let entrySize = is64 ? 32 : 20
            var slices: [SelfCheckMachOSlice] = []
            for index in 0..<Int(count) {
                try handle.seek(toOffset: UInt64(8 + index * entrySize))
                guard let entry = try handle.read(upToCount: entrySize), entry.count == entrySize
                else { return [] }
                let cpu = entry.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
                let offset: UInt64
                let size: UInt64
                if is64 {
                    offset = entry
                        .withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
                        .bigEndian
                    size = entry
                        .withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self) }
                        .bigEndian
                } else {
                    offset = UInt64(
                        entry
                            .withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
                            .bigEndian
                    )
                    size = UInt64(
                        entry
                            .withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }
                            .bigEndian
                    )
                }
                guard let name = architectureName(cpu_type_t(bitPattern: cpu)) else { return [] }
                slices.append(SelfCheckMachOSlice(
                    architecture: name,
                    sha256: try digest(handle, from: offset, count: size)
                ))
            }
            return slices

        case UInt32(MH_MAGIC), UInt32(MH_MAGIC_64), UInt32(MH_CIGAM), UInt32(MH_CIGAM_64):
            guard let name = machOArchitecture(header) else { return [] }
            try handle.seek(toOffset: 0)
            let size = try handle.seekToEnd()
            return [SelfCheckMachOSlice(
                architecture: name,
                sha256: try digest(handle, from: 0, count: size)
            )]

        default:
            return []
        }
    }

    private static func digest(
        _ handle: FileHandle,
        from offset: UInt64,
        count: UInt64
    ) throws -> String {
        try handle.seek(toOffset: offset)
        var remaining = count
        var digest = SHA256()
        while remaining > 0 {
            let wanted = Int(min(remaining, 1 * 1_024 * 1_024))
            guard let chunk = try handle.read(upToCount: wanted), !chunk.isEmpty else { break }
            digest.update(data: chunk)
            remaining -= UInt64(chunk.count)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func configRoundTrip(
        homeDirectory: URL,
        marker: String,
        fileManager: FileManager
    ) throws -> SelfCheckConfigSnapshot {
        let directory = try makeUniqueProbeDirectory(
            homeDirectory: homeDirectory,
            prefix: "config",
            fileManager: fileManager
        )
        defer { try? fileManager.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config-\(marker).json")
        let payload = try JSONSerialization.data(
            withJSONObject: ["marker": marker, "version": 1],
            options: [.sortedKeys]
        )
        try SecureAtomicFile.write(payload, to: file, fileManager: fileManager)
        let roundTrip = try Data(contentsOf: file) == payload
        let attributes = try fileManager.attributesOfItem(atPath: file.path)
        return SelfCheckConfigSnapshot(
            roundTripSucceeded: roundTrip,
            permissions: attributes[.posixPermissions] as? Int
        )
    }

    static func historyRoundTrip(
        homeDirectory: URL,
        marker: String,
        fileManager: FileManager
    ) throws -> SelfCheckHistorySnapshot {
        let fixtureRoot = try makeUniqueProbeDirectory(
            homeDirectory: homeDirectory,
            prefix: "history",
            fileManager: fileManager
        )
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        let projectDirectory = fixtureRoot.appendingPathComponent(
            "projects/-selfcheck",
            isDirectory: true
        )
        try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

        let sessionMarker = "session-\(marker)"
        let messageMarker = "message-\(marker)"
        let transcript = projectDirectory.appendingPathComponent("session.jsonl")
        let records: [[String: Any]] = [
            [
                "type": "user",
                "message": ["role": "user", "content": messageMarker],
                "sessionId": sessionMarker,
                "cwd": "/selfcheck",
                "timestamp": "2026-01-01T00:00:00.000Z",
            ],
            [
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [["type": "text", "text": messageMarker]],
                ],
                "sessionId": sessionMarker,
                "cwd": "/selfcheck",
                "timestamp": "2026-01-01T00:00:01.000Z",
            ],
        ]
        var payload = Data()
        for record in records {
            payload.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            payload.append(0x0A)
        }
        try SecureAtomicFile.write(payload, to: transcript, fileManager: fileManager)

        let repository = HistoryRepository(
            historyDirs: [fixtureRoot.path],
            homeDirectory: homeDirectory,
            importsRoot: fixtureRoot.appendingPathComponent("imports", isDirectory: true)
        )
        let canonicalTranscript = transcript.resolvingSymlinksInPath().standardizedFileURL
        guard let metadata = repository.listSessions(limit: 10).first(where: {
            $0.file.resolvingSymlinksInPath().standardizedFileURL == canonicalTranscript
        }) else {
            return SelfCheckHistorySnapshot(
                discovered: false,
                parsed: false,
                sessionMarkerMatched: false,
                messageMarkerMatched: false
            )
        }

        let session = try repository.getSession(file: metadata.file)
        return SelfCheckHistorySnapshot(
            discovered: true,
            parsed: session.metadata.source == .claude && !session.messages.isEmpty,
            sessionMarkerMatched: metadata.sessionID == sessionMarker
                && session.metadata.sessionID == sessionMarker,
            messageMarkerMatched: session.messages.contains { message in
                message.content.contains { $0.text == messageMarker }
            }
        )
    }

    /// Creates an unpredictable probe directory directly below the validated isolated root.
    /// Unlike a shared `selfcheck` directory, an attacker cannot pre-seed this child as a symlink
    /// and redirect the subsequent chmod/write operations into another data tree.
    private static func makeUniqueProbeDirectory(
        homeDirectory: URL,
        prefix: String,
        fileManager: FileManager
    ) throws -> URL {
        try fileManager.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        let homeValues = try homeDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard homeValues.isDirectory == true, homeValues.isSymbolicLink != true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        for _ in 0..<8 {
            let directory = homeDirectory.appendingPathComponent(
                ".ccbud-selfcheck-\(prefix)-\(UUID().uuidString)",
                isDirectory: true
            )
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
            let values = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                try? fileManager.removeItem(at: directory)
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            return directory
        }
        throw POSIXError(.EEXIST)
    }

    static func clipboardRoundTrip(
        marker: String,
        pasteboard: NSPasteboard
    ) -> SelfCheckClipboardSnapshot {
        let original = archive(pasteboard)
        pasteboard.clearContents()
        let writeSucceeded = pasteboard.setString(marker, forType: .string)
        let readBackSucceeded = pasteboard.string(forType: .string) == marker
        restore(original, to: pasteboard)
        return SelfCheckClipboardSnapshot(
            writeSucceeded: writeSucceeded,
            readBackSucceeded: readBackSucceeded,
            restored: archive(pasteboard) == original
        )
    }

    private struct PasteboardItemArchive: Equatable {
        let values: [String: Data]
    }

    private static func archive(_ pasteboard: NSPasteboard) -> [PasteboardItemArchive] {
        (pasteboard.pasteboardItems ?? []).map { item in
            PasteboardItemArchive(values: Dictionary(uniqueKeysWithValues: item.types.compactMap {
                type in item.data(forType: type).map { (type.rawValue, $0) }
            }))
        }
    }

    private static func restore(
        _ archive: [PasteboardItemArchive],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        let items = archive.map { archived -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (rawType, data) in archived.values {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private static func machOArchitecture(_ header: Data) -> String? {
        guard header.count >= 8 else { return nil }
        let magic = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let cpu = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        let normalizedCPU: UInt32
        switch magic {
        case UInt32(MH_MAGIC), UInt32(MH_MAGIC_64): normalizedCPU = cpu
        case UInt32(MH_CIGAM), UInt32(MH_CIGAM_64): normalizedCPU = cpu.byteSwapped
        default: return nil
        }
        return architectureName(cpu_type_t(bitPattern: normalizedCPU)) ?? "unknown"
    }

    private static func architectureName(_ cpu: cpu_type_t) -> String? {
        switch cpu {
        case CPU_TYPE_ARM64: "arm64"
        case CPU_TYPE_X86_64: "x86_64"
        default: nil
        }
    }

    private static var runtimeArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

enum SelfCheckReportFileWriter {
    static func write(
        _ data: Data,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        guard destination.isFileURL, !data.isEmpty,
              data.last == 0x0A,
              !data.dropLast().contains(0x0A),
              !data.dropLast().contains(0x0D) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try SecureAtomicFile.write(data, to: destination, fileManager: fileManager)
        let attributes = try fileManager.attributesOfItem(atPath: destination.path)
        guard (attributes[.posixPermissions] as? Int).map({ $0 & 0o777 }) == 0o600 else {
            throw POSIXError(.EPERM)
        }
    }
}

private struct SelfCheckRedactor {
    private let literalSecrets: [String]
    private static let labeledSecret = try! NSRegularExpression(
        pattern: #"(?i)((?:api[_-]?key|token|password|secret|authorization|cookie)\s*[:=]\s*)[^\s,;]+"#
    )
    private static let bearer = try! NSRegularExpression(
        pattern: #"(?i)(bearer\s+)[A-Za-z0-9._~+\-/=]+"#
    )

    init(
        environment: [String: String],
        userHomeDirectory: URL,
        request: SelfCheckRequest?,
        additionalSecrets: [String] = []
    ) {
        let sensitiveFragments = [
            "TOKEN", "KEY", "SECRET", "PASSWORD", "AUTH", "COOKIE", "CREDENTIAL", "HOME",
        ]
        var values = environment.compactMap { key, value -> String? in
            sensitiveFragments.contains(where: { key.uppercased().contains($0) }) ? value : nil
        }
        values.append(userHomeDirectory.path)
        if let request {
            values.append(request.homeDirectory.path)
            if let outputURL = request.outputURL { values.append(outputURL.path) }
        }
        values.append(contentsOf: additionalSecrets)
        literalSecrets = Array(Set(values.filter { $0.count >= 3 })).sorted { $0.count > $1.count }
    }

    func redact(_ raw: String) -> String {
        var value = raw
        for secret in literalSecrets {
            value = value.replacingOccurrences(of: secret, with: "<redacted>")
        }
        let fullRange = { NSRange(value.startIndex..<value.endIndex, in: value) }
        value = Self.labeledSecret.stringByReplacingMatches(
            in: value,
            range: fullRange(),
            withTemplate: "$1<redacted>"
        )
        value = Self.bearer.stringByReplacingMatches(
            in: value,
            range: fullRange(),
            withTemplate: "$1<redacted>"
        )
        return value
    }
}
