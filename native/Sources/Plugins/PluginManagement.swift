import Foundation

struct PluginDerivedProvider: Equatable, Sendable {
    var id: String
    var pluginID: String
    var name: String
    var baseURL: URL
    var protocolName: String
    var defaultModel: String
    var smallFastModel: String
    var iconDataURI: String?
}

struct PluginCatalogItem: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var version: String
    var summary: String
    var protocolName: String
    var hasSource: Bool
    var isOfficialSource: Bool
    var lifecycle: PluginLifecycleState
    var authentication: PluginAuthenticationSnapshot?
    var actions: [PluginAction]
    var provider: PluginDerivedProvider?
    var iconData: Data?
    var validationMessages: [String]
    var failureMessage: String?
    var latestVersion: String?
    var updateAvailable: Bool

    init(
        id: String,
        name: String,
        version: String = "",
        summary: String = "",
        protocolName: String = "",
        hasSource: Bool = false,
        isOfficialSource: Bool = false,
        lifecycle: PluginLifecycleState = .installed,
        authentication: PluginAuthenticationSnapshot? = nil,
        actions: [PluginAction] = [],
        provider: PluginDerivedProvider? = nil,
        iconData: Data? = nil,
        validationMessages: [String] = [],
        failureMessage: String? = nil,
        latestVersion: String? = nil,
        updateAvailable: Bool = false
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.protocolName = protocolName
        self.hasSource = hasSource
        self.isOfficialSource = isOfficialSource
        self.lifecycle = lifecycle
        self.authentication = authentication
        self.actions = actions
        self.provider = provider
        self.iconData = iconData
        self.validationMessages = validationMessages
        self.failureMessage = failureMessage
        self.latestVersion = latestVersion
        self.updateAvailable = updateAvailable
    }

    var isRunning: Bool { lifecycle == .running }
    var canStart: Bool { validationMessages.isEmpty && lifecycle != .starting && lifecycle != .stopping }

    var lifecycleLabel: String {
        switch lifecycle {
        case .installed, .stopped: return "已停用"
        case .starting: return "正在启动"
        case .running: return "运行中"
        case .stopping: return "正在停止"
        case .failed: return "启动失败"
        }
    }

    var authenticationLabel: String {
        guard let authentication else {
            return isRunning ? "登录状态未知" : "插件未运行"
        }
        return switch authentication.state {
        case .loggedIn:
            authentication.account.map { "已登录 · \($0)" } ?? "已登录"
        case .expired: "登录已过期"
        case .loggedOut: "未登录"
        case .unknown: isRunning ? "登录状态未知" : "插件未运行"
        }
    }
}

struct PluginCatalogIssue: Equatable, Sendable {
    var location: String
    var message: String
}

struct PluginCatalogSnapshot: Equatable, Sendable {
    var items: [PluginCatalogItem]
    var issues: [PluginCatalogIssue]

    static let empty = PluginCatalogSnapshot(items: [], issues: [])
}

enum PluginManagementError: Error, LocalizedError, Equatable, Sendable {
    case pluginNotFound(String)
    case pluginNotRunning(String)
    case actionNotFound(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .pluginNotFound(let id): return "未找到插件“\(id)”"
        case .pluginNotRunning(let id): return "请先启用插件“\(id)”"
        case .actionNotFound(let id): return "未找到插件操作“\(id)”"
        case .operationFailed(let message): return message
        }
    }
}

protocol PluginManaging: Sendable {
    func catalog(ensureRuntimeRecords: Bool) async -> PluginCatalogSnapshot
    func setEnabled(id: String, enabled: Bool) async throws -> PluginCatalogItem
    func waitForExit(id: String) async -> PluginCatalogItem?
    func install(from source: URL) async throws -> String
    func installFromGit(_ source: String) async throws -> String
    func uninstall(id: String) async throws
    func checkForUpdate(id: String) async throws -> PluginUpdateStatus
    func update(id: String) async throws -> String
    func loadAction(pluginID: String, actionID: String) async throws -> PluginActionResponse
    func submitAction(
        pluginID: String,
        actionID: String,
        values: [String: PluginJSONValue]
    ) async throws -> PluginActionResponse
    func pluginsDirectory() async -> URL
    func shutdown() async
}

/// A read-only catalog used only by the doubly gated legacy-smoke UI visual fixture. It has no
/// filesystem-backed repository or process supervisor, so loading the Plugins page cannot touch
/// application state outside the test process.
struct LegacySmokeVisualPluginManager: PluginManaging {
    private static let item = PluginCatalogItem(
        id: "demo",
        name: "Demo",
        version: "1.0.0",
        protocolName: "anthropic",
        lifecycle: .stopped,
        authentication: .init(
            state: .loggedOut,
            account: nil,
            message: nil,
            values: [:]
        ),
        actions: [PluginAction(values: [
            "id": .string("a1"),
            "label": .string("Do"),
            "kind": .string("call"),
        ])]
    )

    private var mutationError: PluginManagementError {
        .operationFailed("The visual fixture is read-only")
    }

    func catalog(ensureRuntimeRecords: Bool) async -> PluginCatalogSnapshot {
        .init(items: [Self.item], issues: [])
    }

    func setEnabled(id: String, enabled: Bool) async throws -> PluginCatalogItem {
        throw mutationError
    }

    func waitForExit(id: String) async -> PluginCatalogItem? { Self.item }
    func install(from source: URL) async throws -> String { throw mutationError }
    func installFromGit(_ source: String) async throws -> String { throw mutationError }
    func uninstall(id: String) async throws { throw mutationError }
    func checkForUpdate(id: String) async throws -> PluginUpdateStatus { throw mutationError }
    func update(id: String) async throws -> String { throw mutationError }
    func loadAction(pluginID: String, actionID: String) async throws -> PluginActionResponse {
        throw mutationError
    }
    func submitAction(
        pluginID: String,
        actionID: String,
        values: [String: PluginJSONValue]
    ) async throws -> PluginActionResponse {
        throw mutationError
    }
    func pluginsDirectory() async -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "ccbud-read-only-visual-fixture",
            isDirectory: true
        )
    }
    func shutdown() async {}
}

actor LivePluginManager: PluginManaging {
    private let repository: PluginRepository
    private let supervisor: PluginSidecarSupervisor
    private let controlPlane: PluginControlPlaneClient
    private let portAllocator: any PluginPortAllocating
    private let activity: PluginActivityRegistry
    private let installer: PluginInstaller
    private let gitService: PluginGitService

    init(
        repository: PluginRepository,
        supervisor: PluginSidecarSupervisor? = nil,
        controlPlane: PluginControlPlaneClient = .init(),
        portAllocator: any PluginPortAllocating = PluginDeterministicPortAllocator(),
        commandRunner: PluginCommandRunning = PluginProcessCommandRunner(),
        toolchain: PluginToolchain = .init()
    ) {
        self.repository = repository
        // The manager and supervisor are separate actors. Give the supervisor its own repository
        // adapter so non-Sendable Foundation helpers (FileManager/JSONDecoder) are never shared
        // across actor isolation domains; both adapters still point at the same on-disk layout.
        self.supervisor = supervisor ?? PluginSidecarSupervisor(repository: PluginRepository(
            layout: repository.layout,
            platformKey: repository.platformKey
        ))
        self.controlPlane = controlPlane
        self.portAllocator = portAllocator
        let activity = PluginActivityRegistry()
        self.activity = activity
        let installer = PluginInstaller(repository: repository) { activity.contains($0) }
        self.installer = installer
        gitService = PluginGitService(
            repository: repository,
            installer: installer,
            runner: commandRunner,
            toolchain: toolchain
        )
    }

    func catalog(ensureRuntimeRecords: Bool) async -> PluginCatalogSnapshot {
        let discovery = repository.discover()
        let supervisorStates = await supervisor.states()
        let stateByID = Dictionary(uniqueKeysWithValues: supervisorStates.map { ($0.pluginID, $0) })
        activity.replace(with: Set(supervisorStates.compactMap {
            $0.processIdentifier == nil ? nil : $0.pluginID
        }))

        var reservedPorts = Set<UInt16>()
        var items: [PluginCatalogItem] = []
        for installation in discovery.installations.sorted(by: { $0.id < $1.id }) {
            let state = stateByID[installation.id]
            let port = assignedPort(
                for: installation,
                livePort: state?.processIdentifier == nil ? nil : state?.port,
                ensureRuntimeRecord: ensureRuntimeRecords,
                reserved: &reservedPorts
            )
            let provider = port.flatMap { derivedProvider(for: installation, port: $0) }
            let authentication = await authenticationSnapshot(
                for: installation,
                state: state
            )
            let icon = readIcon(for: installation)
            items.append(.init(
                id: installation.id,
                name: installation.manifest.name,
                version: installation.manifest.version,
                summary: installation.manifest.description,
                protocolName: installation.manifest.endpoint.protocolName,
                hasSource: installation.hasGitSource,
                isOfficialSource: installation.isOfficialSource,
                lifecycle: state?.lifecycle ?? .installed,
                authentication: authentication,
                actions: installation.manifest.userInterface.actions,
                provider: provider.map {
                    var value = $0
                    value.iconDataURI = icon.dataURI
                    return value
                },
                iconData: icon.data,
                validationMessages: installation.validation.errors.map {
                    "\($0.path): \($0.message)"
                },
                failureMessage: state?.failure?.message
            ))
        }

        return .init(
            items: items,
            issues: discovery.issues.map {
                .init(location: $0.directory.lastPathComponent, message: safeMessage($0.message))
            }
        )
    }

    func setEnabled(id: String, enabled: Bool) async throws -> PluginCatalogItem {
        do {
            let snapshot: PluginSidecarSnapshot?
            if enabled {
                // `start` awaits readiness and this actor may re-enter while suspended. Mark the
                // plugin busy before that first await so a concurrent synchronous install cannot
                // replace an executable that is already starting.
                activity.set(id, active: true)
                snapshot = try await supervisor.start(id: id)
            } else {
                snapshot = await supervisor.stop(id: id)
            }
            activity.set(id, active: snapshot?.processIdentifier != nil)
            guard let item = await catalog(ensureRuntimeRecords: true).items.first(where: { $0.id == id }) else {
                throw PluginManagementError.pluginNotFound(id)
            }
            return item
        } catch let error as PluginManagementError {
            throw error
        } catch {
            let state = await supervisor.state(id: id)
            activity.set(id, active: state?.processIdentifier != nil)
            throw managementError(error)
        }
    }

    func waitForExit(id: String) async -> PluginCatalogItem? {
        let state = await supervisor.waitForExit(id: id)
        activity.set(id, active: state?.processIdentifier != nil)
        return await catalog(ensureRuntimeRecords: true).items.first(where: { $0.id == id })
    }

    func install(from source: URL) async throws -> String {
        do {
            return try installer.install(from: source).pluginID
        } catch {
            throw managementError(error)
        }
    }

    func installFromGit(_ source: String) async throws -> String {
        do {
            return try gitService.install(from: source).install.pluginID
        } catch {
            throw managementError(error, explicitSecrets: [source])
        }
    }

    func uninstall(id: String) async throws {
        let state = await supervisor.stop(id: id)
        activity.set(id, active: state?.processIdentifier != nil)
        guard state?.processIdentifier == nil else {
            throw PluginManagementError.operationFailed("插件进程未能停止，未删除任何文件")
        }
        do {
            _ = try installer.uninstall(id: id)
        } catch {
            throw managementError(error)
        }
    }

    func checkForUpdate(id: String) async throws -> PluginUpdateStatus {
        do {
            return try gitService.checkForUpdate(id: id)
        } catch {
            throw managementError(error)
        }
    }

    func update(id: String) async throws -> String {
        let state = await supervisor.stop(id: id)
        activity.set(id, active: state?.processIdentifier != nil)
        guard state?.processIdentifier == nil else {
            throw PluginManagementError.operationFailed("插件进程未能停止，未更新任何文件")
        }
        do {
            return try gitService.update(id: id).install.pluginID
        } catch {
            throw managementError(error)
        }
    }

    func loadAction(pluginID: String, actionID: String) async throws -> PluginActionResponse {
        let (action, descriptor) = try await actionAndDescriptor(pluginID: pluginID, actionID: actionID)
        do {
            return try await controlPlane.load(action: action, for: descriptor)
        } catch {
            throw managementError(error)
        }
    }

    func submitAction(
        pluginID: String,
        actionID: String,
        values: [String: PluginJSONValue]
    ) async throws -> PluginActionResponse {
        let (action, descriptor) = try await actionAndDescriptor(pluginID: pluginID, actionID: actionID)
        do {
            return try await controlPlane.submit(action: action, values: values, for: descriptor)
        } catch {
            throw managementError(error, explicitSecrets: strings(in: values))
        }
    }

    func pluginsDirectory() async -> URL { repository.layout.pluginsRoot }

    func shutdown() async {
        await supervisor.shutdown()
        activity.replace(with: [])
    }

    private func assignedPort(
        for installation: PluginInstallation,
        livePort: UInt16?,
        ensureRuntimeRecord: Bool,
        reserved: inout Set<UInt16>
    ) -> UInt16? {
        if let livePort {
            reserved.insert(livePort)
            return livePort
        }
        let preferred = installation.runtime?.validPort
        guard ensureRuntimeRecord else {
            if let preferred, !reserved.contains(preferred) {
                reserved.insert(preferred)
                return preferred
            }
            return nil
        }
        do {
            let port = try portAllocator.allocate(
                pluginID: installation.id,
                preferred: preferred,
                reserved: reserved
            )
            reserved.insert(port)
            if preferred != port {
                try repository.writeRuntime(.init(port: Int(port)), id: installation.id)
            }
            return port
        } catch {
            return preferred.flatMap { reserved.insert($0).inserted ? $0 : nil }
        }
    }

    private func derivedProvider(
        for installation: PluginInstallation,
        port: UInt16
    ) -> PluginDerivedProvider? {
        guard installation.validation.isValid,
              let baseURL = URL(string: "http://127.0.0.1:\(port)\(installation.manifest.endpoint.basePath)") else {
            return nil
        }
        let manifest = installation.manifest
        return .init(
            id: manifest.providerIdentifier,
            pluginID: installation.id,
            name: manifest.name,
            baseURL: baseURL,
            protocolName: manifest.endpoint.protocolName,
            defaultModel: manifest.modelMapping.primary,
            smallFastModel: manifest.modelMapping.light,
            iconDataURI: nil
        )
    }

    private func authenticationSnapshot(
        for installation: PluginInstallation,
        state: PluginSidecarSnapshot?
    ) async -> PluginAuthenticationSnapshot? {
        guard state?.lifecycle == .running, let port = state?.port,
              let descriptor = try? repository.sidecarDescriptor(id: installation.id, port: port) else {
            return nil
        }
        return try? await controlPlane.authenticationStatus(for: descriptor)
    }

    private func actionAndDescriptor(
        pluginID: String,
        actionID: String
    ) async throws -> (PluginAction, PluginSidecarDescriptor) {
        let installation: PluginInstallation
        do {
            installation = try repository.installation(id: pluginID)
        } catch {
            throw PluginManagementError.pluginNotFound(pluginID)
        }
        guard let action = installation.manifest.userInterface.actions.first(where: { $0.id == actionID }) else {
            throw PluginManagementError.actionNotFound(actionID)
        }
        guard let state = await supervisor.state(id: pluginID), state.lifecycle == .running,
              let port = state.port else {
            throw PluginManagementError.pluginNotRunning(pluginID)
        }
        do {
            return (action, try repository.sidecarDescriptor(id: pluginID, port: port))
        } catch {
            throw managementError(error)
        }
    }

    private func readIcon(for installation: PluginInstallation) -> (data: Data?, dataURI: String?) {
        let relativePath = installation.manifest.icon
        guard !relativePath.isEmpty,
              let url = try? PluginManifestValidator.containedURL(
                  relativePath: relativePath,
                  in: installation.directory
              ),
              let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize <= 1_048_576,
              let data = try? Data(contentsOf: url), !data.isEmpty else {
            return (nil, nil)
        }
        let mime: String
        switch url.pathExtension.lowercased() {
        case "svg": mime = "image/svg+xml"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        default: mime = "image/png"
        }
        return (data, "data:\(mime);base64,\(data.base64EncodedString())")
    }

    private func managementError(
        _ error: Error,
        explicitSecrets: [String] = []
    ) -> PluginManagementError {
        if let error = error as? PluginManagementError { return error }
        let message = PluginSecretRedactor(explicitSecrets: explicitSecrets)
            .redact(error.localizedDescription)
        return .operationFailed(String(message.prefix(512)))
    }

    private func safeMessage(_ message: String) -> String {
        String(PluginSecretRedactor().redact(message).prefix(512))
    }

    private func strings(in values: [String: PluginJSONValue]) -> [String] {
        values.values.flatMap(strings(in:))
    }

    private func strings(in value: PluginJSONValue) -> [String] {
        switch value {
        case .string(let value): return [value]
        case .array(let values): return values.flatMap(strings(in:))
        case .object(let values): return strings(in: values)
        case .number, .bool, .null: return []
        }
    }
}

private final class PluginActivityRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var activeIDs = Set<String>()

    func contains(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeIDs.contains(id)
    }

    func set(_ id: String, active: Bool) {
        lock.lock()
        if active { activeIDs.insert(id) }
        else { activeIDs.remove(id) }
        lock.unlock()
    }

    func replace(with ids: Set<String>) {
        lock.lock()
        activeIDs = ids
        lock.unlock()
    }
}
