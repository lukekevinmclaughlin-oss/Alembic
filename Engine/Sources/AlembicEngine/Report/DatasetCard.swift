import Foundation

/// Statistics + provenance for a processed dataset — the "dataset card".
/// Exportable as Markdown or JSON alongside the data itself.
public struct DatasetCard: Sendable {

    public struct ColumnStats: Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public let typeName: String
        public let nullFraction: Double
        public let uniqueCount: Int        // capped at 10k
        public let tokenStats: TokenStats? // text columns only
    }

    public struct TokenStats: Sendable {
        public let min: Int
        public let max: Int
        public let mean: Double
        public let p50: Int
        public let p95: Int
        public let total: Int
        public let histogram: [(bucket: String, count: Int)]
    }

    public let rowCount: Int
    public let columnCount: Int
    public let columns: [ColumnStats]
    public let languageMix: [(code: String, fraction: Double)]
    public let pipelineSummary: [(op: String, rowsIn: Int, rowsOut: Int, cellsChanged: Int, notes: [String: String])]
    public let tokenizerName: String
    public let generatedAt: Date

    /// Compute the card. Language mix and token stats are sampled for speed.
    public static func compute(dataset: Dataset, metrics: [OpMetrics],
                               tokenizer: any Tokenizer = TokenizerProvider.current,
                               now: Date = Date()) -> DatasetCard {
        var columnStats: [ColumnStats] = []
        var textColumnIdx: Int?
        var longestTextLen = 0

        for (idx, name) in dataset.columns.enumerated() {
            var nulls = 0
            var uniques = Set<UInt64>()
            var types: [String: Int] = [:]
            var textLenSum = 0
            for r in dataset.records {
                guard idx < r.values.count else { nulls += 1; continue }
                let v = r.values[idx]
                if v.isNull { nulls += 1; continue }
                types[v.typeName, default: 0] += 1
                if uniques.count < 10_000 { uniques.insert(stableHash64(v.display)) }
                if case .string(let s) = v { textLenSum += s.count }
            }
            let dominantType = types.max(by: { $0.value < $1.value })?.key ?? "null"
            if dominantType == "string" && textLenSum > longestTextLen {
                longestTextLen = textLenSum
                textColumnIdx = idx
            }
            let n = max(1, dataset.rowCount)
            columnStats.append(ColumnStats(
                name: name, typeName: dominantType,
                nullFraction: Double(nulls) / Double(n),
                uniqueCount: uniques.count, tokenStats: nil))
        }

        // Token stats on the dominant text column (sampled at ≤2000 rows)
        if let tIdx = textColumnIdx {
            let sampleRecords = dataset.records.count > 2000
                ? dataset.sample(head: 1000, spread: 1000).records
                : dataset.records
            var counts: [Int] = []
            counts.reserveCapacity(sampleRecords.count)
            var fullTotal = 0
            for r in sampleRecords where tIdx < r.values.count {
                let c = tokenizer.countTokens(r.values[tIdx].display)
                counts.append(c)
            }
            if !counts.isEmpty {
                let sorted = counts.sorted()
                let mean = Double(counts.reduce(0, +)) / Double(counts.count)
                // Extrapolate total from the sample when sampled
                fullTotal = dataset.records.count > 2000
                    ? Int(mean * Double(dataset.rowCount))
                    : counts.reduce(0, +)
                let stats = TokenStats(
                    min: sorted.first ?? 0,
                    max: sorted.last ?? 0,
                    mean: mean,
                    p50: sorted[sorted.count / 2],
                    p95: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
                    total: fullTotal,
                    histogram: histogram(sorted))
                columnStats[tIdx] = ColumnStats(
                    name: columnStats[tIdx].name, typeName: columnStats[tIdx].typeName,
                    nullFraction: columnStats[tIdx].nullFraction,
                    uniqueCount: columnStats[tIdx].uniqueCount, tokenStats: stats)
            }
        }

        // Language mix (sampled)
        var langCounts: [String: Int] = [:]
        if let tIdx = textColumnIdx {
            let sample = dataset.records.prefix(500)
            for r in sample where tIdx < r.values.count {
                langCounts[LanguageID.detect(r.values[tIdx].display).code, default: 0] += 1
            }
        }
        let langTotal = max(1, langCounts.values.reduce(0, +))
        let mix = langCounts.sorted { $0.value > $1.value }.prefix(8)
            .map { (code: $0.key, fraction: Double($0.value) / Double(langTotal)) }

        return DatasetCard(
            rowCount: dataset.rowCount,
            columnCount: dataset.columnCount,
            columns: columnStats,
            languageMix: Array(mix),
            pipelineSummary: metrics.map { ($0.opName, $0.rowsIn, $0.rowsOut, $0.cellsChanged, $0.notes) },
            tokenizerName: tokenizer.name,
            generatedAt: now)
    }

    static func histogram(_ sorted: [Int]) -> [(String, Int)] {
        guard let maxV = sorted.last, maxV > 0 else { return [] }
        let buckets: [(String, Range<Int>)] = [
            ("0–64", 0..<64), ("64–128", 64..<128), ("128–256", 128..<256),
            ("256–512", 256..<512), ("512–1k", 512..<1024), ("1k–2k", 1024..<2048),
            ("2k–4k", 2048..<4096), ("4k–8k", 4096..<8192), ("8k+", 8192..<Int.max)
        ]
        return buckets.map { (label, range) in
            (label, sorted.filter { range.contains($0) }.count)
        }.filter { $0.1 > 0 }
    }

    // MARK: - Rendering

    public func markdown() -> String {
        var md = "# Dataset Card\n\n"
        md += "Generated \(ISO8601DateFormatter.alembicShared.string(from: generatedAt)) by Alembic. Tokenizer: `\(tokenizerName)`.\n\n"
        md += "**\(rowCount) rows × \(columnCount) columns**\n\n"

        md += "## Columns\n\n| Column | Type | Nulls | Unique |\n|---|---|---|---|\n"
        for c in columns {
            md += "| \(c.name) | \(c.typeName) | \(String(format: "%.1f%%", c.nullFraction * 100)) | \(c.uniqueCount >= 10_000 ? "10k+" : String(c.uniqueCount)) |\n"
        }

        if let ts = columns.compactMap(\.tokenStats).first {
            md += "\n## Token distribution\n\n"
            md += "Total ≈ **\(ts.total.formatted())** tokens. Mean \(String(format: "%.0f", ts.mean)), median \(ts.p50), p95 \(ts.p95), range \(ts.min)–\(ts.max).\n\n"
            if !ts.histogram.isEmpty {
                md += "| Bucket | Rows |\n|---|---|\n"
                for (bucket, count) in ts.histogram { md += "| \(bucket) | \(count) |\n" }
            }
        }

        if !languageMix.isEmpty {
            md += "\n## Language mix (sampled)\n\n"
            for (code, fraction) in languageMix {
                md += "- **\(code)**: \(String(format: "%.1f%%", fraction * 100))\n"
            }
        }

        if !pipelineSummary.isEmpty {
            md += "\n## Pipeline provenance\n\n| Step | Rows in | Rows out | Cells changed | Notes |\n|---|---|---|---|---|\n"
            for step in pipelineSummary {
                let notes = step.notes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                md += "| \(step.op) | \(step.rowsIn) | \(step.rowsOut) | \(step.cellsChanged) | \(notes) |\n"
            }
        }
        return md
    }

    public func json() throws -> Data {
        var obj: [String: Any] = [
            "rowCount": rowCount,
            "columnCount": columnCount,
            "tokenizer": tokenizerName,
            "generatedAt": ISO8601DateFormatter.alembicShared.string(from: generatedAt),
            "columns": columns.map { c -> [String: Any] in
                var d: [String: Any] = ["name": c.name, "type": c.typeName,
                                        "nullFraction": c.nullFraction, "uniqueCount": c.uniqueCount]
                if let t = c.tokenStats {
                    d["tokens"] = ["min": t.min, "max": t.max, "mean": t.mean,
                                   "p50": t.p50, "p95": t.p95, "total": t.total]
                }
                return d
            },
            "languageMix": languageMix.map { ["code": $0.code, "fraction": $0.fraction] }
        ]
        obj["pipeline"] = pipelineSummary.map {
            ["op": $0.op, "rowsIn": $0.rowsIn, "rowsOut": $0.rowsOut,
             "cellsChanged": $0.cellsChanged, "notes": $0.notes] as [String: Any]
        }
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }
}

/// Cell-level diff between the imported dataset and the pipeline output —
/// powers the before/after preview highlighting.
public enum DatasetDiff {

    public enum RowChange: Sendable, Equatable {
        case unchanged
        case modified(changedColumns: Set<String>)
        case added          // e.g. new chunk rows
    }

    public struct Result: Sendable {
        public let rowChanges: [Int: RowChange]   // keyed by record id in the AFTER dataset
        public let droppedIDs: Set<Int>           // ids present before, gone after
        public let addedColumns: Set<String>
        public let removedColumns: Set<String>
    }

    public static func diff(before: Dataset, after: Dataset) -> Result {
        let beforeByID = Dictionary(uniqueKeysWithValues: before.records.map { ($0.id, $0) })
        let afterIDs = Set(after.records.map(\.id))
        let beforeCols = Set(before.columns)
        let afterCols = Set(after.columns)
        let shared = beforeCols.intersection(afterCols)

        var rowChanges: [Int: RowChange] = [:]
        for r in after.records {
            guard let old = beforeByID[r.id] else {
                rowChanges[r.id] = .added
                continue
            }
            var changed = Set<String>()
            for col in shared {
                guard let bIdx = before.columnIndex(of: col), let aIdx = after.columnIndex(of: col) else { continue }
                let oldV = bIdx < old.values.count ? old.values[bIdx] : .null
                let newV = aIdx < r.values.count ? r.values[aIdx] : .null
                if oldV != newV { changed.insert(col) }
            }
            rowChanges[r.id] = changed.isEmpty ? .unchanged : .modified(changedColumns: changed)
        }

        let dropped = Set(beforeByID.keys).subtracting(afterIDs)
        return Result(rowChanges: rowChanges,
                      droppedIDs: dropped,
                      addedColumns: afterCols.subtracting(beforeCols),
                      removedColumns: beforeCols.subtracting(afterCols))
    }
}
