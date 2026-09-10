import Accelerate
import CoreML
import CryptoKit
import Foundation

struct SemanticSearchCandidate: Equatable, Sendable {
    let id: String
    let text: String
}

struct SemanticSearchDiagnostics: Equatable, Sendable {
    enum State: String, Sendable { case ready, unsupportedLanguage, unavailable }
    enum ComputePolicy: String, Sendable { case cpuAndNeuralEngine, cpuOnly }

    var state: State
    var computePolicy: ComputePolicy
    /// Core ML's anticipated placement, not hardware-utilization telemetry. Nil means the OS
    /// cannot expose the plan (macOS 13 / 14.0–14.3) or the plan could not be inspected.
    var neuralEnginePreferredOperationCount: Int? = nil
    var totalPlannedOperationCount: Int? = nil
    var durationMilliseconds: Double = 0
    var embeddedCount: Int = 0
    var cacheHitCount: Int = 0
    var cachedEmbeddingCount: Int = 0
    var modelName: String = "MiniLM-L6-v2 · 384D · int8"
    var detail: String = ""
}

struct SemanticSearchResult: Equatable, Sendable {
    let orderedIDs: [String]
    let scores: [String: Float]
    let diagnostics: SemanticSearchDiagnostics
}

protocol SemanticSearchRanking: Sendable {
    func rank(query: String, candidates: [SemanticSearchCandidate]) async throws -> SemanticSearchResult
}

enum SemanticSearchError: Error {
    case missingModel, invalidVocabulary, invalidEmbedding
}

/// Offline, opt-in reranking of already-authorized search candidates. The service never scans
/// files, discovers extra conversations, persists text, or sends data to a model provider.
/// Serial actor isolation bounds memory and keeps synchronous Core ML work off the UI actor.
actor LocalSemanticSearch: SemanticSearchRanking {
    static let shared = LocalSemanticSearch()
    static let candidateLimit = 32
    static let cacheLimit = 512

    private struct PreparedModel: @unchecked Sendable {
        // Published once by preparation, subsequently used only by this actor.
        let model: MLModel
        let tokenizer: SemanticWordPieceTokenizer
        let computePolicy: SemanticSearchDiagnostics.ComputePolicy
        let neuralEnginePreferredOperationCount: Int?
        let totalPlannedOperationCount: Int?
        let detail: String
    }

    private struct CachedEmbedding {
        let vector: [Float]
        var lastAccess: UInt64
    }

    private let resourceDirectory: URL?
    private let forceCPU: Bool
    private var preparation: Task<PreparedModel, Error>?
    private var cache: [String: CachedEmbedding] = [:]
    private var accessCounter: UInt64 = 0

    /// resourceDirectory and forceCPU support reproducible offline benchmarks and Intel parity
    /// tests. Production resolves signed resources from Bundle.main and chooses by architecture.
    init(resourceDirectory: URL? = nil, forceCPU: Bool = false) {
        self.resourceDirectory = resourceDirectory
        self.forceCPU = forceCPU
    }

    func rank(query: String, candidates: [SemanticSearchCandidate]) async throws -> SemanticSearchResult {
        let start = ContinuousClock.now
        try Task.checkCancellation()
        let policy = Self.computePolicy(forceCPU: forceCPU)
        var diagnostic = SemanticSearchDiagnostics(state: .ready, computePolicy: policy)
        func unchanged(_ diagnostic: SemanticSearchDiagnostics) -> SemanticSearchResult {
            SemanticSearchResult(orderedIDs: candidates.map(\.id), scores: [:], diagnostics: diagnostic)
        }
        guard Self.supports(query: query) else {
            diagnostic.state = .unsupportedLanguage
            diagnostic.detail = "This model supports English and code queries. Keyword order is preserved for other languages."
            return unchanged(diagnostic)
        }
        guard !candidates.isEmpty else { return unchanged(diagnostic) }

        do {
            let prepared = try await prepare()
            try Task.checkCancellation()
            diagnostic.computePolicy = prepared.computePolicy
            diagnostic.neuralEnginePreferredOperationCount = prepared.neuralEnginePreferredOperationCount
            diagnostic.totalPlannedOperationCount = prepared.totalPlannedOperationCount
            diagnostic.detail = prepared.detail
            let queryVector = try embedding(query, prepared: prepared, diagnostic: &diagnostic)
            var scored: [(index: Int, candidate: SemanticSearchCandidate, score: Float)] = []
            for (index, candidate) in candidates.prefix(Self.candidateLimit).enumerated() {
                try Task.checkCancellation()
                let vector = try embedding(candidate.text, prepared: prepared, diagnostic: &diagnostic)
                var cosine: Float = 0
                vDSP_dotpr(queryVector, 1, vector, 1, &cosine, vDSP_Length(queryVector.count))
                scored.append((index, candidate, cosine))
            }
            try Task.checkCancellation()
            // Exact ties retain retrieval order; duplicate IDs must never trap dictionary creation.
            scored.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
            var scores: [String: Float] = [:]
            for item in scored { scores[item.candidate.id] = item.score }
            diagnostic.cachedEmbeddingCount = cache.count
            diagnostic.durationMilliseconds = Self.milliseconds(since: start)
            return SemanticSearchResult(
                orderedIDs: scored.map { $0.candidate.id } + candidates.dropFirst(Self.candidateLimit).map(\.id),
                scores: scores, diagnostics: diagnostic)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            diagnostic.state = .unavailable
            // Avoid exposing filesystem paths, user text, or framework error dumps in the UI.
            diagnostic.detail = "Local semantic model unavailable. Keyword results remain available."
            diagnostic.durationMilliseconds = Self.milliseconds(since: start)
            diagnostic.cachedEmbeddingCount = cache.count
            return unchanged(diagnostic)
        }
    }

    /// English MiniLM is not a multilingual model. Non-Latin text remains fully searchable via
    /// tgrep and exact source/block verification; declining its rerank preserves CJK result order.
    nonisolated static func supports(query: String) -> Bool {
        let letters = query.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return !letters.isEmpty && letters.allSatisfy { $0.value < 0x0250 }
    }

    private func prepare() async throws -> PreparedModel {
        if let preparation { return try await preparation.value }
        let directory = resourceDirectory
        let policy = Self.computePolicy(forceCPU: forceCPU)
        let task = Task.detached(priority: .userInitiated) { () throws -> PreparedModel in
            let resources = try Self.resources(in: directory)
            let tokenizer = try SemanticWordPieceTokenizer(vocabularyURL: resources.vocabulary)
            let modelURL = resources.model.pathExtension == "mlmodelc"
                ? resources.model : try MLModel.compileModel(at: resources.model)
            var actualPolicy = policy
            var configuration = Self.configuration(for: actualPolicy)
            let model: MLModel
            do {
                model = try MLModel(contentsOf: modelURL, configuration: configuration)
            } catch {
                guard actualPolicy == .cpuAndNeuralEngine else { throw error }
                actualPolicy = .cpuOnly
                configuration = Self.configuration(for: actualPolicy)
                model = try MLModel(contentsOf: modelURL, configuration: configuration)
            }
            var preferred: Int?
            var total: Int?
            if #available(macOS 14.4, *) {
                if let plan = try? await MLComputePlan.load(contentsOf: modelURL, configuration: configuration) {
                    let counts = Self.countOperations(in: plan)
                    preferred = counts.preferred
                    total = counts.total
                }
            }
            let detail: String
            if let preferred, let total {
                detail = "Core ML plans \(preferred)/\(total) operations on Neural Engine. Placement is an estimate, not utilization telemetry. All processing stays on this Mac."
            } else if actualPolicy == .cpuAndNeuralEngine {
                detail = "CPU + Neural Engine enabled. Operation placement is unavailable for this run. All processing stays on this Mac."
            } else {
                detail = "Core ML CPU fallback. All processing stays on this Mac."
            }
            return PreparedModel(model: model, tokenizer: tokenizer, computePolicy: actualPolicy,
                                 neuralEnginePreferredOperationCount: preferred,
                                 totalPlannedOperationCount: total, detail: detail)
        }
        preparation = task
        return try await task.value
    }

    private func embedding(_ text: String, prepared: PreparedModel,
                           diagnostic: inout SemanticSearchDiagnostics) throws -> [Float] {
        accessCounter &+= 1
        let key = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        if var hit = cache[key] {
            hit.lastAccess = accessCounter
            cache[key] = hit
            diagnostic.cacheHitCount += 1
            return hit.vector
        }
        let encoded = prepared.tokenizer.encode(text)
        let ids = try MLMultiArray(shape: [1, NSNumber(value: SemanticWordPieceTokenizer.tokenCount)], dataType: .int32)
        let mask = try MLMultiArray(shape: ids.shape, dataType: .int32)
        ids.withUnsafeMutableBufferPointer(ofType: Int32.self) { pointer, _ in
            for index in encoded.inputIDs.indices { pointer[index] = encoded.inputIDs[index] }
        }
        mask.withUnsafeMutableBufferPointer(ofType: Int32.self) { pointer, _ in
            for index in encoded.attentionMask.indices { pointer[index] = encoded.attentionMask[index] }
        }
        let inputs = try MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "attention_mask": mask])
        let result = try prepared.model.prediction(from: inputs)
        guard let output = result.featureValue(for: "embedding")?.multiArrayValue, output.count == 384
        else { throw SemanticSearchError.invalidEmbedding }
        var vector = (0..<output.count).map { output[$0].floatValue }
        guard vector.allSatisfy(\.isFinite) else { throw SemanticSearchError.invalidEmbedding }
        var squaredNorm: Float = 0
        vDSP_svesq(vector, 1, &squaredNorm, vDSP_Length(vector.count))
        guard squaredNorm > 0 else { throw SemanticSearchError.invalidEmbedding }
        var inverseNorm = 1 / sqrt(squaredNorm)
        vector.withUnsafeMutableBufferPointer { pointer in
            vDSP_vsmul(pointer.baseAddress!, 1, &inverseNorm, pointer.baseAddress!, 1, vDSP_Length(pointer.count))
        }
        if cache.count >= Self.cacheLimit, let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            cache.removeValue(forKey: oldest)
        }
        cache[key] = CachedEmbedding(vector: vector, lastAccess: accessCounter)
        diagnostic.embeddedCount += 1
        return vector
    }

    private nonisolated static func resources(in directory: URL?) throws -> (model: URL, vocabulary: URL) {
        let roots: [URL]
        if let directory { roots = [directory] }
        else {
            guard let base = Bundle.main.resourceURL else { throw SemanticSearchError.missingModel }
            roots = [base, base.appendingPathComponent("SemanticSearch", isDirectory: true)]
        }
        let manager = FileManager.default
        let models = roots.flatMap { root in ["mlmodelc", "mlpackage"].map {
            root.appendingPathComponent("MiniLMSemantic.\($0)", isDirectory: true)
        } }
        guard let model = models.first(where: { manager.fileExists(atPath: $0.path) }),
              let vocabulary = roots.map({ $0.appendingPathComponent("minilm-vocab.txt") })
                .first(where: { manager.fileExists(atPath: $0.path) })
        else { throw SemanticSearchError.missingModel }
        return (model, vocabulary)
    }

    private nonisolated static func computePolicy(forceCPU: Bool) -> SemanticSearchDiagnostics.ComputePolicy {
#if arch(arm64)
        forceCPU ? .cpuOnly : .cpuAndNeuralEngine
#else
        .cpuOnly
#endif
    }

    private nonisolated static func configuration(for policy: SemanticSearchDiagnostics.ComputePolicy) -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = policy == .cpuAndNeuralEngine ? .cpuAndNeuralEngine : .cpuOnly
        if #available(macOS 15.0, *) {
            configuration.optimizationHints.specializationStrategy = .fastPrediction
        }
        return configuration
    }

    @available(macOS 14.4, *)
    private nonisolated static func countOperations(in plan: MLComputePlan) -> (preferred: Int, total: Int) {
        var preferred = 0
        var total = 0
        func count(_ usage: MLComputePlan.DeviceUsage?) {
            guard let usage else { return }
            total += 1
            if case .neuralEngine = usage.preferred { preferred += 1 }
        }
        func walk(_ block: MLModelStructure.Program.Block) {
            for operation in block.operations {
                count(plan.deviceUsage(for: operation))
                for child in operation.blocks { walk(child) }
            }
        }
        switch plan.modelStructure {
        case .program(let program):
            for function in program.functions.values { walk(function.block) }
        case .neuralNetwork(let network):
            for layer in network.layers { count(plan.deviceUsage(for: layer)) }
        case .pipeline, .unsupported: break
        @unknown default: break
        }
        return (preferred, total)
    }

    private nonisolated static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
