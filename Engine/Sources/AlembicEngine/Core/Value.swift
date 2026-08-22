import Foundation

/// The fundamental cell value type flowing through every Alembic pipeline.
/// Deterministic, Codable, and cheap to copy.
public enum Value: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case date(Date)

    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Canonical display string (used by the UI and CSV writer).
    public var display: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d):
            if d == d.rounded() && abs(d) < 1e15 { return String(format: "%.1f", d) }
            return String(d)
        case .string(let s): return s
        case .date(let d): return ISO8601DateFormatter.alembicShared.string(from: d)
        }
    }

    /// String content if this is a string value, else nil.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Best-effort numeric interpretation.
    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "double"
        case .string: return "string"
        case .date: return "date"
        }
    }
}

extension Value: Codable {
    private enum CodingKeys: String, CodingKey { case t, v }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode(String.self, forKey: .t)
        switch t {
        case "null": self = .null
        case "bool": self = .bool(try c.decode(Bool.self, forKey: .v))
        case "int": self = .int(try c.decode(Int64.self, forKey: .v))
        case "double": self = .double(try c.decode(Double.self, forKey: .v))
        case "string": self = .string(try c.decode(String.self, forKey: .v))
        case "date": self = .date(try c.decode(Date.self, forKey: .v))
        default: self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(typeName, forKey: .t)
        switch self {
        case .null: break
        case .bool(let b): try c.encode(b, forKey: .v)
        case .int(let i): try c.encode(i, forKey: .v)
        case .double(let d): try c.encode(d, forKey: .v)
        case .string(let s): try c.encode(s, forKey: .v)
        case .date(let d): try c.encode(d, forKey: .v)
        }
    }
}

extension Value: Comparable {
    public static func < (lhs: Value, rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return false
        case (.null, _): return true
        case (_, .null): return false
        case (.int(let a), .int(let b)): return a < b
        case (.double(let a), .double(let b)): return a < b
        case (.int(let a), .double(let b)): return Double(a) < b
        case (.double(let a), .int(let b)): return a < Double(b)
        case (.bool(let a), .bool(let b)): return !a && b
        case (.date(let a), .date(let b)): return a < b
        default: return lhs.display < rhs.display
        }
    }
}

/// One row in a dataset. `id` is stable across pipeline operations so the UI
/// can diff before/after states cell-by-cell even when rows are dropped.
public struct Record: Identifiable, Hashable, Sendable {
    public let id: Int
    public var values: [Value]

    public init(id: Int, values: [Value]) {
        self.id = id
        self.values = values
    }
}

/// An in-memory columnar-ish dataset: ordered column names + rows of Values.
/// Readers stream into this; the executor transforms it op by op.
public struct Dataset: Sendable {
    public var columns: [String]
    public var records: [Record]

    public init(columns: [String], records: [Record] = []) {
        self.columns = columns
        self.records = records
    }

    public var rowCount: Int { records.count }
    public var columnCount: Int { columns.count }

    public func columnIndex(of name: String) -> Int? {
        columns.firstIndex(of: name)
    }

    public func value(row: Int, column name: String) -> Value {
        guard let idx = columnIndex(of: name), row < records.count,
              idx < records[row].values.count else { return .null }
        return records[row].values[idx]
    }

    /// All values in a named column (missing cells become .null).
    public func columnValues(_ name: String) -> [Value] {
        guard let idx = columnIndex(of: name) else { return [] }
        return records.map { idx < $0.values.count ? $0.values[idx] : .null }
    }

    /// A sampled subset for live preview: first `head` rows plus a deterministic
    /// spread of `spread` rows from the remainder.
    public func sample(head: Int = 100, spread: Int = 100) -> Dataset {
        guard records.count > head + spread else { return self }
        var sampled = Array(records.prefix(head))
        let rest = records.count - head
        let stride = max(1, rest / spread)
        var i = head
        while i < records.count && sampled.count < head + spread {
            sampled.append(records[i])
            i += stride
        }
        return Dataset(columns: columns, records: sampled)
    }

    /// Rebuild with fresh sequential ids (used at import time only).
    public static func fresh(columns: [String], rows: [[Value]]) -> Dataset {
        var records: [Record] = []
        records.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() {
            var padded = row
            if padded.count < columns.count {
                padded.append(contentsOf: Array(repeating: Value.null, count: columns.count - padded.count))
            } else if padded.count > columns.count {
                padded = Array(padded.prefix(columns.count))
            }
            records.append(Record(id: i, values: padded))
        }
        return Dataset(columns: columns, records: records)
    }
}

public enum AlembicError: Error, LocalizedError, Sendable {
    case unreadableFile(String)
    case unsupportedFormat(String)
    case parseFailure(String)
    case missingColumn(String)
    case invalidRecipe(String)
    case expressionError(String)
    case providerError(String)
    case exportFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let s): return "Unreadable file: \(s)"
        case .unsupportedFormat(let s): return "Unsupported format: \(s)"
        case .parseFailure(let s): return "Parse failure: \(s)"
        case .missingColumn(let s): return "Missing column: \(s)"
        case .invalidRecipe(let s): return "Invalid recipe: \(s)"
        case .expressionError(let s): return "Expression error: \(s)"
        case .providerError(let s): return "Provider error: \(s)"
        case .exportFailure(let s): return "Export failure: \(s)"
        }
    }
}

extension ISO8601DateFormatter {
    static let alembicShared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// Deterministic seeded RNG (SplitMix64) used everywhere randomness is needed,
/// so recipes replay identically.
public struct SeededRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// FNV-1a 64-bit — the engine's canonical stable hash (Hasher is randomly seeded
/// per-process, so it must never be used for anything persisted or deduped).
public func stableHash64(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 {
        h ^= UInt64(b)
        h = h &* 0x100000001b3
    }
    return h
}

public func stableHash64(_ bytes: [UInt8]) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in bytes {
        h ^= UInt64(b)
        h = h &* 0x100000001b3
    }
    return h
}
