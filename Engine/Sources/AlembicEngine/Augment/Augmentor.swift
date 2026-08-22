import Foundation

/// LLM augmentation nodes: synthetic Q&A generation, LLM-as-judge scoring,
/// rewriting, classification, and DPO preference-pair synthesis.
/// Batched with bounded concurrency, resumable (rows already augmented are
/// skipped on re-run), and cost-estimated up front.
public enum AugmentKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case generateQA
    case judgeScore
    case rewrite
    case classify
    case preferencePair

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .generateQA: return "Generate Q&A pairs"
        case .judgeScore: return "LLM-as-judge quality score"
        case .rewrite: return "Rewrite / normalize style"
        case .classify: return "Classify / label"
        case .preferencePair: return "Synthesize DPO rejected"
        }
    }

    /// Columns this augmentation adds.
    public var outputColumns: [String] {
        switch self {
        case .generateQA: return ["gen_question", "gen_answer"]
        case .judgeScore: return ["judge_score", "judge_rationale"]
        case .rewrite: return ["rewritten"]
        case .classify: return ["label"]
        case .preferencePair: return ["rejected"]
        }
    }
}

public struct AugmentConfig: Codable, Sendable, Equatable {
    public var kind: AugmentKind
    public var column: String            // source text column
    public var instruction: String       // extra user guidance folded into the prompt
    public var labels: [String]          // classify only
    public var concurrency: Int
    public var maxTokens: Int

    public init(kind: AugmentKind, column: String, instruction: String = "",
                labels: [String] = [], concurrency: Int = 4, maxTokens: Int = 1024) {
        self.kind = kind
        self.column = column
        self.instruction = instruction
        self.labels = labels
        self.concurrency = concurrency
        self.maxTokens = maxTokens
    }
}

public struct AugmentStats: Sendable {
    public var processed = 0
    public var skipped = 0        // already had output (resume)
    public var failed = 0
    public var inputTokens = 0
    public var outputTokens = 0
}

public struct CostEstimate: Sendable {
    public let calls: Int
    public let estimatedInputTokens: Int
    public let estimatedOutputTokens: Int

    /// Cost given user-entered per-million-token prices.
    public func cost(inputPerMTok: Double, outputPerMTok: Double) -> Double {
        Double(estimatedInputTokens) / 1e6 * inputPerMTok
            + Double(estimatedOutputTokens) / 1e6 * outputPerMTok
    }
}

public enum Augmentor {

    /// Pre-run cost estimate: prompt tokens per row + configured max output.
    public static func estimate(_ config: AugmentConfig, dataset: Dataset,
                                tokenizer: any Tokenizer = TokenizerProvider.current) -> CostEstimate {
        guard let idx = dataset.columnIndex(of: config.column) else {
            return CostEstimate(calls: 0, estimatedInputTokens: 0, estimatedOutputTokens: 0)
        }
        let overhead = tokenizer.countTokens(systemPrompt(config)) + 64
        var input = 0
        for r in dataset.records {
            guard idx < r.values.count else { continue }
            input += tokenizer.countTokens(r.values[idx].display) + overhead
        }
        return CostEstimate(calls: dataset.rowCount,
                            estimatedInputTokens: input,
                            estimatedOutputTokens: dataset.rowCount * min(config.maxTokens, 512))
    }

    /// Run augmentation over the dataset. Rows whose output columns are already
    /// populated are skipped, which makes re-running after an interruption cheap.
    public static func run(_ config: AugmentConfig, dataset: Dataset, client: any LLMClient,
                           tokenizer: any Tokenizer = TokenizerProvider.current,
                           progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> (Dataset, AugmentStats) {
        guard let srcIdx = dataset.columnIndex(of: config.column) else {
            throw AlembicError.missingColumn(config.column)
        }

        var out = dataset
        // Ensure output columns exist
        var outIdxs: [Int] = []
        for name in config.kind.outputColumns {
            if let existing = out.columnIndex(of: name) {
                outIdxs.append(existing)
            } else {
                out.columns.append(name)
                for i in 0..<out.records.count { out.records[i].values.append(.null) }
                outIdxs.append(out.columns.count - 1)
            }
        }

        var stats = AugmentStats()
        let system = systemPrompt(config)
        let retrying = RetryingClient(client)

        // Rows needing work (resume support: first output column still null)
        let firstOut = outIdxs[0]
        let pending = out.records.enumerated().compactMap { (i, r) -> (Int, String)? in
            guard srcIdx < r.values.count else { return nil }
            if firstOut < r.values.count && !r.values[firstOut].isNull { return nil }
            let text = r.values[srcIdx].display
            guard !text.isEmpty else { return nil }
            return (i, text)
        }
        stats.skipped = out.records.count - pending.count

        let total = pending.count
        var completed = 0
        var results: [Int: [Value]] = [:]
        var failures = 0

        // Bounded-concurrency batching
        let batchSize = max(1, config.concurrency)
        for batchStart in stride(from: 0, to: pending.count, by: batchSize) {
            if Task.isCancelled { break }   // partial results still applied — resume skips them next run
            let batch = Array(pending[batchStart..<min(batchStart + batchSize, pending.count)])
            let batchResults: [(Int, [Value]?, Int, Int)] = await withTaskGroup(of: (Int, [Value]?, Int, Int).self) { group in
                for (rowIdx, text) in batch {
                    group.addTask {
                        let user = Self.userPrompt(config, text: text)
                        let inTok = tokenizer.countTokens(system) + tokenizer.countTokens(user)
                        do {
                            let response = try await retrying.complete(system: system, user: user, maxTokens: config.maxTokens)
                            let outTok = tokenizer.countTokens(response)
                            let values = Self.parseResponse(config, response: response)
                            return (rowIdx, values, inTok, outTok)
                        } catch {
                            return (rowIdx, nil, inTok, 0)
                        }
                    }
                }
                var acc: [(Int, [Value]?, Int, Int)] = []
                for await r in group { acc.append(r) }
                return acc
            }
            for (rowIdx, values, inTok, outTok) in batchResults {
                stats.inputTokens += inTok
                stats.outputTokens += outTok
                if let values {
                    results[rowIdx] = values
                    stats.processed += 1
                } else {
                    failures += 1
                }
                completed += 1
            }
            progress?(completed, total)
            // Abort if everything is failing (bad key / endpoint) rather than burning the whole set
            if failures >= 5 && stats.processed == 0 {
                throw AlembicError.providerError("First \(failures) calls all failed — check provider settings")
            }
        }
        stats.failed = failures

        for (rowIdx, values) in results {
            for (k, outIdx) in outIdxs.enumerated() where k < values.count {
                out.records[rowIdx].values[outIdx] = values[k]
            }
        }
        return (out, stats)
    }

    // MARK: - Prompts

    static func systemPrompt(_ config: AugmentConfig) -> String {
        let extra = config.instruction.isEmpty ? "" : "\nAdditional guidance: \(config.instruction)"
        switch config.kind {
        case .generateQA:
            return "You create high-quality training data. Given a passage, write ONE question a user could ask that the passage answers, and the ideal answer grounded strictly in the passage. Respond with JSON only: {\"question\": \"...\", \"answer\": \"...\"}\(extra)"
        case .judgeScore:
            return "You are a strict data-quality judge for LLM training corpora. Score the text 1-10 for coherence, informativeness, and usefulness as training data (10 = excellent). Respond with JSON only: {\"score\": N, \"rationale\": \"one sentence\"}\(extra)"
        case .rewrite:
            return "You normalize text for LLM training. Fix grammar, spelling, and encoding artifacts. Preserve meaning, facts, tone, and language. Do not summarize or add content. Respond with the rewritten text only, no preamble.\(extra)"
        case .classify:
            let labels = config.labels.isEmpty ? "appropriate topical labels" : config.labels.joined(separator: ", ")
            return "Classify the text into exactly one of: \(labels). Respond with JSON only: {\"label\": \"...\"}\(extra)"
        case .preferencePair:
            return "You create DPO training data. Given a prompt-response pair, write a plausible but clearly WORSE response: less accurate, less helpful, or poorly structured — the kind a weak model would produce. It must still be on-topic. Respond with the worse response only, no preamble.\(extra)"
        }
    }

    static func userPrompt(_ config: AugmentConfig, text: String) -> String {
        String(text.prefix(24_000))
    }

    static func parseResponse(_ config: AugmentConfig, response: String) -> [Value] {
        let cleaned = stripCodeFence(response.trimmingCharacters(in: .whitespacesAndNewlines))
        switch config.kind {
        case .generateQA:
            if let obj = parseJSONObject(cleaned) {
                return [.string(obj["question"] as? String ?? ""),
                        .string(obj["answer"] as? String ?? "")]
            }
            return [.string(""), .string(cleaned)]
        case .judgeScore:
            if let obj = parseJSONObject(cleaned) {
                let score = (obj["score"] as? NSNumber)?.int64Value
                    ?? Int64((obj["score"] as? String).flatMap(Int.init) ?? 0)
                return [.int(score), .string(obj["rationale"] as? String ?? "")]
            }
            // Fallback: first integer in the response
            let digits = cleaned.prefix(20).filter(\.isNumber)
            return [.int(Int64(digits.prefix(2)) ?? 0), .string(cleaned)]
        case .rewrite:
            return [.string(cleaned)]
        case .classify:
            if let obj = parseJSONObject(cleaned) {
                return [.string(obj["label"] as? String ?? "")]
            }
            return [.string(cleaned)]
        case .preferencePair:
            return [.string(cleaned)]
        }
    }

    static func stripCodeFence(_ s: String) -> String {
        var t = s
        if t.hasPrefix("```") {
            if let firstNewline = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNewline)...])
            }
            if let fenceRange = t.range(of: "```", options: .backwards) {
                t = String(t[..<fenceRange.lowerBound])
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseJSONObject(_ s: String) -> [String: Any]? {
        // Try direct, then first {...} span
        if let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            return o
        }
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}") , start < end else { return nil }
        let span = String(s[start...end])
        guard let d = span.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}
