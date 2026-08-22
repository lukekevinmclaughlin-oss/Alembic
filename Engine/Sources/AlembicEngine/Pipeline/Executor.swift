import Foundation

/// Per-op execution metrics — these roll up into the dataset card and drive the
/// UI's "rows affected" counters.
public struct OpMetrics: Sendable, Identifiable {
    public let id = UUID()
    public let opName: String
    public var rowsIn = 0
    public var rowsOut = 0
    public var cellsChanged = 0
    public var notes: [String: String] = [:]

    public var rowsDropped: Int { max(0, rowsIn - rowsOut) }
    public init(opName: String) { self.opName = opName }
}

public struct ExecutionResult: Sendable {
    public let dataset: Dataset
    public let metrics: [OpMetrics]
}

/// Applies a recipe's ops in order. Deterministic core ops run synchronously
/// under the hood; augmentation ops require a client and run async.
public enum PipelineExecutor {

    public static func run(_ dataset: Dataset, ops: [Op],
                           augmentClient: (any LLMClient)? = nil,
                           progress: (@Sendable (Int, String) -> Void)? = nil,
                           augmentProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> ExecutionResult {
        var current = dataset
        var allMetrics: [OpMetrics] = []
        for (i, op) in ops.enumerated() {
            progress?(i, op.displayName)
            if Task.isCancelled { break }
            let (next, metrics) = try await apply(op, to: current, augmentClient: augmentClient,
                                                  augmentProgress: augmentProgress)
            current = next
            allMetrics.append(metrics)
        }
        return ExecutionResult(dataset: current, metrics: allMetrics)
    }

    public static func apply(_ op: Op, to dataset: Dataset,
                             augmentClient: (any LLMClient)? = nil,
                             augmentProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> (Dataset, OpMetrics) {
        var m = OpMetrics(opName: op.displayName)
        m.rowsIn = dataset.rowCount

        switch op {

        case .selectColumns(let columns):
            let keep = columns.compactMap { dataset.columnIndex(of: $0) }
            var out = Dataset(columns: keep.map { dataset.columns[$0] })
            out.records = dataset.records.map { r in
                Record(id: r.id, values: keep.map { $0 < r.values.count ? r.values[$0] : .null })
            }
            m.rowsOut = out.rowCount
            return (out, m)

        case .dropColumns(let columns):
            let dropSet = Set(columns)
            let keep = dataset.columns.enumerated().filter { !dropSet.contains($0.element) }.map(\.offset)
            var out = Dataset(columns: keep.map { dataset.columns[$0] })
            out.records = dataset.records.map { r in
                Record(id: r.id, values: keep.map { $0 < r.values.count ? r.values[$0] : .null })
            }
            m.rowsOut = out.rowCount
            return (out, m)

        case .renameColumn(let from, let to):
            var out = dataset
            if let idx = out.columnIndex(of: from) { out.columns[idx] = to }
            m.rowsOut = out.rowCount
            return (out, m)

        case .addColumn(let name, let expression):
            let expr = try ExpressionParser.parse(expression)
            var out = dataset
            out.columns.append(name)
            for i in 0..<out.records.count {
                let v = (try? ExpressionEvaluator.evaluate(expr, columns: dataset.columns,
                                                           values: out.records[i].values)) ?? .null
                out.records[i].values.append(v)
                m.cellsChanged += 1
            }
            m.rowsOut = out.rowCount
            return (out, m)

        case .filterRows(let expression):
            let expr = try ExpressionParser.parse(expression)
            var out = dataset
            out.records = try dataset.records.filter { r in
                let v = try ExpressionEvaluator.evaluate(expr, columns: dataset.columns, values: r.values)
                return ExpressionEvaluator.truthy(v)
            }
            m.rowsOut = out.rowCount
            return (out, m)

        case .normalizeText(let columns, let options):
            let idxs = targetIndices(dataset, columns: columns, stringOnly: true)
            var out = dataset
            for i in 0..<out.records.count {
                for idx in idxs where idx < out.records[i].values.count {
                    if case .string(let s) = out.records[i].values[idx] {
                        let normalized = TextNormalizer.normalize(s, options: options)
                        if normalized != s {
                            out.records[i].values[idx] = normalized.isEmpty ? .null : .string(normalized)
                            m.cellsChanged += 1
                        }
                    }
                }
            }
            m.rowsOut = out.rowCount
            return (out, m)

        case .unifyNulls(let columns):
            let idxs = targetIndices(dataset, columns: columns, stringOnly: true)
            var out = dataset
            for i in 0..<out.records.count {
                for idx in idxs where idx < out.records[i].values.count {
                    if case .string(let s) = out.records[i].values[idx],
                       TypeInference.isNullSentinel(s) {
                        out.records[i].values[idx] = .null
                        m.cellsChanged += 1
                    }
                }
            }
            m.rowsOut = out.rowCount
            return (out, m)

        case .autoType:
            var out = dataset
            for (colIdx, _) in dataset.columns.enumerated() {
                let samples = dataset.records.prefix(500).compactMap { r -> String? in
                    guard colIdx < r.values.count, case .string(let s) = r.values[colIdx] else { return nil }
                    return s
                }
                guard !samples.isEmpty else { continue }
                let inferred = TypeInference.inferType(samples: samples)
                guard inferred != .string else { continue }
                for i in 0..<out.records.count where colIdx < out.records[i].values.count {
                    let old = out.records[i].values[colIdx]
                    let new = TypeInference.coerce(old, to: inferred)
                    if new != old {
                        out.records[i].values[colIdx] = new
                        m.cellsChanged += 1
                    }
                }
                m.notes[dataset.columns[colIdx]] = inferred.rawValue
            }
            m.rowsOut = out.rowCount
            return (out, m)

        case .coerceType(let column, let type):
            guard let idx = dataset.columnIndex(of: column) else { throw AlembicError.missingColumn(column) }
            var out = dataset
            for i in 0..<out.records.count where idx < out.records[i].values.count {
                let old = out.records[i].values[idx]
                let new = TypeInference.coerce(old, to: type)
                if new != old {
                    out.records[i].values[idx] = new
                    m.cellsChanged += 1
                }
            }
            m.rowsOut = out.rowCount
            return (out, m)

        case .dedupeExact(let columns):
            let result = Dedupe.exact(dataset, columns: columns)
            let keep = Set(result.keptIDs)
            var out = dataset
            out.records = dataset.records.filter { keep.contains($0.id) }
            m.rowsOut = out.rowCount
            m.notes["clusters"] = String(result.clusters.count)
            return (out, m)

        case .dedupeFuzzy(let column, let threshold):
            let result = Dedupe.nearDuplicates(dataset, column: column,
                                               config: Dedupe.MinHashConfig(threshold: threshold))
            let keep = Set(result.keptIDs)
            var out = dataset
            out.records = dataset.records.filter { keep.contains($0.id) }
            m.rowsOut = out.rowCount
            m.notes["clusters"] = String(result.clusters.count)
            return (out, m)

        case .redactPII(let columns, let kinds, let mode):
            let idxs = targetIndices(dataset, columns: columns, stringOnly: true)
            let kindSet = Set(kinds.isEmpty ? PIIKind.allCases : kinds)
            var out = dataset
            var totalCounts: [PIIKind: Int] = [:]
            for i in 0..<out.records.count {
                for idx in idxs where idx < out.records[i].values.count {
                    if case .string(let s) = out.records[i].values[idx] {
                        let (redacted, counts) = PIIDetector.redact(s, kinds: kindSet, mode: mode)
                        if !counts.isEmpty {
                            out.records[i].values[idx] = .string(redacted)
                            m.cellsChanged += 1
                            for (k, v) in counts { totalCounts[k, default: 0] += v }
                        }
                    }
                }
            }
            for (k, v) in totalCounts { m.notes[k.rawValue] = String(v) }
            m.rowsOut = out.rowCount
            return (out, m)

        case .qualityFilter(let column, let rules):
            guard let idx = dataset.columnIndex(of: column) else { throw AlembicError.missingColumn(column) }
            var reasonCounts: [String: Int] = [:]
            var out = dataset
            out.records = dataset.records.filter { r in
                guard idx < r.values.count else { return false }
                let verdict = QualityFilter.evaluate(r.values[idx].display, rules: rules)
                if !verdict.passed {
                    for reason in verdict.reasons {
                        let key = reason.split(separator: "(").first.map(String.init) ?? reason
                        reasonCounts[key, default: 0] += 1
                    }
                }
                return verdict.passed
            }
            for (k, v) in reasonCounts.sorted(by: { $0.value > $1.value }).prefix(8) {
                m.notes[k] = String(v)
            }
            m.rowsOut = out.rowCount
            return (out, m)

        case .languageFilter(let column, let allowed, let minConfidence):
            guard let idx = dataset.columnIndex(of: column) else { throw AlembicError.missingColumn(column) }
            let allowedSet = Set(allowed)
            var out = dataset
            out.records = dataset.records.filter { r in
                guard idx < r.values.count else { return false }
                let det = LanguageID.detect(r.values[idx].display)
                return allowedSet.contains(det.code) && det.confidence >= minConfidence
            }
            m.rowsOut = out.rowCount
            return (out, m)

        case .decontaminate(let column, let evalTexts, let nGramSize):
            let index = Decontaminator.EvalIndex(evalTexts: evalTexts, nGramSize: nGramSize)
            let hits = Decontaminator.screen(dataset, column: column, against: index)
            let contaminated = Set(hits.map(\.recordID))
            var out = dataset
            out.records = dataset.records.filter { !contaminated.contains($0.id) }
            m.rowsOut = out.rowCount
            m.notes["contaminated"] = String(hits.count)
            return (out, m)

        case .addTokenCount(let column):
            guard let idx = dataset.columnIndex(of: column) else { throw AlembicError.missingColumn(column) }
            let tokenizer = TokenizerProvider.current
            var out = dataset
            let colName = uniqueColumnName("token_count", existing: out.columns)
            out.columns.append(colName)
            for i in 0..<out.records.count {
                let text = idx < out.records[i].values.count ? out.records[i].values[idx].display : ""
                out.records[i].values.append(.int(Int64(tokenizer.countTokens(text))))
            }
            m.rowsOut = out.rowCount
            m.notes["tokenizer"] = tokenizer.name
            return (out, m)

        case .addLanguage(let column):
            guard let idx = dataset.columnIndex(of: column) else { throw AlembicError.missingColumn(column) }
            var out = dataset
            let colName = uniqueColumnName("lang", existing: out.columns)
            out.columns.append(colName)
            for i in 0..<out.records.count {
                let text = idx < out.records[i].values.count ? out.records[i].values[idx].display : ""
                out.records[i].values.append(.string(LanguageID.detect(text).code))
            }
            m.rowsOut = out.rowCount
            return (out, m)

        case .addQualityScore(let column):
            guard let idx = dataset.columnIndex(of: column) else { throw AlembicError.missingColumn(column) }
            var out = dataset
            let colName = uniqueColumnName("quality_score", existing: out.columns)
            out.columns.append(colName)
            for i in 0..<out.records.count {
                let text = idx < out.records[i].values.count ? out.records[i].values[idx].display : ""
                out.records[i].values.append(.double(QualityFilter.evaluate(text).score))
            }
            m.rowsOut = out.rowCount
            return (out, m)

        case .chunkText(let column, let config):
            guard let idx = dataset.columnIndex(of: column) else { throw AlembicError.missingColumn(column) }
            let tokenizer = TokenizerProvider.current
            var outColumns = dataset.columns
            for extra in ["chunk_index", "chunk_tokens", "heading_path"] {
                outColumns.append(uniqueColumnName(extra, existing: outColumns))
            }
            var newRecords: [Record] = []
            var nextID = (dataset.records.map(\.id).max() ?? -1) + 1
            for r in dataset.records {
                guard idx < r.values.count else { continue }
                let text = r.values[idx].display
                let chunks = Chunker.chunk(text, config: config, tokenizer: tokenizer)
                for (ci, chunk) in chunks.enumerated() {
                    var values = r.values
                    values[idx] = .string(chunk.text)
                    values.append(.int(Int64(chunk.index)))
                    values.append(.int(Int64(chunk.tokenCount)))
                    values.append(chunk.headingPath.isEmpty ? .null : .string(chunk.headingPath))
                    // First chunk keeps the original row id (diffability); rest get fresh ids
                    let id = ci == 0 ? r.id : nextID
                    if ci > 0 { nextID += 1 }
                    newRecords.append(Record(id: id, values: values))
                }
            }
            let out = Dataset(columns: outColumns, records: newRecords)
            m.rowsOut = out.rowCount
            return (out, m)

        case .split(let train, let validation, let test, let seed, let stratifyBy):
            let out = DatasetSplitter.split(dataset,
                                            fractions: .init(train: train, validation: validation, test: test),
                                            seed: seed, stratifyBy: stratifyBy)
            m.rowsOut = out.rowCount
            return (out, m)

        case .augment(let config):
            guard let client = augmentClient else {
                throw AlembicError.providerError("This recipe contains an LLM step — configure a provider in Settings first")
            }
            let (out, stats) = try await Augmentor.run(config, dataset: dataset, client: client,
                                                       progress: augmentProgress)
            m.rowsOut = out.rowCount
            m.cellsChanged = stats.processed * config.kind.outputColumns.count
            m.notes["processed"] = String(stats.processed)
            m.notes["skipped"] = String(stats.skipped)
            m.notes["failed"] = String(stats.failed)
            m.notes["tokens_in"] = String(stats.inputTokens)
            m.notes["tokens_out"] = String(stats.outputTokens)
            return (out, m)
        }
    }

    static func targetIndices(_ dataset: Dataset, columns: [String], stringOnly: Bool) -> [Int] {
        if columns.isEmpty {
            return Array(0..<dataset.columns.count)
        }
        return columns.compactMap { dataset.columnIndex(of: $0) }
    }

    static func uniqueColumnName(_ base: String, existing: [String]) -> String {
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base)_\(n)") { n += 1 }
        return "\(base)_\(n)"
    }
}
