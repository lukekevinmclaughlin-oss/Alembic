import Foundation

/// RFC 4180-compliant CSV/TSV reader with delimiter sniffing, quote handling,
/// embedded newlines, ragged-row recovery, and header inference.
public enum CSVReader {

    public struct Options: Sendable {
        public var delimiter: Character?      // nil = sniff
        public var hasHeader: Bool?           // nil = infer
        public var quote: Character = "\""
        public init(delimiter: Character? = nil, hasHeader: Bool? = nil) {
            self.delimiter = delimiter
            self.hasHeader = hasHeader
        }
    }

    public struct ReadResult: Sendable {
        public let dataset: Dataset
        public let delimiter: Character
        public let hadHeader: Bool
        public let raggedRowsRepaired: Int
        public let encoding: String
    }

    public static func read(data: Data, options: Options = Options()) throws -> ReadResult {
        let decoded = EncodingDetector.decode(data)
        return try read(text: decoded.text, options: options, encoding: decoded.detectedEncoding)
    }

    public static func read(url: URL, options: Options = Options()) throws -> ReadResult {
        guard let data = try? Data(contentsOf: url) else {
            throw AlembicError.unreadableFile(url.lastPathComponent)
        }
        return try read(data: data, options: options)
    }

    public static func read(text: String, options: Options = Options(), encoding: String = "utf-8") throws -> ReadResult {
        let delimiter = options.delimiter ?? sniffDelimiter(text)
        var rows = parse(text: text, delimiter: delimiter, quote: options.quote)
        // Drop trailing fully-empty rows
        while let last = rows.last, last.allSatisfy({ $0.isEmpty }) { rows.removeLast() }
        guard !rows.isEmpty else {
            return ReadResult(dataset: Dataset(columns: [], records: []), delimiter: delimiter,
                              hadHeader: false, raggedRowsRepaired: 0, encoding: encoding)
        }

        let hasHeader = options.hasHeader ?? inferHeader(rows)
        let headerRow = hasHeader ? rows[0] : []
        let dataRows = hasHeader ? Array(rows.dropFirst()) : rows

        let width = max(headerRow.count, dataRows.map(\.count).max() ?? 0)
        var columns: [String]
        if hasHeader {
            columns = normalizeHeaderNames(headerRow, width: width)
        } else {
            columns = (0..<width).map { "column_\($0 + 1)" }
        }

        var repaired = 0
        var valueRows: [[Value]] = []
        valueRows.reserveCapacity(dataRows.count)
        for raw in dataRows {
            if raw.count != width { repaired += 1 }
            var vals: [Value] = raw.map { $0.isEmpty ? .null : .string($0) }
            if vals.count < width { vals.append(contentsOf: Array(repeating: Value.null, count: width - vals.count)) }
            if vals.count > width { vals = Array(vals.prefix(width)) }
            valueRows.append(vals)
        }

        return ReadResult(
            dataset: Dataset.fresh(columns: columns, rows: valueRows),
            delimiter: delimiter, hadHeader: hasHeader, raggedRowsRepaired: repaired, encoding: encoding
        )
    }

    // MARK: - Parsing core

    /// Quote-aware state machine. Handles "" escapes, embedded delimiters and newlines.
    static func parse(text: String, delimiter: Character, quote: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var i = text.startIndex
        let end = text.endIndex

        while i < end {
            let ch = text[i]
            if inQuotes {
                if ch == quote {
                    let next = text.index(after: i)
                    if next < end && text[next] == quote {
                        field.append(quote)
                        i = text.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case quote where field.isEmpty:
                    inQuotes = true
                case delimiter:
                    row.append(field); field = ""
                case "\r":
                    let next = text.index(after: i)
                    if next < end && text[next] == "\n" { i = next }
                    row.append(field); field = ""
                    rows.append(row); row = []
                case "\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                default:
                    field.append(ch)
                }
            }
            i = text.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    /// Sniff by counting candidate delimiters outside quotes on sample lines,
    /// scoring for consistency across lines.
    static func sniffDelimiter(_ text: String) -> Character {
        let candidates: [Character] = [",", "\t", ";", "|"]
        let sample = String(text.prefix(65536))
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: true).prefix(30)
        guard !lines.isEmpty else { return "," }

        var bestScore = -1.0
        var best: Character = ","
        for cand in candidates {
            var counts: [Int] = []
            for line in lines {
                var count = 0
                var inQ = false
                for ch in line {
                    if ch == "\"" { inQ.toggle() }
                    else if ch == cand && !inQ { count += 1 }
                }
                counts.append(count)
            }
            let nonZero = counts.filter { $0 > 0 }
            guard !nonZero.isEmpty else { continue }
            let mean = Double(nonZero.reduce(0, +)) / Double(nonZero.count)
            let variance = nonZero.map { pow(Double($0) - mean, 2) }.reduce(0, +) / Double(nonZero.count)
            let coverage = Double(nonZero.count) / Double(counts.count)
            // High mean, low variance, high coverage wins
            let score = mean * coverage / (1.0 + variance)
            if score > bestScore {
                bestScore = score
                best = cand
            }
        }
        return best
    }

    /// Header inference: first row is a header if its cells are non-empty, unique,
    /// and it is less numeric than the rows below it.
    static func inferHeader(_ rows: [[String]]) -> Bool {
        guard rows.count >= 2 else { return rows.count == 1 }
        let first = rows[0]
        guard !first.isEmpty, first.allSatisfy({ !$0.isEmpty }) else { return false }
        // Duplicate header names are common (bad exporters) — only reject when
        // every cell is identical, which is data, not a header.
        guard Set(first.map { $0.lowercased() }).count > 1 || first.count == 1 else { return false }

        func numericFraction(_ row: [String]) -> Double {
            guard !row.isEmpty else { return 0 }
            let numeric = row.filter { Double($0.replacingOccurrences(of: ",", with: "")) != nil }
            return Double(numeric.count) / Double(row.count)
        }
        let firstNumeric = numericFraction(first)
        let bodySample = rows.dropFirst().prefix(20)
        let bodyNumeric = bodySample.map(numericFraction).reduce(0, +) / Double(max(1, bodySample.count))
        if firstNumeric == 0 && bodyNumeric > 0 { return true }
        if firstNumeric < bodyNumeric - 0.3 { return true }
        // All-text data: still assume header if first row cells look like identifiers
        if firstNumeric == 0 && bodyNumeric == 0 {
            let identifierLike = first.allSatisfy { $0.count < 64 && !$0.contains("\n") }
            return identifierLike
        }
        return false
    }

    static func normalizeHeaderNames(_ header: [String], width: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for i in 0..<width {
            var name = i < header.count ? header[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if name.isEmpty { name = "column_\(i + 1)" }
            var candidate = name
            var n = 2
            while seen.contains(candidate.lowercased()) {
                candidate = "\(name)_\(n)"
                n += 1
            }
            seen.insert(candidate.lowercased())
            out.append(candidate)
        }
        return out
    }
}

/// CSV writer (RFC 4180: quote when needed, escape quotes by doubling).
public enum CSVWriter {
    public static func write(_ dataset: Dataset, delimiter: Character = ",") -> String {
        var out = ""
        out += dataset.columns.map { escape($0, delimiter: delimiter) }.joined(separator: String(delimiter))
        out += "\n"
        for record in dataset.records {
            let cells = record.values.map { escape($0.display, delimiter: delimiter) }
            out += cells.joined(separator: String(delimiter))
            out += "\n"
        }
        return out
    }

    static func escape(_ s: String, delimiter: Character) -> String {
        if s.contains("\"") || s.contains(delimiter) || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
