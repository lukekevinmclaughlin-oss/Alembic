import Foundation

/// A deep single-column profile for the data-inspector panel: type mix, null
/// fraction, cardinality, numeric summary, token summary (text columns), and
/// the most frequent values. Computed over whatever dataset it's handed
/// (the app runs it on the ≤200-row preview sample, so it's cheap).
public struct ColumnProfile: Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let index: Int
    public let sampleCount: Int
    public let nonNullCount: Int
    public let nullFraction: Double
    public let dominantType: String
    public let typeMix: [(type: String, count: Int)]
    public let uniqueCount: Int
    public let uniqueCapped: Bool

    // Numeric summary (present when the column has numeric values)
    public let numericMin: Double?
    public let numericMax: Double?
    public let numericMean: Double?

    // Token summary (present for text columns)
    public let tokenMin: Int?
    public let tokenMax: Int?
    public let tokenMean: Double?
    public let tokenTotal: Int?

    // Most frequent values (meaningful for low-to-mid cardinality columns)
    public let topValues: [(value: String, count: Int)]

    public var isNumeric: Bool { numericMean != nil }
    public var isText: Bool { tokenMean != nil }
}

public enum ColumnProfiler {

    public static func profile(_ dataset: Dataset, column: String,
                               tokenizer: any Tokenizer = TokenizerProvider.current) -> ColumnProfile? {
        guard let idx = dataset.columnIndex(of: column) else { return nil }

        var nulls = 0
        var uniques = Set<UInt64>()
        let uniqueCap = 50_000
        var uniqueCapped = false
        var types: [String: Int] = [:]
        var valueCounts: [String: Int] = [:]
        let valueCap = 10_000
        var numerics: [Double] = []
        var tokenCounts: [Int] = []
        let n = dataset.records.count

        for r in dataset.records {
            guard idx < r.values.count else { nulls += 1; continue }
            let v = r.values[idx]
            if v.isNull { nulls += 1; continue }
            types[v.typeName, default: 0] += 1
            let disp = v.display
            if uniques.count < uniqueCap {
                uniques.insert(stableHash64(disp))
            } else {
                uniqueCapped = true
            }
            if valueCounts.count < valueCap || valueCounts[disp] != nil {
                valueCounts[disp, default: 0] += 1
            }
            if let d = v.doubleValue { numerics.append(d) }
            if case .string(let s) = v { tokenCounts.append(tokenizer.countTokens(s)) }
        }

        let nonNull = n - nulls
        let dominant = types.max { $0.value < $1.value }?.key ?? "null"
        let typeMix = types.sorted { $0.value > $1.value }.map { (type: $0.key, count: $0.value) }

        var numMin: Double?, numMax: Double?, numMean: Double?
        if !numerics.isEmpty {
            numMin = numerics.min()
            numMax = numerics.max()
            numMean = numerics.reduce(0, +) / Double(numerics.count)
        }

        var tMin: Int?, tMax: Int?, tMean: Double?, tTotal: Int?
        if !tokenCounts.isEmpty {
            tMin = tokenCounts.min()
            tMax = tokenCounts.max()
            let total = tokenCounts.reduce(0, +)
            tTotal = total
            tMean = Double(total) / Double(tokenCounts.count)
        }

        let top = valueCounts.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.prefix(10).map { (value: $0.key, count: $0.value) }

        return ColumnProfile(
            name: column, index: idx, sampleCount: n, nonNullCount: nonNull,
            nullFraction: n > 0 ? Double(nulls) / Double(n) : 0,
            dominantType: dominant, typeMix: typeMix,
            uniqueCount: uniques.count, uniqueCapped: uniqueCapped,
            numericMin: numMin, numericMax: numMax, numericMean: numMean,
            tokenMin: tMin, tokenMax: tMax, tokenMean: tMean, tokenTotal: tTotal,
            topValues: Array(top))
    }
}
