import Foundation

/// Per-column type inference and deterministic scalar parsing (no locale surprises).
public enum TypeInference {

    public enum ColumnType: String, Codable, Sendable, CaseIterable {
        case int, double, bool, date, string
    }

    public static let nullSentinels: Set<String> = [
        "", "na", "n/a", "nan", "null", "none", "nil", "-", "--", "?", "missing", "#n/a", "#null!", "(null)", "undefined"
    ]

    public static func isNullSentinel(_ s: String) -> Bool {
        nullSentinels.contains(s.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Infer the dominant type of a column from a sample of its string values.
    /// A type wins if ≥ 95% of non-null values parse as it.
    public static func inferType(samples: [String]) -> ColumnType {
        let nonNull = samples.filter { !isNullSentinel($0) }
        guard !nonNull.isEmpty else { return .string }
        let sample = nonNull.prefix(500)

        var intCount = 0, doubleCount = 0, boolCount = 0, dateCount = 0
        for s in sample {
            let t = s.trimmingCharacters(in: .whitespaces)
            if parseBool(t) != nil { boolCount += 1 }
            if parseInt(t) != nil { intCount += 1 }
            else if parseDouble(t) != nil { doubleCount += 1 }
            else if DateParser.parse(t) != nil { dateCount += 1 }
        }
        let n = Double(sample.count)
        let threshold = 0.95
        if Double(boolCount) / n >= threshold { return .bool }
        if Double(intCount) / n >= threshold { return .int }
        if Double(intCount + doubleCount) / n >= threshold { return .double }
        if Double(dateCount) / n >= threshold { return .date }
        return .string
    }

    /// Coerce a raw value to a target type; unparseable values become null.
    public static func coerce(_ value: Value, to type: ColumnType) -> Value {
        switch value {
        case .null: return .null
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            if isNullSentinel(t) { return .null }
            switch type {
            case .int: return parseInt(t).map(Value.int) ?? .null
            case .double: return parseDouble(t).map(Value.double) ?? .null
            case .bool: return parseBool(t).map(Value.bool) ?? .null
            case .date: return DateParser.parse(t).map(Value.date) ?? .null
            case .string: return value
            }
        default:
            switch type {
            case .string: return .string(value.display)
            case .double: return value.doubleValue.map(Value.double) ?? .null
            case .int:
                if case .int = value { return value }
                if let d = value.doubleValue, d == d.rounded() { return .int(Int64(d)) }
                return .null
            case .bool:
                if case .bool = value { return value }
                return .null
            case .date:
                if case .date = value { return value }
                return .null
            }
        }
    }

    public static func parseInt(_ s: String) -> Int64? {
        var t = s
        // Thousands separators: 1,234,567 (must be well-formed groups of 3)
        if t.contains(",") {
            let parts = t.split(separator: ",")
            guard parts.count > 1,
                  parts.dropFirst().allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isNumber) }) else { return nil }
            t = t.replacingOccurrences(of: ",", with: "")
        }
        guard !t.isEmpty, t.count <= 20 else { return nil }
        return Int64(t)
    }

    public static func parseDouble(_ s: String) -> Double? {
        var t = s
        if t.hasSuffix("%") {
            guard let d = parseDouble(String(t.dropLast())) else { return nil }
            return d / 100.0
        }
        // European style "1.234,56" → "1234.56" (only when clearly European)
        if t.contains(",") && t.contains(".") {
            if let lastComma = t.lastIndex(of: ","), let lastDot = t.lastIndex(of: "."), lastComma > lastDot {
                t = t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                t = t.replacingOccurrences(of: ",", with: "")
            }
        } else if t.contains(",") && !t.contains(".") {
            // "3,14" → decimal comma; "1,234" is ambiguous → treat as thousands
            let parts = t.split(separator: ",")
            if parts.count == 2 && parts[1].count != 3 {
                t = t.replacingOccurrences(of: ",", with: ".")
            } else {
                t = t.replacingOccurrences(of: ",", with: "")
            }
        }
        guard !t.isEmpty else { return nil }
        // Reject things Double() accepts but data almost never means (hex, inf spelled out is ok to reject too)
        let lowered = t.lowercased()
        if lowered.hasPrefix("0x") || lowered.contains("inf") { return nil }
        return Double(t)
    }

    public static func parseBool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true", "yes", "y", "t", "1️⃣": return true
        case "false", "no", "n", "f": return false
        default: return nil
        }
    }
}

/// Deterministic multi-format date parser. No system locale involvement:
/// every format is explicit, ambiguity (dd/mm vs mm/dd) is resolved by value
/// evidence, defaulting to day-first only when the day value proves it.
public enum DateParser {

    static let monthNames: [String: Int] = {
        var m: [String: Int] = [:]
        let full = ["january", "february", "march", "april", "may", "june", "july",
                    "august", "september", "october", "november", "december"]
        for (i, name) in full.enumerated() {
            m[name] = i + 1
            m[String(name.prefix(3))] = i + 1
        }
        m["sept"] = 9
        return m
    }()

    static var utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    public static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 6, t.count <= 40 else { return nil }

        // ISO 8601 with time
        if t.contains("T") || (t.count > 10 && t.contains(":")) {
            if let d = ISO8601DateFormatter.alembicShared.date(from: t) { return d }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: t) { return d }
            // "2024-01-15 10:30:00" (space instead of T)
            if let d = parseDateTime(t) { return d }
        }

        // Pure numeric: epoch seconds (10 digits) or millis (13 digits)
        if t.allSatisfy(\.isNumber) {
            if t.count == 10, let secs = Double(t), secs > 631_152_000 {   // ≥ 1990
                return Date(timeIntervalSince1970: secs)
            }
            if t.count == 13, let ms = Double(t) {
                return Date(timeIntervalSince1970: ms / 1000)
            }
            // 20240115 compact
            if t.count == 8, let y = Int(t.prefix(4)), let mo = Int(t.dropFirst(4).prefix(2)), let d = Int(t.suffix(2)),
               (1900...2100).contains(y), (1...12).contains(mo), (1...31).contains(d) {
                return makeDate(y, mo, d)
            }
            return nil
        }

        // yyyy-MM-dd / yyyy/MM/dd
        if let m = matchYMD(t) { return m }
        // dd/MM/yyyy, MM/dd/yyyy, dd.MM.yyyy, dd-MM-yyyy
        if let m = matchDMY(t) { return m }
        // "15 Jan 2024", "Jan 15, 2024", "January 15 2024"
        if let m = matchMonthName(t) { return m }
        return nil
    }

    static func parseDateTime(_ t: String) -> Date? {
        let parts = t.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let base = parse(String(parts[0])) else { return nil }
        let time = parts[1].split(separator: ":")
        guard time.count >= 2, let h = Int(time[0]), let mi = Int(time[1]) else { return base }
        let sec = time.count > 2 ? Int(time[2].prefix(2)) ?? 0 : 0
        return base.addingTimeInterval(TimeInterval(h * 3600 + mi * 60 + sec))
    }

    static func matchYMD(_ t: String) -> Date? {
        let seps: [Character] = ["-", "/"]
        for sep in seps {
            let parts = t.split(separator: sep)
            guard parts.count == 3,
                  let y = Int(parts[0]), let mo = Int(parts[1]), let d = Int(parts[2]),
                  (1000...9999).contains(y), (1...12).contains(mo), (1...31).contains(d) else { continue }
            return makeDate(y, mo, d)
        }
        return nil
    }

    static func matchDMY(_ t: String) -> Date? {
        let seps: [Character] = ["/", ".", "-"]
        for sep in seps {
            let parts = t.split(separator: sep)
            guard parts.count == 3,
                  let a = Int(parts[0]), let b = Int(parts[1]), var y = Int(parts[2]) else { continue }
            if y < 100 { y += y < 50 ? 2000 : 1900 }
            guard (1900...2100).contains(y) else { continue }
            // Disambiguate: value > 12 forces its slot to be the day
            if a > 12 && b <= 12 { return makeDate(y, b, a) }        // dd/MM
            if b > 12 && a <= 12 { return makeDate(y, a, b) }        // MM/dd
            if a <= 12 && b <= 12 {
                // Ambiguous — dot separator conventionally day-first (European), slash US month-first
                return sep == "." ? makeDate(y, b, a) : makeDate(y, a, b)
            }
            continue
        }
        return nil
    }

    static func matchMonthName(_ t: String) -> Date? {
        let cleaned = t.replacingOccurrences(of: ",", with: " ")
        let tokens = cleaned.split(separator: " ").map { $0.lowercased() }
        guard tokens.count >= 3 else { return nil }
        var month: Int?
        var day: Int?
        var year: Int?
        for tok in tokens {
            if let m = monthNames[String(tok)] { month = m }
            else if let n = Int(tok.trimmingCharacters(in: CharacterSet(charactersIn: "stndrdth"))) {
                if n > 31 { year = n } else if day == nil { day = n } else if year == nil { year = n }
            }
        }
        guard let m = month, let d = day, let y = year, (1...31).contains(d), (1000...9999).contains(y) else { return nil }
        return makeDate(y, m, d)
    }

    static func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date? {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        guard let date = utcCalendar.date(from: comps) else { return nil }
        // Reject impossible dates that Calendar rolls over (e.g. Feb 30 → Mar 2)
        let check = utcCalendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == y, check.month == m, check.day == d else { return nil }
        return date
    }
}
