import Foundation

/// Deterministic text normalization — the workhorse cleaning pass.
/// Every option is independent and composable; the struct is Codable so a
/// recipe replays byte-identically.
public struct NormalizeOptions: Codable, Sendable, Equatable {
    public var unicodeForm: UnicodeForm = .nfc
    public var trimWhitespace = true
    public var collapseInnerWhitespace = false
    public var stripControlCharacters = true
    public var stripZeroWidth = true
    public var canonicalizeQuotes = false
    public var canonicalizeDashes = false
    public var decodeHTMLEntities = false
    public var stripHTMLTags = false
    public var collapseRepeatedPunctuation = false
    public var normalizeNewlines = true
    public var lowercase = false

    public enum UnicodeForm: String, Codable, Sendable, CaseIterable {
        case none, nfc, nfkc
    }

    public init() {}

    public static var standard: NormalizeOptions { NormalizeOptions() }

    public static var aggressive: NormalizeOptions {
        var o = NormalizeOptions()
        o.unicodeForm = .nfkc
        o.collapseInnerWhitespace = true
        o.canonicalizeQuotes = true
        o.canonicalizeDashes = true
        o.decodeHTMLEntities = true
        o.stripHTMLTags = true
        o.collapseRepeatedPunctuation = true
        return o
    }
}

public enum TextNormalizer {

    /// Apply all enabled normalizations in a fixed, documented order.
    public static func normalize(_ input: String, options: NormalizeOptions) -> String {
        var s = input

        // 1. HTML first (entities may decode to things later passes handle)
        if options.stripHTMLTags { s = HTMLCleaner.stripTags(s) }
        if options.decodeHTMLEntities { s = HTMLCleaner.decodeEntities(s) }

        // 2. Unicode normalization
        switch options.unicodeForm {
        case .nfc: s = s.precomposedStringWithCanonicalMapping
        case .nfkc: s = s.precomposedStringWithCompatibilityMapping
        case .none: break
        }

        // 3. Character-level cleanup
        if options.stripZeroWidth {
            s = String(s.unicodeScalars.filter { !Self.zeroWidthScalars.contains($0.value) }.map(Character.init))
        }
        if options.stripControlCharacters {
            s = String(s.unicodeScalars.filter { scalar in
                !(scalar.properties.generalCategory == .control && scalar != "\n" && scalar != "\t" && scalar != "\r")
            }.map(Character.init))
        }
        if options.normalizeNewlines {
            s = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        if options.canonicalizeQuotes {
            for (from, to) in Self.quoteMap { s = s.replacingOccurrences(of: from, with: to) }
        }
        if options.canonicalizeDashes {
            for (from, to) in Self.dashMap { s = s.replacingOccurrences(of: from, with: to) }
        }
        if options.collapseRepeatedPunctuation {
            s = collapseRuns(s, of: ".", keep: 3)   // preserve ellipsis
            for p: Character in ["!", "?", ",", ";", ":"] { s = collapseRuns(s, of: p, keep: 1) }
        }

        // 4. Whitespace last
        if options.collapseInnerWhitespace {
            // Collapse runs of spaces/tabs; preserve single newlines, collapse 3+ newlines to 2
            s = s.replacingOccurrences(of: "[ \\t\u{00A0}]+", with: " ", options: .regularExpression)
            s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        }
        if options.trimWhitespace {
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if options.lowercase { s = s.lowercased() }
        return s
    }

    static let zeroWidthScalars: Set<UInt32> = [
        0x200B, // zero-width space
        0x200C, // zero-width non-joiner
        0x200D, // zero-width joiner
        0x2060, // word joiner
        0xFEFF, // BOM / zero-width no-break
        0x00AD, // soft hyphen
        0x180E  // mongolian vowel separator
    ]

    static let quoteMap: [(String, String)] = [
        ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201A}", "'"), ("\u{201B}", "'"),
        ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{201E}", "\""), ("\u{201F}", "\""),
        ("\u{00AB}", "\""), ("\u{00BB}", "\""), ("\u{2039}", "'"), ("\u{203A}", "'"),
        ("\u{0060}", "'"), ("\u{00B4}", "'")
    ]

    static let dashMap: [(String, String)] = [
        ("\u{2014}", "-"), ("\u{2013}", "-"), ("\u{2012}", "-"), ("\u{2015}", "-"), ("\u{2212}", "-")
    ]

    static func collapseRuns(_ s: String, of ch: Character, keep: Int) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var run = 0
        for c in s {
            if c == ch {
                run += 1
                if run <= keep { out.append(c) }
            } else {
                run = 0
                out.append(c)
            }
        }
        return out
    }
}

/// HTML stripping + entity decoding without WebKit (pure, fast, offline).
public enum HTMLCleaner {

    /// Remove tags; scripts/styles removed with their content. Block-level tags
    /// become newlines so text structure survives.
    public static func stripTags(_ html: String) -> String {
        var s = html
        // Kill script/style/head blocks entirely
        for tag in ["script", "style", "head", "noscript", "svg"] {
            s = s.replacingOccurrences(
                of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
                with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // Comments
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        // Block-level closers → newline
        s = s.replacingOccurrences(
            of: "</?(p|div|br|li|ul|ol|h[1-6]|tr|table|section|article|blockquote|pre)[^>]*>",
            with: "\n", options: [.regularExpression, .caseInsensitive])
        // All remaining tags
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Tidy the aftermath
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " ?\n ?", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "copy": "©", "reg": "®", "trade": "™",
        "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "\u{2018}",
        "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "eacute": "é", "egrave": "è", "agrave": "à", "uuml": "ü",
        "ouml": "ö", "auml": "ä", "szlig": "ß", "ccedil": "ç",
        "ntilde": "ñ", "deg": "°", "euro": "€", "pound": "£", "yen": "¥",
        "sect": "§", "para": "¶", "middot": "·", "laquo": "«", "raquo": "»",
        "times": "×", "divide": "÷", "plusmn": "±", "frac12": "½", "frac14": "¼"
    ]

    /// Decode &name;, &#123;, and &#x1F600; entities.
    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let body = String(s[s.index(after: i)..<semi])
                var decoded: String?
                if body.hasPrefix("#x") || body.hasPrefix("#X") {
                    if let code = UInt32(body.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                        decoded = String(Character(scalar))
                    }
                } else if body.hasPrefix("#") {
                    if let code = UInt32(body.dropFirst()), let scalar = Unicode.Scalar(code) {
                        decoded = String(Character(scalar))
                    }
                } else {
                    decoded = namedEntities[body]
                }
                if let d = decoded {
                    out += d
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(ch)
            i = s.index(after: i)
        }
        return out
    }
}
