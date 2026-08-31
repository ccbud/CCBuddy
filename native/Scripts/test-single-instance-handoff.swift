import AppKit
import Foundation

private enum HandoffProbeError: LocalizedError {
    case invalidArguments
    case invalidApplication(String)
    case timedOut(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "usage: test-single-instance-handoff.swift <CC Buddy.app> [timeout-seconds]"
        case .invalidApplication(let detail), .operationFailed(let detail):
            detail
        case .timedOut(let operation):
            "timed out while waiting for \(operation)"
        }
    }
}

private func wait(
    seconds: TimeInterval,
    operation: String,
    until predicate: () -> Bool
) throws {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if predicate() { return }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    throw HandoffProbeError.timedOut(operation)
}

private func launchApplication(
    application: URL,
    isolatedHome: URL,
    timeout: TimeInterval
) throws -> NSRunningApplication {
    var environment = ProcessInfo.processInfo.environment
    for key in [
        "CCBUD_SELFCHECK",
        "CCBUD_SELFCHECK_OUT",
        "CCBUD_UI_TESTING",
        "XCTestBundlePath",
        "XCTestConfigurationFilePath",
        "XCTestSessionIdentifier",
    ] {
        environment.removeValue(forKey: key)
    }
    environment["CCBUD_HOME"] = isolatedHome.path

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.createsNewApplicationInstance = true
    configuration.environment = environment

    var launchedApplication: NSRunningApplication?
    var launchError: Error?
    NSWorkspace.shared.openApplication(at: application, configuration: configuration) {
        launchedApplication = $0
        launchError = $1
    }
    try wait(seconds: timeout, operation: "LaunchServices to create the application process") {
        launchedApplication != nil || launchError != nil
    }
    if let launchError { throw launchError }
    guard let launchedApplication else {
        throw HandoffProbeError.operationFailed("LaunchServices returned no application process")
    }
    return launchedApplication
}

private func launchProcess(executable: URL, isolatedHome: URL) throws -> Process {
    let process = Process()
    process.executableURL = executable
    var environment = ProcessInfo.processInfo.environment
    for key in [
        "CCBUD_SELFCHECK",
        "CCBUD_SELFCHECK_OUT",
        "CCBUD_UI_TESTING",
        "XCTestBundlePath",
        "XCTestConfigurationFilePath",
        "XCTestSessionIdentifier",
    ] {
        environment.removeValue(forKey: key)
    }
    environment["CCBUD_HOME"] = isolatedHome.path
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

private func stop(_ application: NSRunningApplication?) {
    guard let application, !application.isTerminated else { return }
    _ = application.terminate()
    let deadline = Date().addingTimeInterval(5)
    while !application.isTerminated, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    if !application.isTerminated {
        _ = application.forceTerminate()
    }
}

private func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(5)
    while process.isRunning, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    if process.isRunning { process.interrupt() }
}

private func run() throws {
    guard (2...3).contains(CommandLine.arguments.count) else {
        throw HandoffProbeError.invalidArguments
    }
    let application = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        .standardizedFileURL
    guard application.lastPathComponent == "CC Buddy.app" else {
        throw HandoffProbeError.invalidApplication("expected a CC Buddy.app bundle")
    }
    let executable = application.appendingPathComponent("Contents/MacOS/CC Buddy")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw HandoffProbeError.invalidApplication("app executable is missing")
    }
    let timeout = CommandLine.arguments.count == 3
        ? TimeInterval(CommandLine.arguments[2]) ?? 15
        : 15
    guard timeout > 0 else {
        throw HandoffProbeError.invalidArguments
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ccbud-instance-handoff-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: root.path
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let history = root.appendingPathComponent("history", isDirectory: true)
    let config = root.appendingPathComponent("config.json")
    let escapedHistory = history.path
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let contents = """
    {"gatewayEnabled":false,"openAtLogin":false,"historyDirs":["\(escapedHistory)"],"autoUpdate":{"check":false,"autoDownload":false}}
    """
    try Data(contents.utf8).write(to: config, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: config.path
    )

    let primaryApplication = try launchApplication(
        application: application,
        isolatedHome: root,
        timeout: timeout
    )
    defer { stop(primaryApplication) }

    try wait(seconds: timeout, operation: "the primary application to finish launching") {
        primaryApplication.isFinishedLaunching
            && primaryApplication.activationPolicy == .regular
    }
    guard primaryApplication.activate(options: [.activateAllWindows]) else {
        throw HandoffProbeError.operationFailed("could not activate the primary application")
    }
    try wait(seconds: timeout, operation: "the primary application to become visible") {
        !primaryApplication.isHidden && primaryApplication.activationPolicy == .regular
    }
    // `hide()` reports whether LaunchServices accepted the request synchronously. SwiftUI apps can
    // return false while AppKit is still completing the transition, so the observable state below
    // is the authoritative assertion.
    _ = primaryApplication.hide()
    try wait(seconds: timeout, operation: "the primary application to enter its hidden state") {
        // AppDelegate intentionally turns a hidden CC Buddy into an accessory/menu-bar app. Once
        // that policy changes, LaunchServices may no longer report `isHidden` even though the main
        // app has completed the same hidden-state transition.
        primaryApplication.isHidden || primaryApplication.activationPolicy == .accessory
    }

    let secondaryProcess = try launchProcess(executable: executable, isolatedHome: root)
    defer { stop(secondaryProcess) }
    try wait(seconds: timeout, operation: "the secondary application to hand off and exit") {
        !secondaryProcess.isRunning
    }
    guard secondaryProcess.terminationReason == .exit,
          secondaryProcess.terminationStatus == 0 else {
        throw HandoffProbeError.operationFailed(
            "secondary application exited abnormally (status \(secondaryProcess.terminationStatus))"
        )
    }

    try wait(seconds: timeout, operation: "the primary application to reactivate") {
        !primaryApplication.isHidden
            && primaryApplication.activationPolicy == .regular
    }
    guard !primaryApplication.isTerminated else {
        throw HandoffProbeError.operationFailed("primary application exited during handoff")
    }
    print("single-instance handoff passed: secondary exited and primary became visible")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("single-instance handoff failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
