import Darwin
import Foundation
import Security

struct VerifiedUpdateApplication: Equatable, Sendable {
    let bundleIdentifier: String
    let version: UpdateSemanticVersion
    let teamIdentifier: String
}

protocol UpdateArchiveExtracting: Sendable {
    func extract(archiveURL: URL, destinationURL: URL) throws -> URL
}

protocol UpdateApplicationVerifying: Sendable {
    func verify(applicationURL: URL, expectedVersion: UpdateSemanticVersion) throws -> VerifiedUpdateApplication
}

protocol UpdateApplicationInstalling: Sendable {
    func prepare(stagedApplicationURL: URL, currentApplicationURL: URL) throws -> URL
    func commit(preparedApplicationURL: URL, currentApplicationURL: URL) throws -> URL
    func rollback(backupApplicationURL: URL, currentApplicationURL: URL) throws
    func discardPreparedApplication(at url: URL)
}

struct DeveloperIDUpdateVerifier: UpdateApplicationVerifying {
    static let bundleIdentifier = "dev.ccbud.gateway"
    static let teamIdentifier = "2CGR266XD2"

    let expectedBundleIdentifier: String
    let expectedTeamIdentifier: String
    init(
        expectedBundleIdentifier: String = Self.bundleIdentifier,
        expectedTeamIdentifier: String = Self.teamIdentifier
    ) {
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
    }

    func verify(
        applicationURL: URL,
        expectedVersion: UpdateSemanticVersion
    ) throws -> VerifiedUpdateApplication {
        let values = try applicationURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              applicationURL.pathExtension == "app"
        else { throw UpdateServiceError.invalidApplication("应用包不是普通 .app 目录") }

        let infoURL = applicationURL.appendingPathComponent("Contents/Info.plist")
        let infoValues = try infoURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard infoValues.isRegularFile == true, infoValues.isSymbolicLink != true else {
            throw UpdateServiceError.invalidApplication("Info.plist 缺失或不安全")
        }
        let infoData = try Data(contentsOf: infoURL, options: [.mappedIfSafe])
        guard let info = try PropertyListSerialization.propertyList(
            from: infoData,
            options: [],
            format: nil
        ) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              identifier == expectedBundleIdentifier,
              let rawVersion = info["CFBundleShortVersionString"] as? String,
              let version = UpdateSemanticVersion(rawVersion),
              version.description == expectedVersion.description
        else { throw UpdateServiceError.invalidApplication("包标识或版本与发布元数据不一致") }

        var staticCode: SecStaticCode?
        let creationStatus = SecStaticCodeCreateWithPath(
            applicationURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard creationStatus == errSecSuccess, let staticCode else {
            throw UpdateServiceError.codeSignature("无法读取签名（\(creationStatus)）")
        }

        let requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamIdentifier)\" and identifier \"\(expectedBundleIdentifier)\""
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirementText as CFString,
            SecCSFlags(),
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            throw UpdateServiceError.codeSignature("无法建立发布者要求（\(requirementStatus)）")
        }

        // Swift does not import the expiration/revocation SecCSFlags constants declared in
        // CSCommon.h. These are Apple's public bit values from that header. The explicit
        // `anchor apple generic` requirement above supplies the trusted-anchor constraint;
        // kSecCSCheckTrustedAnchors is not a valid flag for this static-code API on current macOS.
        let considerExpiration = UInt32(1) << 31
        let enforceRevocationChecks = UInt32(1) << 30
        let validationBits = kSecCSCheckGatekeeperArchitectures
            | kSecCSCheckNestedCode
            | kSecCSStrictValidate
            | kSecCSRestrictSymlinks
            | kSecCSRestrictToAppLike
            | considerExpiration
            | enforceRevocationChecks
            | kSecCSAllowNetworkAccess
        var validationError: Unmanaged<CFError>?
        let validationStatus = SecStaticCodeCheckValidityWithErrors(
            staticCode,
            SecCSFlags(rawValue: validationBits),
            requirement,
            &validationError
        )
        guard validationStatus == errSecSuccess else {
            let detail = validationError?.takeRetainedValue().localizedDescription
                ?? "Security.framework 错误 \(validationStatus)"
            throw UpdateServiceError.codeSignature(detail)
        }

        var signingInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSContentInformation),
            &signingInformation
        )
        guard informationStatus == errSecSuccess,
              let information = signingInformation as? [String: Any],
              information[kSecCodeInfoTeamIdentifier as String] as? String == expectedTeamIdentifier,
              let ticket = information[kSecCodeInfoStapledNotarizationTicket as String] as? Data,
              !ticket.isEmpty
        else { throw UpdateServiceError.codeSignature("缺少匹配的 Team ID 或随附公证票据") }

        return VerifiedUpdateApplication(
            bundleIdentifier: identifier,
            version: version,
            teamIdentifier: expectedTeamIdentifier
        )
    }
}

struct TarGzipUpdateExtractor: UpdateArchiveExtracting, @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func extract(archiveURL: URL, destinationURL: URL) throws -> URL {
        let archiveValues = try archiveURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard archiveValues.isRegularFile == true, archiveValues.isSymbolicLink != true else {
            throw UpdateServiceError.archiveExtraction("更新包不是普通文件")
        }
        try ensureEmptyDirectory(destinationURL)
        let listing = try runTar(["-tzf", archiveURL.path], temporaryDirectory: destinationURL)
        let entries = listing.split(whereSeparator: \.isNewline).map(String.init)
        guard !entries.isEmpty, entries.count <= 100_000 else {
            throw UpdateServiceError.archiveExtraction("归档目录为空或条目过多")
        }

        var topLevelName: String?
        for rawEntry in entries {
            var entry = rawEntry
            while entry.hasPrefix("./") { entry.removeFirst(2) }
            let components = entry.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !entry.hasPrefix("/"), !entry.contains("\0"), !components.isEmpty,
                  !components.contains("."), !components.contains("..")
            else { throw UpdateServiceError.archiveExtraction("归档包含越界路径") }
            if topLevelName == nil { topLevelName = components[0] }
            guard components[0] == topLevelName else {
                throw UpdateServiceError.archiveExtraction("归档必须只包含一个应用包")
            }
        }
        guard let topLevelName, topLevelName.hasSuffix(".app") else {
            throw UpdateServiceError.archiveExtraction("归档顶层不是 .app")
        }

        _ = try runTar(
            ["-xzf", archiveURL.path, "-C", destinationURL.path],
            temporaryDirectory: destinationURL,
            captureStandardOutput: false
        )
        let applicationURL = destinationURL.appendingPathComponent(topLevelName, isDirectory: true)
        let values = try applicationURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw UpdateServiceError.archiveExtraction("解包结果不是普通应用目录")
        }
        try validateSymlinks(inside: applicationURL)
        return applicationURL
    }

    private func ensureEmptyDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  try fileManager.contentsOfDirectory(atPath: url.path).isEmpty
            else { throw UpdateServiceError.archiveExtraction("解包目录并非安全空目录") }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func validateSymlinks(inside applicationURL: URL) throws {
        let root = applicationURL.standardizedFileURL.path + "/"
        guard let enumerator = fileManager.enumerator(
            at: applicationURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { throw UpdateServiceError.archiveExtraction("无法检查解包内容") }
        for case let item as URL in enumerator {
            guard try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true else {
                continue
            }
            let resolved = item.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(root) else {
                throw UpdateServiceError.archiveExtraction("应用包包含指向外部的符号链接")
            }
        }
    }

    private func runTar(
        _ arguments: [String],
        temporaryDirectory: URL,
        captureStandardOutput: Bool = true
    ) throws -> String {
        let token = UUID().uuidString
        let stdoutURL = temporaryDirectory.appendingPathComponent(".tar-\(token).stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent(".tar-\(token).stderr")
        defer {
            try? fileManager.removeItem(at: stdoutURL)
            try? fileManager.removeItem(at: stderrURL)
        }
        guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
              fileManager.createFile(atPath: stderrURL.path, contents: nil)
        else { throw UpdateServiceError.archiveExtraction("无法建立受限的解包日志") }
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.standardOutput = captureStandardOutput ? stdout : FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        let stdoutLimit: off_t = captureStandardOutput ? 16 * 1_024 * 1_024 : 0
        let stderrLimit: off_t = 1 * 1_024 * 1_024
        while process.isRunning {
            if (captureStandardOutput && fileSize(stdout) > stdoutLimit)
                || fileSize(stderr) > stderrLimit
            {
                process.terminate()
                process.waitUntilExit()
                throw UpdateServiceError.archiveExtraction("归档目录或错误输出超过安全上限")
            }
            usleep(10_000)
        }
        process.waitUntilExit()
        try stdout.synchronize()
        try stderr.synchronize()
        let errorData = try Data(contentsOf: stderrURL)
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errorData.prefix(4_096), as: UTF8.self)
            throw UpdateServiceError.archiveExtraction(detail)
        }
        guard captureStandardOutput else { return "" }
        let attributes = try fileManager.attributesOfItem(atPath: stdoutURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 16 * 1_024 * 1_024 else {
            throw UpdateServiceError.archiveExtraction("归档目录列表过大")
        }
        return String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self)
    }

    private func fileSize(_ handle: FileHandle) -> off_t {
        var information = stat()
        guard fstat(handle.fileDescriptor, &information) == 0 else { return .max }
        return information.st_size
    }
}

struct AtomicUpdateInstaller: UpdateApplicationInstalling, @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prepare(stagedApplicationURL: URL, currentApplicationURL: URL) throws -> URL {
        let parent = currentApplicationURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parent.path),
              try currentApplicationURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try currentApplicationURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
        else { throw UpdateServiceError.installation("当前应用所在目录不可安全写入") }
        let prepared = parent.appendingPathComponent(
            ".CCBuddy.update-\(UUID().uuidString).app",
            isDirectory: true
        )
        do {
            try fileManager.copyItem(at: stagedApplicationURL, to: prepared)
            return prepared
        } catch {
            try? fileManager.removeItem(at: prepared)
            throw UpdateServiceError.installation(error.localizedDescription)
        }
    }

    func commit(preparedApplicationURL: URL, currentApplicationURL: URL) throws -> URL {
        try validatePreparedURL(preparedApplicationURL, beside: currentApplicationURL)
        let result = preparedApplicationURL.path.withCString { prepared in
            currentApplicationURL.path.withCString { current in
                renameatx_np(AT_FDCWD, prepared, AT_FDCWD, current, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw UpdateServiceError.installation(
                POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription
            )
        }
        return preparedApplicationURL
    }

    func rollback(backupApplicationURL: URL, currentApplicationURL: URL) throws {
        _ = try commit(preparedApplicationURL: backupApplicationURL, currentApplicationURL: currentApplicationURL)
    }

    func discardPreparedApplication(at url: URL) {
        guard url.lastPathComponent.hasPrefix(".CCBuddy.update-"), url.pathExtension == "app" else { return }
        try? fileManager.removeItem(at: url)
    }

    private func validatePreparedURL(_ prepared: URL, beside current: URL) throws {
        guard prepared.deletingLastPathComponent().standardizedFileURL
                == current.deletingLastPathComponent().standardizedFileURL,
              prepared.lastPathComponent.hasPrefix(".CCBuddy.update-"),
              prepared.pathExtension == "app"
        else { throw UpdateServiceError.installation("待替换应用不在目标目录中") }
    }
}
