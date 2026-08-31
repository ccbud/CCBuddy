import Foundation

enum UsageHistoryLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

struct UsageHistoryConfiguration: Equatable, Sendable {
    var historyDirs: [String]
    var active: String
    var homeDirectory: URL

    init(
        historyDirs: [String],
        active: String = "all",
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.historyDirs = historyDirs
        self.active = active.isEmpty ? "all" : active
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    var activeRoots: [URL] {
        var configured: [(raw: String, url: URL)] = []
        var seen = Set<String>()
        for raw in historyDirs where !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = HistoryPathResolver.expandTilde(raw, homeDirectory: homeDirectory)
                .resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            configured.append((raw, url))
        }

        if active != "all" {
            let selected = configured.filter { $0.raw == active }.map(\.url)
            if !selected.isEmpty { return selected }
        }
        // Synthetic imported/trash scopes and stale selectors intentionally fall back to all
        // configured roots, matching the legacy usage service.
        return configured.map(\.url)
    }

    var cacheSignature: String {
        ([active] + activeRoots.map(\.path)).joined(separator: "\u{0}")
    }
}

struct UsageHistoryDay: Equatable, Sendable {
    var tokens = 0
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheCreation = 0
    var requests = 0
    var models: [String: Int] = [:]
    var providers: [String: Int] = [:]
    var hours: [Int: Int] = [:]
}

struct UsageHistoryShare: Equatable, Identifiable, Sendable {
    let name: String
    let tokens: Int
    let percentage: Double

    var id: String { name }
}

struct UsageHistoryHeatmapCell: Equatable, Identifiable, Sendable {
    let date: String
    let tokens: Int
    let level: Int

    var id: String { date }
}

/// History-derived usage payload matching the legacy `usage_get` response without coupling it
/// to a particular view. Provider buckets remain available for future transcript metadata; the
/// legacy Claude/Codex readers currently attribute tokens by model only.
struct UsageHistorySummary: Equatable, Sendable {
    let range: UsageRange
    let tokens: Int
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheCreation: Int
    let requests: Int
    let activeDays: Int
    let peakHour: Int?
    let favoriteModel: String?
    let favoriteProvider: String?
    let byModel: [UsageHistoryShare]
    let byProvider: [UsageHistoryShare]
    let currentStreak: Int
    let longestStreak: Int
    let heatmap: [UsageHistoryHeatmapCell]

    func resolvingFavoriteProvider(
        providers: [Provider],
        activeProviderID: String?
    ) -> UsageHistorySummary {
        guard favoriteProvider == nil,
              let resolved = UsageHistoryProviderAttribution.providerName(
                  for: favoriteModel,
                  providers: providers,
                  activeProviderID: activeProviderID
              )
        else { return self }

        return UsageHistorySummary(
            range: range,
            tokens: tokens,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheCreation: cacheCreation,
            requests: requests,
            activeDays: activeDays,
            peakHour: peakHour,
            favoriteModel: favoriteModel,
            favoriteProvider: resolved,
            byModel: byModel,
            byProvider: byProvider,
            currentStreak: currentStreak,
            longestStreak: longestStreak,
            heatmap: heatmap
        )
    }
}

/// History files identify models but generally do not record the configured CC Buddy provider.
/// Attribute the favorite model only when the configuration makes that relationship unambiguous.
/// An explicitly active matching provider wins; otherwise exactly one matching provider is
/// required so shared upstream model names never receive a misleading service label.
enum UsageHistoryProviderAttribution {
    static func providerName(
        for favoriteModel: String?,
        providers: [Provider],
        activeProviderID: String?
    ) -> String? {
        guard let favoriteModel = nonempty(favoriteModel) else { return nil }
        let matches = providers.filter { provider in
            modelNames(for: provider).contains(favoriteModel)
        }
        if let activeProviderID,
           let active = matches.first(where: { $0.id == activeProviderID }) {
            return nonempty(active.name)
        }
        guard matches.count == 1 else { return nil }
        return nonempty(matches[0].name)
    }

    private static func modelNames(for provider: Provider) -> Set<String> {
        var names = [provider.defaultModel, provider.smallFastModel]
        for mapping in provider.models {
            names.append(mapping.alias)
            names.append(mapping.upstream)
        }
        return Set(names.compactMap(nonempty))
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct UsageHistoryEvent: Sendable {
    let timestamp: Date
    let model: String?
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheCreation: Int

    var total: Int { input + output + cacheRead + cacheCreation }
}
