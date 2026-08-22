import Foundation

/// Deterministic PII / secret detection and redaction. Regex packs with
/// checksum validation where the format defines one (Luhn for cards, mod-97
/// for IBAN) to keep false positives down.
public enum PIIKind: String, Codable, Sendable, CaseIterable {
    case email
    case phone
    case ipAddress
    case creditCard
    case iban
    case ssn
    case apiKey
    case url_credentials
}

public enum RedactionMode: String, Codable, Sendable, CaseIterable {
    case tag        // "[EMAIL]"
    case hash       // "[EMAIL:a1b2c3d4]" — stable, preserves joinability
    case remove     // deleted outright
}

public struct PIIMatch: Sendable, Equatable {
    public let kind: PIIKind
    public let range: Range<String.Index>
    public let matched: String
}

public enum PIIDetector {

    struct Pack {
        let kind: PIIKind
        let regex: NSRegularExpression
        let validator: ((String) -> Bool)?
    }

    static let packs: [Pack] = {
        func rx(_ p: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p, options: [])
        }
        return [
            Pack(kind: .email,
                 regex: rx(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,24}"#),
                 validator: nil),
            Pack(kind: .url_credentials,
                 regex: rx(#"[a-zA-Z][a-zA-Z0-9+.-]*://[^\s/:@]+:[^\s/@]+@[^\s]+"#),
                 validator: nil),
            Pack(kind: .apiKey,
                 regex: rx(#"(sk-[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|ya29\.[0-9A-Za-z_-]{20,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})"#),
                 validator: nil),
            Pack(kind: .iban,
                 regex: rx(#"\b[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}\b"#),
                 validator: validIBAN),
            Pack(kind: .creditCard,
                 regex: rx(#"\b(?:\d[ -]?){13,19}\b"#),
                 validator: { luhnValid($0.filter(\.isNumber)) }),
            Pack(kind: .ssn,
                 regex: rx(#"\b\d{3}-\d{2}-\d{4}\b"#),
                 validator: { s in !s.hasPrefix("000") && !s.hasPrefix("666") && !s.hasPrefix("9") }),
            Pack(kind: .ipAddress,
                 regex: rx(#"\b(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\b|\b(?:[0-9a-fA-F]{1,4}:){4,7}[0-9a-fA-F]{1,4}\b"#),
                 validator: { s in
                     // Skip obvious version numbers like 1.2.3.4 in prose? Keep: they match IP shape.
                     // But drop all-zeros and localhost noise.
                     s != "0.0.0.0" && s != "127.0.0.1" && s != "::1"
                 }),
            Pack(kind: .phone,
                 regex: rx(#"(?<![\d.\w])(\+?[0-9]{1,3}[ .-]?)?(\(?\d{2,4}\)?[ .-]?)\d{3,4}[ .-]?\d{3,5}(?![\d.])"#),
                 validator: { s in
                     let digits = s.filter(\.isNumber)
                     // Phones are 7–15 digits; reject year-ranges and pure integers without separators
                     guard digits.count >= 8 && digits.count <= 15 else { return false }
                     let separators = s.filter { "+- .()".contains($0) }
                     return !separators.isEmpty
                 })
        ]
    }()

    /// Find all PII in `text`, longest/earliest match wins on overlap.
    /// Detection order gives specific kinds (email, key, iban, card) priority over
    /// generic ones (phone, ip).
    public static func detect(_ text: String, kinds: Set<PIIKind> = Set(PIIKind.allCases)) -> [PIIMatch] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var claimed: [NSRange] = []
        var matches: [PIIMatch] = []

        for pack in packs where kinds.contains(pack.kind) {
            for m in pack.regex.matches(in: text, options: [], range: full) {
                let r = m.range
                guard r.length > 0 else { continue }
                // Skip if overlapping something already claimed by a higher-priority pack
                if claimed.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
                let s = ns.substring(with: r)
                if let v = pack.validator, !v(s) { continue }
                guard let range = Range(r, in: text) else { continue }
                claimed.append(r)
                matches.append(PIIMatch(kind: pack.kind, range: range, matched: s))
            }
        }
        return matches.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Redact detected PII. Returns the redacted text and per-kind counts.
    public static func redact(_ text: String, kinds: Set<PIIKind> = Set(PIIKind.allCases),
                              mode: RedactionMode = .tag) -> (text: String, counts: [PIIKind: Int]) {
        let matches = detect(text, kinds: kinds)
        guard !matches.isEmpty else { return (text, [:]) }
        var counts: [PIIKind: Int] = [:]
        var out = text
        for m in matches.reversed() {   // reverse so ranges stay valid
            counts[m.kind, default: 0] += 1
            let replacement: String
            switch mode {
            case .tag:
                replacement = "[\(m.kind.rawValue.uppercased())]"
            case .hash:
                let h = String(format: "%08x", UInt32(truncatingIfNeeded: stableHash64(m.matched)))
                replacement = "[\(m.kind.rawValue.uppercased()):\(h)]"
            case .remove:
                replacement = ""
            }
            out.replaceSubrange(m.range, with: replacement)
        }
        return (out, counts)
    }

    // MARK: - Validators

    static func luhnValid(_ digits: String) -> Bool {
        guard digits.count >= 13, digits.count <= 19 else { return false }
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 {
                d *= 2
                if d > 9 { d -= 9 }
            }
            sum += d
        }
        // Exclude trivial all-same-digit sequences that pass Luhn (e.g. 0000…)
        guard Set(digits).count > 1 else { return false }
        return sum % 10 == 0
    }

    static func validIBAN(_ s: String) -> Bool {
        let iban = s.uppercased()
        guard iban.count >= 15, iban.count <= 34 else { return false }
        // Move first 4 chars to end, convert letters to numbers (A=10…Z=35), mod 97 == 1
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var remainder = 0
        for ch in rearranged {
            let v: Int
            if let d = ch.wholeNumberValue, ch.isNumber { v = d }
            else if let ascii = ch.asciiValue, ascii >= 65, ascii <= 90 { v = Int(ascii) - 55 }
            else { return false }
            if v >= 10 {
                remainder = (remainder * 100 + v) % 97
            } else {
                remainder = (remainder * 10 + v) % 97
            }
        }
        return remainder == 1
    }
}
