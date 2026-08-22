import Foundation

/// JSON / JSONL reader. Accepts: JSONL (one object per line), a top-level JSON
/// array of objects, or a single object containing an array of objects (finds the
/// largest array). Nested objects/arrays are flattened with dot-path keys.
public enum JSONReader {

    public struct ReadResult: Sendable {
        public let dataset: Dataset
        public let format: String       // "jsonl" | "json-array" | "json-nested"
        public let badLines: Int
    }

    public static func read(data: Data) throws -> ReadResult {
        let decoded = EncodingDetector.decode(data)
        return try read(text: decoded.text)
    }

    public static func read(url: URL) throws -> ReadResult {
        guard let data = try? Data(contentsOf: url) else {
            throw AlembicError.unreadableFile(url.lastPathComponent)
        }
        return try read(data: data)
    }

    public static func read(text: String) throws -> ReadResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ReadResult(dataset: Dataset(columns: []), format: "jsonl", badLines: 0)
        }

        // Try whole-document JSON first when it starts with [ or {
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            if let data = trimmed.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                if let array = obj as? [Any] {
                    // Could be a JSON array, but also could be a single JSONL line — array wins
                    return ReadResult(dataset: datasetFrom(objects: array), format: "json-array", badLines: 0)
                }
                if let dict = obj as? [String: Any] {
                    // Whole doc parsed as one object: if multi-line, likely JSONL of objects; try that first
                    let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: true)
                    if lines.count > 1 {
                        let (ds, bad) = parseJSONL(lines: lines.map(String.init))
                        if ds.rowCount > 1 { return ReadResult(dataset: ds, format: "jsonl", badLines: bad) }
                    }
                    // Single object: find the largest embedded array of objects
                    if let best = largestObjectArray(in: dict) {
                        return ReadResult(dataset: datasetFrom(objects: best), format: "json-nested", badLines: 0)
                    }
                    return ReadResult(dataset: datasetFrom(objects: [dict]), format: "json-nested", badLines: 0)
                }
            }
        }

        // JSONL path
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let (ds, bad) = parseJSONL(lines: lines)
        guard ds.rowCount > 0 else {
            throw AlembicError.parseFailure("No parseable JSON records found")
        }
        return ReadResult(dataset: ds, format: "jsonl", badLines: bad)
    }

    static func parseJSONL(lines: [String]) -> (Dataset, Int) {
        var objects: [Any] = []
        var bad = 0
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if let d = t.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) {
                objects.append(obj)
            } else {
                bad += 1
            }
        }
        return (datasetFrom(objects: objects), bad)
    }

    static func largestObjectArray(in dict: [String: Any]) -> [Any]? {
        var best: [Any]?
        var bestCount = 0
        func walk(_ node: Any) {
            if let arr = node as? [Any] {
                let objCount = arr.prefix(50).filter { $0 is [String: Any] }.count
                if objCount > 0 && arr.count > bestCount {
                    best = arr
                    bestCount = arr.count
                }
                for el in arr.prefix(10) { walk(el) }
            } else if let d = node as? [String: Any] {
                for v in d.values { walk(v) }
            }
        }
        walk(dict)
        return best
    }

    /// Flatten heterogeneous JSON objects into a rectangular dataset.
    /// Keys are discovered in first-seen order; nested paths use dots.
    static func datasetFrom(objects: [Any]) -> Dataset {
        var columns: [String] = []
        var columnSet = Set<String>()
        var flatRows: [[String: Value]] = []
        flatRows.reserveCapacity(objects.count)

        for obj in objects {
            var flat: [String: Value] = [:]
            if let dict = obj as? [String: Any] {
                flatten(dict, prefix: "", into: &flat)
            } else {
                flat["value"] = jsonValue(obj)
            }
            for key in flat.keys.sorted() where !columnSet.contains(key) {
                // Keep discovery order within a row deterministic via sort, across rows first-seen
                columnSet.insert(key)
                columns.append(key)
            }
            flatRows.append(flat)
        }

        let rows: [[Value]] = flatRows.map { flat in
            columns.map { flat[$0] ?? .null }
        }
        return Dataset.fresh(columns: columns, rows: rows)
    }

    static func flatten(_ dict: [String: Any], prefix: String, into out: inout [String: Value]) {
        for (k, v) in dict {
            let key = prefix.isEmpty ? k : "\(prefix).\(k)"
            if let nested = v as? [String: Any] {
                flatten(nested, prefix: key, into: &out)
            } else if let arr = v as? [Any] {
                // Arrays of scalars → joined string; arrays of objects → compact JSON
                if arr.allSatisfy({ $0 is String || $0 is NSNumber }) {
                    out[key] = .string(arr.map { "\($0)" }.joined(separator: "; "))
                } else if let d = try? JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys]),
                          let s = String(data: d, encoding: .utf8) {
                    out[key] = .string(s)
                } else {
                    out[key] = .null
                }
            } else {
                out[key] = jsonValue(v)
            }
        }
    }

    static func jsonValue(_ v: Any) -> Value {
        if v is NSNull { return .null }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let d = n.doubleValue
            if d == d.rounded() && abs(d) < 9.2e18 && !n.stringValue.contains(".") {
                return .int(n.int64Value)
            }
            return .double(d)
        }
        if let s = v as? String { return .string(s) }
        return .string("\(v)")
    }
}

/// JSONL writer — the primary export format. Values serialize naturally
/// (int as number, null as null, date as ISO string).
public enum JSONLWriter {

    public static func write(_ dataset: Dataset) -> String {
        var out = ""
        out.reserveCapacity(dataset.rowCount * 128)
        for record in dataset.records {
            var obj: [String: Any] = [:]
            for (i, col) in dataset.columns.enumerated() where i < record.values.count {
                obj[col] = jsonObject(record.values[i])
            }
            if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]),
               let s = String(data: d, encoding: .utf8) {
                out += s
                out += "\n"
            }
        }
        return out
    }

    /// Write nested structures (used by schema shapers that produce message arrays).
    public static func writeObjects(_ objects: [[String: Any]]) -> String {
        var out = ""
        for obj in objects {
            if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]),
               let s = String(data: d, encoding: .utf8) {
                out += s
                out += "\n"
            }
        }
        return out
    }

    static func jsonObject(_ v: Value) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d.isFinite ? d : NSNull()
        case .string(let s): return s
        case .date(let d): return ISO8601DateFormatter.alembicShared.string(from: d)
        }
    }
}
