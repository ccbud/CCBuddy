import Foundation

struct UpdateSemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    private enum Identifier: Hashable, Sendable {
        case numeric(Int)
        case text(String)
    }

    let major: Int
    let minor: Int
    let patch: Int
    private let prerelease: [Identifier]
    private let buildMetadata: [String]

    init?(_ source: String) {
        var raw = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.utf8.count <= 128 else { return nil }
        if raw.first == "v" { raw.removeFirst() }

        let buildParts = raw.split(separator: "+", omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { return nil }
        let precedence = buildParts[0]
        let build = buildParts.count == 2 ? String(buildParts[1]) : ""
        let precedenceParts = precedence.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = precedenceParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.parseCoreNumber(core[0]),
              let minor = Self.parseCoreNumber(core[1]),
              let patch = Self.parseCoreNumber(core[2])
        else { return nil }

        let prereleaseText = precedenceParts.count == 2 ? String(precedenceParts[1]) : ""
        guard precedenceParts.count == 1 || !prereleaseText.isEmpty else { return nil }
        guard buildParts.count == 1 || !build.isEmpty else { return nil }
        guard let prerelease = Self.parseIdentifiers(prereleaseText, numericAware: true),
              let buildIdentifiers = Self.parseBuildIdentifiers(build)
        else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        buildMetadata = buildIdentifiers
    }

    var description: String {
        var result = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty {
            result += "-" + prerelease.map {
                switch $0 {
                case .numeric(let value): String(value)
                case .text(let value): value
                }
            }.joined(separator: ".")
        }
        if !buildMetadata.isEmpty { result += "+" + buildMetadata.joined(separator: ".") }
        return result
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let leftCore = [lhs.major, lhs.minor, lhs.patch]
        let rightCore = [rhs.major, rhs.minor, rhs.patch]
        if leftCore != rightCore { return leftCore.lexicographicallyPrecedes(rightCore) }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        for index in 0..<min(lhs.prerelease.count, rhs.prerelease.count) {
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            guard left != right else { continue }
            switch (left, right) {
            case (.numeric(let first), .numeric(let second)): return first < second
            case (.numeric, .text): return true
            case (.text, .numeric): return false
            case (.text(let first), .text(let second)): return first < second
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
            && lhs.prerelease == rhs.prerelease
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
        hasher.combine(prerelease)
    }

    private static func parseCoreNumber(_ value: Substring) -> Int? {
        guard !value.isEmpty, value.allSatisfy(\.isASCIIWholeNumber),
              value.count == 1 || value.first != "0"
        else { return nil }
        return Int(value)
    }

    private static func parseIdentifiers(_ raw: String, numericAware: Bool) -> [Identifier]? {
        guard !raw.isEmpty else { return [] }
        let values = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard values.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isSemanticVersionCharacter) }) else {
            return nil
        }
        var result: [Identifier] = []
        for value in values {
            if numericAware, value.allSatisfy(\.isASCIIWholeNumber) {
                guard value.count == 1 || value.first != "0", let number = Int(value) else { return nil }
                result.append(.numeric(number))
            } else {
                result.append(.text(String(value)))
            }
        }
        return result
    }

    private static func parseBuildIdentifiers(_ raw: String) -> [String]? {
        guard !raw.isEmpty else { return [] }
        let values = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard values.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isSemanticVersionCharacter) }) else {
            return nil
        }
        return values.map(String.init)
    }
}

struct UpdateRelease: Equatable, Sendable {
    let version: UpdateSemanticVersion
    let notes: String?
    let publishedAt: Date?
    let artifactURL: URL?
    let encodedSignature: String?
    let expectedSHA256: String?
    let releasePageURL: URL
}

struct StagedUpdate: Equatable, Sendable {
    let release: UpdateRelease
    let directoryURL: URL
    let applicationURL: URL
    let artifactSHA256: String
}

struct InstalledUpdate: Equatable, Sendable {
    let staged: StagedUpdate
    let applicationURL: URL
    let backupApplicationURL: URL
}

enum UpdateRestartChoice: Equatable, Sendable {
    case restartNow
    case later
}

struct UpdateRestartPrompt: Equatable, Sendable {
    let title: String
    let message: String
    let restartButtonTitle: String
    let laterButtonTitle: String

    init(language: AppLanguage, version: String) {
        switch language {
        case .simplifiedChinese:
            title = "更新已就绪"
            message = "新版本 \(version) 已自动下载完成。是否立即重启以应用新版本？"
            restartButtonTitle = "立即重启"
            laterButtonTitle = "稍后"
        case .traditionalChinese:
            title = "更新已就緒"
            message = "新版本 \(version) 已自動下載完成。要立即重新啟動以套用新版本嗎？"
            restartButtonTitle = "立即重啟"
            laterButtonTitle = "稍後"
        case .japanese:
            title = "アップデートの準備ができました"
            message = "新しいバージョン \(version) のダウンロードが完了しました。今すぐ再起動して適用しますか？"
            restartButtonTitle = "今すぐ再起動"
            laterButtonTitle = "後で"
        case .korean:
            title = "업데이트 준비 완료"
            message = "새 버전 \(version) 다운로드가 완료되었습니다. 지금 다시 시작하여 적용할까요?"
            restartButtonTitle = "지금 다시 시작"
            laterButtonTitle = "나중에"
        case .english:
            title = "Update ready"
            message = "Version \(version) has been downloaded. Restart now to switch to the new version?"
            restartButtonTitle = "Restart now"
            laterButtonTitle = "Later"
        }
    }
}

enum UpdateState: Equatable, Sendable {
    case idle(currentVersion: String)
    case checking(currentVersion: String)
    case upToDate(currentVersion: String, checkedAt: Date)
    case available(UpdateRelease)
    case downloading(UpdateRelease)
    case staged(StagedUpdate)
    case installing(StagedUpdate)
    case installed(InstalledUpdate)
    /// The replacement is already committed on disk while this process continues running the
    /// previous executable. A normal quit and launch will therefore start the installed version.
    case installedAwaitingRestart(InstalledUpdate)
    case manualDownload(UpdateRelease?, reason: String)
    case failed(currentVersion: String, message: String)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing: true
        default: false
        }
    }
}

enum UpdateServiceError: LocalizedError, Equatable, Sendable {
    case invalidCurrentVersion(String)
    case insecureURL(String)
    case untrustedHost(String)
    case invalidHTTPResponse
    case transport(String)
    case httpStatus(Int)
    case responseTooLarge
    case invalidMetadata(String)
    case invalidReleaseVersion(String)
    case unsupportedPlatform(String)
    case missingTrustMaterial
    case invalidSignature
    case digestMismatch
    case unsafeStaging(String)
    case archiveExtraction(String)
    case invalidApplication(String)
    case codeSignature(String)
    case installation(String)
    case busy
    case noAvailableUpdate
    case noStagedUpdate

    var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion(let version): "当前版本号无效：\(version)"
        case .insecureURL: "更新服务拒绝非 HTTPS 地址。"
        case .untrustedHost: "更新地址不属于受信任的发布主机。"
        case .invalidHTTPResponse: "更新服务器返回了无效响应。"
        case .transport(let detail): "无法连接更新服务器：\(detail)"
        case .httpStatus(let status): "更新服务器返回 HTTP \(status)。"
        case .responseTooLarge: "更新响应超过安全大小限制。"
        case .invalidMetadata(let detail): "更新元数据无效：\(detail)"
        case .invalidReleaseVersion(let version): "发布版本号无效：\(version)"
        case .unsupportedPlatform: "当前 Mac 架构没有可用的完整更新。"
        case .missingTrustMaterial: "发布元数据缺少可信签名，不能在应用内安装。"
        case .invalidSignature: "更新包的发布者签名无效。"
        case .digestMismatch: "更新包完整性校验失败。"
        case .unsafeStaging(let detail): "更新暂存目录不安全：\(detail)"
        case .archiveExtraction(let detail): "无法安全解包更新：\(detail)"
        case .invalidApplication(let detail): "更新中的应用无效：\(detail)"
        case .codeSignature(let detail): "更新未通过 Developer ID 或公证验证：\(detail)"
        case .installation(let detail): "无法安装更新：\(detail)"
        case .busy: "另一项更新操作正在进行。"
        case .noAvailableUpdate: "没有可下载的更新。"
        case .noStagedUpdate: "没有已验证的待安装更新。"
        }
    }

    var requiresManualDownload: Bool {
        switch self {
        case .insecureURL, .untrustedHost, .unsupportedPlatform, .missingTrustMaterial,
             .invalidSignature, .digestMismatch, .unsafeStaging, .archiveExtraction,
             .invalidApplication, .codeSignature, .installation:
            true
        default:
            false
        }
    }
}

private extension Character {
    var isASCIIWholeNumber: Bool { isASCII && wholeNumberValue != nil }
    var isSemanticVersionCharacter: Bool { isASCII && (isLetter || isNumber || self == "-") }
}
