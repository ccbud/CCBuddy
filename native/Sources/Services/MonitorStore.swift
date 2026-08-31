import Combine
import Foundation

/// A gateway event rendered in the compact operational log. Process lifecycle entries are appended
/// by AppModel, while request warnings/errors are synthesized only from structured Bifrost fields.
/// Raw process output and provider-owned error text must never be stored here.
struct MonitorLifecycleEvent: Identifiable, Equatable, Sendable {
    enum Level: String, CaseIterable, Sendable {
        case debug
        case info
        case warning
        case error

        init(_ rawValue: String) {
            switch rawValue.lowercased() {
            case "debug", "trace": self = .debug
            case "warn", "warning": self = .warning
            case "error", "fatal": self = .error
            default: self = .info
            }
        }
    }

    let id: UUID
    let sequence: UInt64?
    let timestamp: Date
    let level: Level
    let message: String

    init(
        id: UUID = UUID(),
        sequence: UInt64? = nil,
        timestamp: Date = Date(),
        level: Level = .info,
        message: String
    ) {
        self.id = id
        self.sequence = sequence
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

/// Builds the small subset of request-scoped gateway events that can be shown without parsing
/// Bifrost's process output or copying provider-owned error text into the UI. The retained snapshot
/// makes polling idempotent: an error/retry is reported only when that structured log state first
/// appears or advances.
struct MonitorOperationalEventSynthesizer {
    private static let observationLimit = 200

    private struct Snapshot: Equatable {
        var status: BifrostLogStatus
        var retryCount: Int
    }

    private var observations: [String: Snapshot] = [:]
    private var activeSince: Date?

    mutating func begin(at date: Date = Date()) {
        observations.removeAll(keepingCapacity: true)
        activeSince = date
    }

    mutating func stop() {
        observations.removeAll(keepingCapacity: true)
        activeSince = nil
    }

    mutating func events(for logs: [BifrostLog]) -> [MonitorLifecycleEvent] {
        guard let activeSince else { return [] }
        var events: [MonitorLifecycleEvent] = []

        // Bifrost lists newest first. Process oldest first so two transitions received in one
        // refresh retain their causal order in the gateway log.
        for log in logs.sorted(by: { $0.monitorTimestamp < $1.monitorTimestamp }) {
            guard !log.id.isEmpty else { continue }
            let previous = observations[log.id]
            let current = Snapshot(
                status: log.status,
                // A partially populated/stale row must not make a later poll report the same
                // retry total again.
                retryCount: max(previous?.retryCount ?? 0, max(0, log.numberOfRetries ?? 0))
            )
            observations[log.id] = current

            // A new sidecar can reopen the same persistent Bifrost database. Establish snapshots
            // for older rows, but do not replay operational events from a previous app lifetime.
            let timestamp = log.monitorTimestamp
            guard timestamp != .distantPast,
                  timestamp >= activeSince.addingTimeInterval(-1)
            else { continue }

            let previousRetryCount = previous?.retryCount ?? 0
            if current.retryCount > previousRetryCount {
                events.append(.init(
                    timestamp: timestamp,
                    level: .warning,
                    message: "Bifrost 请求已重试 \(current.retryCount) 次"
                ))
            }

            if current.status == .error, previous?.status != .error {
                let message = log.errorStatusCode.map {
                    "Bifrost 请求失败 · 上游 HTTP \($0)"
                } ?? "Bifrost 请求失败"
                events.append(.init(timestamp: timestamp, level: .error, message: message))
            }
        }
        return events
    }

    /// Request rows are themselves bounded to 100. Keep one extra page of transition history, then
    /// compact to the rows the monitor can still display instead of growing for the app's lifetime.
    @discardableResult
    mutating func limitObservations(retaining requestIDs: Set<String>) -> Int {
        guard observations.count > Self.observationLimit else { return observations.count }
        observations = observations.filter { requestIDs.contains($0.key) }
        return observations.count
    }
}

@MainActor
final class MonitorStore: ObservableObject {
    static let requestLimit = 100
    static let lifecycleLimit = 100
    nonisolated static let activityCoalescingNanoseconds: UInt64 = 120_000_000

    @Published private(set) var requests: [BifrostLog] = []
    @Published private(set) var stats: BifrostLogStats?
    @Published private(set) var lifecycleEvents: [MonitorLifecycleEvent] = []
    @Published private(set) var currentPort: Int?
    @Published private(set) var gatewayRunning = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isClearing = false
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var refreshError: String?

    @Published private(set) var selectedDetail: BifrostLog?
    @Published private(set) var detailRequestID: String?
    @Published private(set) var isLoadingDetail = false
    @Published private(set) var detailError: String?

    private let client: BifrostManagementClient
    private let pollIntervalNanoseconds: UInt64
    private let activityCoalescingNanoseconds: UInt64
    private var pollingTask: Task<Void, Never>?
    private var pollingGeneration = UUID()
    /// Changes only when the management endpoint changes, so a stale destructive operation cannot
    /// clear rows or errors belonging to a newly configured Bifrost instance.
    private var endpointGeneration = UUID()
    private var activeRefreshGeneration: UUID?
    private var requestActivityTask: Task<Void, Never>?
    private var activityRefreshTask: Task<Void, Never>?
    private var activityRefreshGeneration = UUID()
    private var activityRefreshQueued = false
    private var detailGeneration = UUID()
    private var seenLifecycleSequences = Set<UInt64>()
    private var seenLifecycleIDs = Set<UUID>()
    private var operationalEvents = MonitorOperationalEventSynthesizer()
    private let uiTestFixture: MonitorUITestFixture?
    private let legacySmokeVisualFixture: Bool

    init(
        client: BifrostManagementClient,
        pollIntervalNanoseconds: UInt64 = 10_000_000_000,
        requestActivity: AsyncStream<BifrostRequestActivity>? = nil,
        activityCoalescingNanoseconds: UInt64 = MonitorStore.activityCoalescingNanoseconds,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.client = client
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.activityCoalescingNanoseconds = activityCoalescingNanoseconds
        let uiTesting = AppModel.runtimeMode(environment: environment) == .uiTesting
        let usesLegacySmokeVisualFixture = uiTesting
            && AppModel.uiVisualFixture(environment: environment) == .legacySmoke
        legacySmokeVisualFixture = usesLegacySmokeVisualFixture
        uiTestFixture = !usesLegacySmokeVisualFixture
            && uiTesting
            && environment["CCBUD_MONITOR_UI_FIXTURE"] == "1"
            ? Self.makeUITestFixture()
            : nil
        installUITestFixtureIfNeeded()
        if let requestActivity { observeRequestActivity(requestActivity) }
    }

    deinit {
        pollingTask?.cancel()
        requestActivityTask?.cancel()
        activityRefreshTask?.cancel()
    }

    /// Rebinds the client and restarts polling when the gateway port changes. Calling this with the
    /// same values is idempotent, which makes it safe to drive from SwiftUI's `task(id:)`.
    func configure(port: Int, gatewayRunning: Bool) {
        let safePort = (1...65_535).contains(port) ? port : 8_788
        let portChanged = currentPort != safePort
        let runningChanged = self.gatewayRunning != gatewayRunning

        guard portChanged || runningChanged else {
            if legacySmokeVisualFixture {
                installUITestFixtureIfNeeded()
                return
            }
            if gatewayRunning, pollingTask == nil { startPolling() }
            return
        }

        stopPolling()
        currentPort = safePort
        self.gatewayRunning = gatewayRunning

        if portChanged {
            endpointGeneration = UUID()
            client.updatePort(safePort)
            // A different port may be a different Bifrost process. Never merge its UUID space or
            // metrics with the previous endpoint, and invalidate any in-flight detail response.
            requests.removeAll(keepingCapacity: true)
            stats = nil
            lastUpdatedAt = nil
            refreshError = nil
            dismissDetail()
            operationalEvents.stop()
        }

        installUITestFixtureIfNeeded()
        if legacySmokeVisualFixture { return }
        if gatewayRunning {
            operationalEvents.begin()
            startPolling()
        } else {
            operationalEvents.stop()
        }
    }

    func stopPolling() {
        pollingGeneration = UUID()
        pollingTask?.cancel()
        pollingTask = nil
        activeRefreshGeneration = nil
        isRefreshing = false
        cancelActivityRefresh()
    }

    func shutdown() {
        stopPolling()
        requestActivityTask?.cancel()
        requestActivityTask = nil
        operationalEvents.stop()
    }

    @discardableResult
    func refreshNow() async -> Bool {
        guard !legacySmokeVisualFixture else {
            installUITestFixtureIfNeeded()
            return true
        }
        let generation = pollingGeneration
        return await refresh(generation: generation)
    }

    @discardableResult
    func clearAllLogs() async -> Bool {
        guard !legacySmokeVisualFixture else {
            installUITestFixtureIfNeeded()
            return true
        }
        guard !isClearing, !isRefreshing else { return false }
        isClearing = true

        // Freeze the server-side snapshot. Requests created while deletion is running are newer
        // than this boundary and therefore survive the clear operation.
        let cutoff = Date()
        let clearEndpointGeneration = endpointGeneration
        let clearEndpoint = client.snapshotEndpoint()
        let lifecycleIDsAtStart = Set(lifecycleEvents.map(\.id))
        do {
            _ = try await client.clearLogs(through: cutoff, pinnedTo: clearEndpoint)
            guard endpointGeneration == clearEndpointGeneration else {
                isClearing = false
                return false
            }
            requests.removeAll { $0.monitorTimestamp <= cutoff }
            stats = nil
            // Main-actor reentrancy permits delayed/backdated lifecycle events to arrive while the
            // network clear is suspended. Clear the exact frozen history, not events appended
            // after the user acted, regardless of their source timestamp.
            lifecycleEvents.removeAll { lifecycleIDsAtStart.contains($0.id) }
            seenLifecycleSequences = Set(lifecycleEvents.compactMap(\.sequence))
            seenLifecycleIDs = Set(lifecycleEvents.map(\.id))
            operationalEvents.begin(at: cutoff)
            dismissDetail()
            refreshError = nil
            isClearing = false
            if gatewayRunning { _ = await refreshNow() }
            return true
        } catch {
            guard endpointGeneration == clearEndpointGeneration else {
                isClearing = false
                return false
            }
            if let partial = error as? BifrostPartialLogDeleteError {
                removeDeletedRequests(ids: partial.deletedIDs)
                stats = nil
            }
            if !Task.isCancelled { refreshError = error.localizedDescription }
            isClearing = false
            return false
        }
    }

    func loadDetail(id: String) async {
        guard !legacySmokeVisualFixture else {
            dismissDetail()
            return
        }
        let generation = UUID()
        detailGeneration = generation
        detailRequestID = id
        selectedDetail = nil
        detailError = nil
        isLoadingDetail = true
        defer {
            if detailGeneration == generation { isLoadingDetail = false }
        }

        if let fixtureDetail = uiTestFixture?.details[id] {
            await Task.yield()
            guard !Task.isCancelled, detailGeneration == generation else { return }
            selectedDetail = fixtureDetail
            return
        }

        do {
            let detail = try await client.fetchLogDetail(id: id)
                .restoringLegacyRequestedModel()
            guard !Task.isCancelled, detailGeneration == generation else { return }
            selectedDetail = detail
        } catch {
            guard !Task.isCancelled, detailGeneration == generation else { return }
            detailError = error.localizedDescription
        }
    }

    func dismissDetail() {
        detailGeneration = UUID()
        detailRequestID = nil
        selectedDetail = nil
        isLoadingDetail = false
        detailError = nil
    }

    private func removeDeletedRequests(ids: [String]) {
        let deleted = Set(ids)
        guard !deleted.isEmpty else { return }
        requests.removeAll { deleted.contains($0.id) }
        if let detailRequestID, deleted.contains(detailRequestID) { dismissDetail() }
    }

    func appendLifecycle(
        sequence: UInt64? = nil,
        timestamp: Date = Date(),
        level: MonitorLifecycleEvent.Level = .info,
        message: String
    ) {
        appendLifecycle(.init(
            sequence: sequence,
            timestamp: timestamp,
            level: level,
            message: message
        ))
    }

    func appendLifecycle(
        sequence: UInt64? = nil,
        timestamp: Date = Date(),
        level: String,
        message: String
    ) {
        appendLifecycle(
            sequence: sequence,
            timestamp: timestamp,
            level: .init(level),
            message: message
        )
    }

    func appendLifecycle(_ event: MonitorLifecycleEvent) {
        guard !legacySmokeVisualFixture else { return }
        if let sequence = event.sequence {
            guard !seenLifecycleSequences.contains(sequence) else { return }
        }
        guard !seenLifecycleIDs.contains(event.id) else { return }
        if let sequence = event.sequence { seenLifecycleSequences.insert(sequence) }
        seenLifecycleIDs.insert(event.id)
        lifecycleEvents.append(event)
        lifecycleEvents.sort { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            if let left = lhs.sequence, let right = rhs.sequence { return left < right }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        if lifecycleEvents.count > Self.lifecycleLimit {
            lifecycleEvents.removeFirst(lifecycleEvents.count - Self.lifecycleLimit)
            seenLifecycleSequences = Set(lifecycleEvents.compactMap(\.sequence))
            seenLifecycleIDs = Set(lifecycleEvents.map(\.id))
        }
    }

    func ingestLifecycle(_ events: [MonitorLifecycleEvent]) {
        for event in events { appendLifecycle(event) }
    }

    private func startPolling() {
        guard !legacySmokeVisualFixture else { return }
        let generation = UUID()
        pollingGeneration = generation
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.pollingGeneration == generation {
                _ = await self.refresh(generation: generation)
                guard !Task.isCancelled, self.pollingGeneration == generation else { break }
                do {
                    try await Task.sleep(nanoseconds: self.pollIntervalNanoseconds)
                } catch {
                    break
                }
            }
            if self.pollingGeneration == generation { self.pollingTask = nil }
        }
    }

    private func observeRequestActivity(_ activity: AsyncStream<BifrostRequestActivity>) {
        requestActivityTask?.cancel()
        requestActivityTask = Task { @MainActor [weak self] in
            for await event in activity {
                guard !Task.isCancelled else { break }
                guard event == .responseCompleted else { continue }
                self?.queueActivityRefresh()
            }
        }
    }

    private func queueActivityRefresh() {
        guard gatewayRunning, !legacySmokeVisualFixture else { return }
        activityRefreshQueued = true
        guard activityRefreshTask == nil else { return }

        let generation = UUID()
        activityRefreshGeneration = generation
        activityRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.activityRefreshGeneration == generation {
                do {
                    try await Task.sleep(nanoseconds: self.activityCoalescingNanoseconds)
                } catch {
                    break
                }
                guard !Task.isCancelled, self.activityRefreshGeneration == generation else { break }
                self.activityRefreshQueued = false
                let startedRefresh = await self.refreshNow()
                // A periodic/manual refresh may already own the management client. Preserve this
                // completion signal and try again once that refresh has had time to finish.
                if !startedRefresh, self.gatewayRunning {
                    self.activityRefreshQueued = true
                }
                if !self.activityRefreshQueued { break }
            }
            if self.activityRefreshGeneration == generation {
                self.activityRefreshTask = nil
            }
        }
    }

    private func cancelActivityRefresh() {
        activityRefreshGeneration = UUID()
        activityRefreshQueued = false
        activityRefreshTask?.cancel()
        activityRefreshTask = nil
    }

    /// Returns false only when another refresh/clear currently owns the store or the gateway is no
    /// longer available. Once work starts, callers need not retry transport failures aggressively;
    /// the normal ten-second poll remains the recovery path.
    private func refresh(generation: UUID) async -> Bool {
        guard !legacySmokeVisualFixture else {
            installUITestFixtureIfNeeded()
            return true
        }
        guard activeRefreshGeneration == nil else { return false }
        guard !isClearing else { return false }
        guard gatewayRunning else { return false }
        activeRefreshGeneration = generation
        isRefreshing = true
        defer {
            if activeRefreshGeneration == generation {
                activeRefreshGeneration = nil
                isRefreshing = false
            }
        }

        var refreshedAnything = false
        var errors: [String] = []

        do {
            let page = try await client.fetchLogs(limit: Self.requestLimit, offset: 0)
            guard !Task.isCancelled, generation == pollingGeneration else { return true }
            upsert(page.logs)
            refreshedAnything = true
        } catch {
            if !Task.isCancelled { errors.append(error.localizedDescription) }
        }

        guard !Task.isCancelled, generation == pollingGeneration else { return true }
        do {
            // `/api/logs` currently returns unreliable embedded stats. Always use the dedicated
            // endpoint so the four headline cards reflect Bifrost's source of truth.
            stats = try await client.fetchLogStats()
            refreshedAnything = true
        } catch {
            if !Task.isCancelled { errors.append(error.localizedDescription) }
        }

        guard !Task.isCancelled, generation == pollingGeneration else { return true }
        if refreshedAnything { lastUpdatedAt = Date() }
        refreshError = errors.isEmpty ? nil : errors.joined(separator: " · ")
        return true
    }

    /// UUID upsert is essential for Bifrost streaming records: the same request first appears as
    /// `processing`, then becomes a terminal success/error/cancelled record.
    private func upsert(_ incoming: [BifrostLog]) {
        var byID = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0) })
        var accepted: [BifrostLog] = []
        for incomingLog in incoming {
            let log = incomingLog.restoringLegacyRequestedModel()
            if let current = byID[log.id], current.isTerminal, log.isProcessing {
                // Do not let a delayed/stale poll regress a terminal row back to processing.
                continue
            }
            byID[log.id] = log
            accepted.append(log)
        }

        ingestLifecycle(operationalEvents.events(for: accepted))

        requests = byID.values.sorted { lhs, rhs in
            if lhs.monitorTimestamp != rhs.monitorTimestamp {
                return lhs.monitorTimestamp > rhs.monitorTimestamp
            }
            return lhs.id > rhs.id
        }
        if requests.count > Self.requestLimit {
            requests.removeLast(requests.count - Self.requestLimit)
        }
        operationalEvents.limitObservations(retaining: Set(requests.map(\.id)))
    }

    private func installUITestFixtureIfNeeded() {
        if legacySmokeVisualFixture {
            requests.removeAll(keepingCapacity: true)
            stats = nil
            lifecycleEvents.removeAll(keepingCapacity: true)
            seenLifecycleSequences.removeAll(keepingCapacity: true)
            seenLifecycleIDs.removeAll(keepingCapacity: true)
            lastUpdatedAt = nil
            refreshError = nil
            isRefreshing = false
            isClearing = false
            dismissDetail()
            return
        }
        guard let fixture = uiTestFixture else { return }
        requests = fixture.requests
        stats = fixture.stats
        lifecycleEvents = fixture.lifecycleEvents
        seenLifecycleSequences = Set(fixture.lifecycleEvents.compactMap(\.sequence))
        seenLifecycleIDs = Set(fixture.lifecycleEvents.map(\.id))
        lastUpdatedAt = fixture.requests.first?.monitorTimestamp
    }

    private static func makeUITestFixture() -> MonitorUITestFixture {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let id = "ui-monitor-translated"
        let summary = BifrostLog(
            id: id,
            provider: "fixture-upstream",
            selectedKeyName: "Fixture Provider",
            model: "upstream-model",
            alias: "client-model",
            object: "chat_completion",
            timestamp: timestamp,
            status: .success,
            latency: 42,
            cost: 0.001
        )
        let detail = BifrostLog(
            id: id,
            provider: "fixture-upstream",
            selectedKeyName: "Fixture Provider",
            model: "upstream-model",
            alias: "client-model",
            object: "chat_completion",
            timestamp: timestamp,
            status: .success,
            latency: 42,
            cost: 0.001,
            stream: true,
            rawRequest: #"{"authorization":"Bearer ui-secret-token","prompt":"Needle secret"}"#,
            rawResponse: #"{"id":"fixture-response","output":"Needle result"}"#,
            inputHistory: .array([
                .object(["role": .string("user"), "content": .string("Needle client request")]),
            ]),
            outputMessage: .object([
                "role": .string("assistant"), "content": .string("Needle client response"),
            ]),
            additionalFields: [
                "session_id": .string("session-fixture-12345678"),
                "agent_id": .string("subagent-fixture"),
            ]
        )
        return MonitorUITestFixture(
            requests: [summary],
            details: [id: detail],
            stats: BifrostLogStats(
                totalRequests: 1,
                totalTokens: 12,
                promptTokens: 7,
                completionTokens: 5,
                totalCost: 0.001,
                averageLatency: 42,
                successRate: 100
            ),
            lifecycleEvents: [
                MonitorLifecycleEvent(
                    sequence: 1,
                    timestamp: timestamp,
                    level: .info,
                    message: "Authorization: Bearer ui-lifecycle-secret"
                ),
            ]
        )
    }
}

private struct MonitorUITestFixture {
    let requests: [BifrostLog]
    let details: [String: BifrostLog]
    let stats: BifrostLogStats
    let lifecycleEvents: [MonitorLifecycleEvent]
}

extension BifrostLog {
    var monitorTimestamp: Date {
        timestamp ?? createdAt ?? .distantPast
    }
}
