import Foundation

/// Build with the two production semantic-search services; no application or network required.
@main
struct SemanticSearchBenchmark {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let candidates = [
            SemanticSearchCandidate(id: "appearance", text: "Arrange the sidebar icons and change the background color."),
            SemanticSearchCandidate(id: "authentication", text: "Renew credentials to restore access to the service."),
            SemanticSearchCandidate(id: "database", text: "Investigate slow database queries and reduce response latency."),
        ]
        let query = "Fix authentication errors when the API key expires."
        var measurements: [[String: Any]] = []
        for cpu in [false, true] {
            let service = LocalSemanticSearch(resourceDirectory: directory, forceCPU: cpu)
            let cold = try await service.rank(query: query, candidates: candidates)
            guard cold.diagnostics.state == .ready, cold.orderedIDs.first == "authentication"
            else { fatalError("Real-model semantic ranking failed: \(cold)") }
            let warm = try await service.rank(query: query, candidates: candidates)
            var inferenceSamples: [Double] = []
            for iteration in 0..<10 {
                // Vary text to bypass the vector cache and measure actual model predictions.
                let result = try await service.rank(query: query + " Request \(iteration).", candidates: candidates)
                inferenceSamples.append(result.diagnostics.durationMilliseconds)
            }
            measurements.append([
                "compute_policy": cold.diagnostics.computePolicy.rawValue,
                "model": cold.diagnostics.modelName,
                "cold_rank_ms": cold.diagnostics.durationMilliseconds,
                "cached_rank_ms": warm.diagnostics.durationMilliseconds,
                "cached_rank_hits": warm.diagnostics.cacheHitCount,
                "uncached_query_rank_ms": inferenceSamples,
                "neural_engine_preferred_operations": cold.diagnostics.neuralEnginePreferredOperationCount as Any,
                "planned_operations": cold.diagnostics.totalPlannedOperationCount as Any,
                "ordered_ids": cold.orderedIDs,
                "scores": cold.scores,
                "detail": cold.diagnostics.detail,
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "measurements": measurements,
        ], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
