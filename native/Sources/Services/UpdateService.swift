import Foundation

struct UpdateServiceConfiguration: Sendable {
    let metadataURL: URL
    let releasePageURL: URL
    let currentVersion: String
    let platformKeys: [String]
    let stagingRoot: URL
    let currentApplicationURL: URL
    let trustedHosts: Set<String>
    let maximumMetadataBytes: Int
    let maximumArtifactBytes: Int

    static func live(
        stagingRoot: URL,
        bundle: Bundle = .main
    ) -> UpdateServiceConfiguration {
        #if arch(arm64)
        let keys = ["darwin-aarch64-app", "darwin-aarch64"]
        #else
        let keys = ["darwin-x86_64-app", "darwin-x86_64"]
        #endif
        return UpdateServiceConfiguration(
            metadataURL: URL(string: "https://github.com/ccbud/ccbud/releases/latest/download/latest.json")!,
            releasePageURL: URL(string: "https://github.com/ccbud/ccbud/releases/latest")!,
            currentVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "0.0.0",
            platformKeys: keys,
            stagingRoot: stagingRoot,
            currentApplicationURL: bundle.bundleURL,
            trustedHosts: [
                "github.com", "www.github.com", "objects.githubusercontent.com",
                "release-assets.githubusercontent.com",
            ],
            maximumMetadataBytes: 1 * 1_024 * 1_024,
            maximumArtifactBytes: 512 * 1_024 * 1_024
        )
    }
}

actor UpdateService {
    private(set) var state: UpdateState

    private let configuration: UpdateServiceConfiguration
    private let currentVersion: UpdateSemanticVersion?
    private let session: URLSession
    private let fileManager: FileManager
    private let artifactVerifier: any UpdateArtifactVerifying
    private let archiveExtractor: any UpdateArchiveExtracting
    private let applicationVerifier: any UpdateApplicationVerifying
    private let installer: any UpdateApplicationInstalling
    private var latestRelease: UpdateRelease?
    private var stagedUpdate: StagedUpdate?
    private var operationInProgress = false

    init(
        configuration: UpdateServiceConfiguration,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        artifactVerifier: (any UpdateArtifactVerifying)? = nil,
        archiveExtractor: (any UpdateArchiveExtracting)? = nil,
        applicationVerifier: (any UpdateApplicationVerifying)? = nil,
        installer: (any UpdateApplicationInstalling)? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.fileManager = fileManager
        self.artifactVerifier = artifactVerifier
            ?? (try? SignedUpdateArtifactVerifier())
            ?? RejectingUpdateArtifactVerifier()
        self.archiveExtractor = archiveExtractor ?? TarGzipUpdateExtractor(fileManager: fileManager)
        self.applicationVerifier = applicationVerifier
            ?? DeveloperIDUpdateVerifier()
        self.installer = installer ?? AtomicUpdateInstaller(fileManager: fileManager)
        currentVersion = UpdateSemanticVersion(configuration.currentVersion)
        if currentVersion == nil {
            state = .failed(
                currentVersion: configuration.currentVersion,
                message: UpdateServiceError.invalidCurrentVersion(configuration.currentVersion)
                    .localizedDescription
            )
        } else {
            state = .idle(currentVersion: configuration.currentVersion)
        }
    }

    func check() async -> UpdateState {
        switch state {
        case .installed, .installedAwaitingRestart:
            // The application on disk has already been replaced. Checking against the version of
            // this still-running process would rediscover and download the same release.
            return state
        default:
            break
        }
        guard beginOperation() else { return state }
        defer { endOperation() }
        guard let currentVersion else { return state }
        state = .checking(currentVersion: configuration.currentVersion)

        do {
            try validateHTTPS(configuration.metadataURL)
            let data = try await fetch(
                configuration.metadataURL,
                maximumBytes: configuration.maximumMetadataBytes
            )
            let manifest: Manifest
            do { manifest = try JSONDecoder().decode(Manifest.self, from: data) }
            catch { throw UpdateServiceError.invalidMetadata(error.localizedDescription) }
            guard let releaseVersion = UpdateSemanticVersion(manifest.version) else {
                throw UpdateServiceError.invalidReleaseVersion(manifest.version)
            }
            guard releaseVersion > currentVersion else {
                latestRelease = nil
                stagedUpdate = nil
                state = .upToDate(currentVersion: configuration.currentVersion, checkedAt: Date())
                return state
            }

            let platform = configuration.platformKeys.compactMap { manifest.platforms[$0] }.first
            let artifactURL = platform.flatMap { URL(string: $0.url) }
            let release = UpdateRelease(
                version: releaseVersion,
                notes: manifest.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                publishedAt: Self.parseDate(manifest.pubDate),
                artifactURL: artifactURL,
                encodedSignature: platform?.signature.nilIfEmpty,
                expectedSHA256: platform?.sha256?.nilIfEmpty ?? platform?.digest?.nilIfEmpty,
                releasePageURL: configuration.releasePageURL
            )
            latestRelease = release
            guard platform != nil, let artifactURL else {
                stagedUpdate = nil
                state = .manualDownload(
                    release,
                    reason: UpdateServiceError.unsupportedPlatform(configuration.platformKeys.joined(separator: ", "))
                        .localizedDescription
                )
                return state
            }
            do { try validateHTTPS(artifactURL) }
            catch let error as UpdateServiceError {
                stagedUpdate = nil
                state = .manualDownload(release, reason: error.localizedDescription)
                return state
            }
            guard release.encodedSignature != nil else {
                stagedUpdate = nil
                state = .manualDownload(
                    release,
                    reason: UpdateServiceError.missingTrustMaterial.localizedDescription
                )
                return state
            }
            if let staged = stagedUpdate, staged.release.version == release.version {
                let refreshed = StagedUpdate(
                    release: release,
                    directoryURL: staged.directoryURL,
                    applicationURL: staged.applicationURL,
                    artifactSHA256: staged.artifactSHA256
                )
                stagedUpdate = refreshed
                state = .staged(refreshed)
                return state
            }
            stagedUpdate = nil
            state = .available(release)
        } catch {
            state = failureState(for: error, release: nil)
        }
        return state
    }

    func downloadAndStage() async -> UpdateState {
        guard beginOperation() else { return state }
        defer { endOperation() }
        guard let release = latestRelease,
              let artifactURL = release.artifactURL,
              let encodedSignature = release.encodedSignature
        else {
            state = failureState(for: UpdateServiceError.noAvailableUpdate, release: latestRelease)
            return state
        }
        state = .downloading(release)
        var operationDirectory: URL?

        do {
            try validateHTTPS(artifactURL)
            let artifact = try await fetch(
                artifactURL,
                maximumBytes: configuration.maximumArtifactBytes
            )
            let artifactSHA256 = try artifactVerifier.verify(
                artifact: artifact,
                encodedSignature: encodedSignature,
                expectedSHA256: release.expectedSHA256
            )
            try ensurePrivateStagingRoot()
            let directory = configuration.stagingRoot.appendingPathComponent(
                "staging-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            operationDirectory = directory
            let archiveURL = directory.appendingPathComponent("update.app.tar.gz")
            try SecureAtomicFile.write(artifact, to: archiveURL, fileManager: fileManager)
            let extractionURL = directory.appendingPathComponent("extracted", isDirectory: true)
            let applicationURL = try archiveExtractor.extract(
                archiveURL: archiveURL,
                destinationURL: extractionURL
            )
            try validateExtractedApplication(applicationURL, inside: extractionURL)
            _ = try applicationVerifier.verify(
                applicationURL: applicationURL,
                expectedVersion: release.version
            )
            let staged = StagedUpdate(
                release: release,
                directoryURL: directory,
                applicationURL: applicationURL,
                artifactSHA256: artifactSHA256
            )
            let receipt = StageReceipt(
                version: release.version.description,
                artifactURL: artifactURL.absoluteString,
                sha256: artifactSHA256,
                applicationPath: applicationURL.path
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try SecureAtomicFile.write(
                encoder.encode(receipt),
                to: directory.appendingPathComponent("receipt.json"),
                fileManager: fileManager
            )
            stagedUpdate = staged
            state = .staged(staged)
            operationDirectory = nil
        } catch {
            if let operationDirectory { try? fileManager.removeItem(at: operationDirectory) }
            state = failureState(for: error, release: release)
        }
        return state
    }

    func installStaged() async -> UpdateState {
        guard beginOperation() else { return state }
        defer { endOperation() }
        guard let staged = stagedUpdate, let currentVersion else {
            state = failureState(for: UpdateServiceError.noStagedUpdate, release: latestRelease)
            return state
        }
        state = .installing(staged)
        var preparedURL: URL?

        do {
            _ = try applicationVerifier.verify(
                applicationURL: staged.applicationURL,
                expectedVersion: staged.release.version
            )
            _ = try applicationVerifier.verify(
                applicationURL: configuration.currentApplicationURL,
                expectedVersion: currentVersion
            )
            let prepared = try installer.prepare(
                stagedApplicationURL: staged.applicationURL,
                currentApplicationURL: configuration.currentApplicationURL
            )
            preparedURL = prepared
            _ = try applicationVerifier.verify(
                applicationURL: prepared,
                expectedVersion: staged.release.version
            )
            let backup = try installer.commit(
                preparedApplicationURL: prepared,
                currentApplicationURL: configuration.currentApplicationURL
            )
            // After the atomic swap, `prepared` is no longer disposable scratch space: it is the
            // only copy of the previously installed application until rollback or the next
            // verified launch succeeds. Keep the generic failure cleanup from deleting it.
            preparedURL = nil
            let installed = InstalledUpdate(
                staged: staged,
                applicationURL: configuration.currentApplicationURL,
                backupApplicationURL: backup
            )
            do {
                try writeInstallationReceipt(installed)
            } catch let receiptError {
                do {
                    try installer.rollback(
                        backupApplicationURL: backup,
                        currentApplicationURL: configuration.currentApplicationURL
                    )
                    // A successful swap-back leaves the rejected new application at `backup`.
                    installer.discardPreparedApplication(at: backup)
                } catch let rollbackError {
                    // Rollback failed, so `backup` is still the only recovery copy of the old app.
                    // Never discard it, even though the installation receipt could not be written.
                    throw UpdateServiceError.installation(
                        "无法写入安装凭据（\(receiptError.localizedDescription)），且无法回滚更新（\(rollbackError.localizedDescription)）。旧应用已保留在 \(backup.path)"
                    )
                }
                throw receiptError
            }
            state = .installed(installed)
        } catch {
            if let preparedURL { installer.discardPreparedApplication(at: preparedURL) }
            state = failureState(for: error, release: staged.release)
        }
        return state
    }

    func rollbackInstalledUpdate() async -> UpdateState {
        guard case .installed(let installed) = state else { return state }
        do {
            try installer.rollback(
                backupApplicationURL: installed.backupApplicationURL,
                currentApplicationURL: installed.applicationURL
            )
            installer.discardPreparedApplication(at: installed.backupApplicationURL)
            try? fileManager.removeItem(at: installationReceiptURL)
            state = .staged(installed.staged)
        } catch {
            state = failureState(for: error, release: installed.staged.release)
        }
        return state
    }

    func markInstalledAwaitingRestart() -> UpdateState {
        guard case .installed(let installed) = state else { return state }
        state = .installedAwaitingRestart(installed)
        return state
    }

    func finalizePreviousInstallation() {
        guard let data = try? Data(contentsOf: installationReceiptURL),
              let receipt = try? JSONDecoder().decode(InstallationReceipt.self, from: data),
              receipt.applicationPath == configuration.currentApplicationURL.path,
              receipt.version == configuration.currentVersion,
              let version = currentVersion,
              (try? applicationVerifier.verify(
                  applicationURL: configuration.currentApplicationURL,
                  expectedVersion: version
              )) != nil
        else { return }
        let backup = URL(fileURLWithPath: receipt.backupPath, isDirectory: true)
        guard backup.deletingLastPathComponent().standardizedFileURL
                == configuration.currentApplicationURL.deletingLastPathComponent().standardizedFileURL,
              backup.lastPathComponent.hasPrefix(".CCBuddy.update-"),
              backup.pathExtension == "app"
        else { return }
        try? fileManager.removeItem(at: backup)
        try? fileManager.removeItem(at: installationReceiptURL)
    }

    private func beginOperation() -> Bool {
        guard !operationInProgress else { return false }
        operationInProgress = true
        return true
    }

    private func endOperation() { operationInProgress = false }

    private func failureState(for error: Error, release: UpdateRelease?) -> UpdateState {
        let updateError = error as? UpdateServiceError
            ?? UpdateServiceError.transport(error.localizedDescription)
        if updateError.requiresManualDownload {
            return .manualDownload(release, reason: updateError.localizedDescription)
        }
        return .failed(
            currentVersion: configuration.currentVersion,
            message: updateError.localizedDescription
        )
    }

    private func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        try validateHTTPS(url)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 60
        request.setValue("application/json, application/octet-stream", forHTTPHeaderField: "Accept")
        let delegate = HTTPSOnlyRedirectDelegate(trustedHosts: configuration.trustedHosts)
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            if let violation = delegate.violation { throw violation }
            guard let http = response as? HTTPURLResponse else {
                throw UpdateServiceError.invalidHTTPResponse
            }
            guard let finalURL = http.url else { throw UpdateServiceError.invalidHTTPResponse }
            try validateHTTPS(finalURL)
            guard http.statusCode == 200 else { throw UpdateServiceError.httpStatus(http.statusCode) }
            if http.expectedContentLength > Int64(maximumBytes) {
                throw UpdateServiceError.responseTooLarge
            }

            var responseData = Data()
            if http.expectedContentLength > 0 {
                responseData.reserveCapacity(min(Int(http.expectedContentLength), maximumBytes))
            }
            for try await byte in bytes {
                guard responseData.count < maximumBytes else {
                    throw UpdateServiceError.responseTooLarge
                }
                responseData.append(byte)
            }
            return responseData
        } catch let error as UpdateServiceError {
            throw error
        } catch {
            if let violation = delegate.violation { throw violation }
            throw UpdateServiceError.transport(error.localizedDescription)
        }
    }

    private func validateHTTPS(_ url: URL) throws {
        try UpdateURLTrust.validate(url, trustedHosts: configuration.trustedHosts)
    }

    private func ensurePrivateStagingRoot() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: configuration.stagingRoot.path, isDirectory: &isDirectory) {
            let values = try configuration.stagingRoot.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard isDirectory.boolValue, values.isDirectory == true, values.isSymbolicLink != true else {
                throw UpdateServiceError.unsafeStaging("根目录不是普通目录")
            }
        } else {
            try fileManager.createDirectory(
                at: configuration.stagingRoot,
                withIntermediateDirectories: true
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: configuration.stagingRoot.path
        )
    }

    private func validateExtractedApplication(_ applicationURL: URL, inside root: URL) throws {
        let rootPath = root.standardizedFileURL.path + "/"
        let applicationPath = applicationURL.standardizedFileURL.path
        let values = try applicationURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard applicationPath.hasPrefix(rootPath), applicationURL.pathExtension == "app",
              values.isDirectory == true, values.isSymbolicLink != true
        else { throw UpdateServiceError.invalidApplication("解包器返回了暂存目录之外的路径") }
    }

    private var installationReceiptURL: URL {
        configuration.stagingRoot.appendingPathComponent("installed.json")
    }

    private func writeInstallationReceipt(_ installed: InstalledUpdate) throws {
        try ensurePrivateStagingRoot()
        let receipt = InstallationReceipt(
            version: installed.staged.release.version.description,
            applicationPath: installed.applicationURL.path,
            backupPath: installed.backupApplicationURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try SecureAtomicFile.write(
            encoder.encode(receipt),
            to: installationReceiptURL,
            fileManager: fileManager
        )
    }

    private static func parseDate(_ source: String?) -> Date? {
        guard let source else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: source) ?? ISO8601DateFormatter().date(from: source)
    }
}

enum AutomaticUpdateCheckOutcome: Equatable, Sendable {
    case skipped
    case state(UpdateState)
    case restartPrompt(StagedUpdate)
}

/// Serializes visibility-triggered update work and owns the daily/retry policy independently of
/// AppKit lifecycle noise. Callers may safely forward launch, activation, and window-visibility
/// events without coordinating them first.
actor AutomaticUpdateLifecycle {
    static let retryInterval: TimeInterval = 10 * 60

    private struct Stamp: Codable {
        let lastAutoCheckDay: String
    }

    private let updateService: UpdateService
    private let stampFileURL: URL
    private let calendar: Calendar
    private let fileManager: FileManager
    private var completedDay: String?
    private var lastAttempt: Date?
    private var isRunning = false

    init(
        updateService: UpdateService,
        stampFileURL: URL,
        calendar: Calendar? = nil,
        fileManager: FileManager = .default
    ) {
        self.updateService = updateService
        self.stampFileURL = stampFileURL
        self.fileManager = fileManager
        if let calendar {
            self.calendar = calendar
        } else {
            var localCalendar = Calendar(identifier: .gregorian)
            localCalendar.timeZone = .autoupdatingCurrent
            self.calendar = localCalendar
        }
    }

    func applicationBecameVisible(
        at now: Date,
        checkEnabled: Bool,
        autoDownload: Bool
    ) async -> AutomaticUpdateCheckOutcome {
        let day = localDay(containing: now)
        if completedDay == day { return .skipped }
        if storedCompletedDay() == day {
            completedDay = day
            return .skipped
        }
        guard checkEnabled else { return .skipped }
        if let lastAttempt,
           now.timeIntervalSince(lastAttempt) < Self.retryInterval {
            return .skipped
        }
        guard !isRunning else { return .skipped }

        isRunning = true
        lastAttempt = now
        defer { isRunning = false }

        let checked = await updateService.check()
        switch checked {
        case .upToDate:
            markCompleted(day)
            return .state(checked)
        case .manualDownload(let release, _):
            // A release-bearing manual fallback follows a successful metadata request (for
            // example, an unsupported platform). A nil release represents a preflight/check
            // failure and must remain retryable.
            if release != nil { markCompleted(day) }
            return .state(checked)
        case .available:
            guard autoDownload else {
                markCompleted(day)
                return .state(checked)
            }
            let downloaded = await updateService.downloadAndStage()
            switch downloaded {
            case .staged(let staged):
                markCompleted(day)
                return .restartPrompt(staged)
            case .downloading, .installing, .installed, .installedAwaitingRestart:
                // A user-driven updater operation took ownership while this flow was suspended.
                markCompleted(day)
                return .state(downloaded)
            default:
                // Check/download failures deliberately leave the day unstamped. A later visible
                // event may retry after the fixed ten-minute interval.
                return .state(downloaded)
            }
        case .staged(let staged):
            markCompleted(day)
            return .restartPrompt(staged)
        case .downloading, .installing, .installed, .installedAwaitingRestart:
            markCompleted(day)
            return .state(checked)
        case .idle, .checking, .failed:
            return .state(checked)
        }
    }

    private func localDay(containing date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return ""
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func storedCompletedDay() -> String? {
        guard let data = try? Data(contentsOf: stampFileURL),
              data.count <= 4_096,
              let stamp = try? JSONDecoder().decode(Stamp.self, from: data)
        else { return nil }
        return stamp.lastAutoCheckDay
    }

    private func markCompleted(_ day: String) {
        completedDay = day
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Stamp(lastAutoCheckDay: day)) else { return }
        try? SecureAtomicFile.write(data, to: stampFileURL, fileManager: fileManager)
    }
}

private struct Manifest: Decodable {
    let version: String
    let notes: String?
    let pubDate: String?
    let platforms: [String: ManifestArtifact]

    enum CodingKeys: String, CodingKey {
        case version, notes, platforms
        case pubDate = "pub_date"
    }
}

private struct ManifestArtifact: Decodable {
    let signature: String
    let url: String
    let sha256: String?
    let digest: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        signature = try container.decodeIfPresent(String.self, forKey: .signature) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        digest = try container.decodeIfPresent(String.self, forKey: .digest)
    }

    private enum CodingKeys: String, CodingKey { case signature, url, sha256, digest }
}

private struct StageReceipt: Codable {
    let version: String
    let artifactURL: String
    let sha256: String
    let applicationPath: String
}

private struct InstallationReceipt: Codable {
    let version: String
    let applicationPath: String
    let backupPath: String
}

private struct RejectingUpdateArtifactVerifier: UpdateArtifactVerifying {
    func verify(
        artifact: Data,
        encodedSignature: String,
        expectedSHA256: String?
    ) throws -> String {
        throw UpdateServiceError.invalidSignature
    }
}

enum UpdateURLTrust {
    static func validate(_ url: URL, trustedHosts: Set<String>) throws {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443
        else { throw UpdateServiceError.insecureURL(url.absoluteString) }
        guard let host = url.host?.lowercased(), trustedHosts.contains(host) else {
            throw UpdateServiceError.untrustedHost(url.host ?? "")
        }
    }
}

final class HTTPSOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let trustedHosts: Set<String>
    private let lock = NSLock()
    private var storedViolation: UpdateServiceError?

    init(trustedHosts: Set<String>) { self.trustedHosts = trustedHosts }

    var violation: UpdateServiceError? {
        lock.lock()
        defer { lock.unlock() }
        return storedViolation
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            record(.invalidHTTPResponse)
            completionHandler(nil)
            return
        }
        do {
            try UpdateURLTrust.validate(url, trustedHosts: trustedHosts)
        } catch let error as UpdateServiceError {
            record(error)
            completionHandler(nil)
            return
        } catch {
            record(.invalidHTTPResponse)
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private func record(_ error: UpdateServiceError) {
        lock.lock()
        if storedViolation == nil { storedViolation = error }
        lock.unlock()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
