import Foundation

/// Training-grade quality heuristics, in the tradition of C4/Gopher/RefinedWeb
/// filtering rules. Each rule is independently togglable and every rejection
/// carries a reason, so nothing is silently dropped.
public struct QualityRules: Codable, Sendable, Equatable {
    public var minWords = 3
    public var maxWords = 100_000
    public var minMeanWordLength = 2.0
    public var maxMeanWordLength = 12.0
    public var maxSymbolRatio = 0.3          // non-alphanumeric, non-space fraction
    public var maxDigitRatio = 0.5
    public var maxUppercaseRatio = 0.6
    public var maxDuplicateLineRatio = 0.4   // fraction of lines that are repeats
    public var maxTopBigramRatio = 0.25      // most frequent bigram's share of all bigrams
    public var requireTerminalPunctuation = false
    public var minAlphaRatio = 0.5           // letters / non-space chars
    public var flagTruncated = true          // ends mid-word/with dangling connector

    public init() {}
    public static var standard: QualityRules { QualityRules() }
}

public struct QualityVerdict: Sendable, Equatable {
    public let passed: Bool
    public let reasons: [String]
    public let score: Double  // 0 (junk) … 1 (clean)
}

public enum QualityFilter {

    public static func evaluate(_ text: String, rules: QualityRules = .standard) -> QualityVerdict {
        var reasons: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return QualityVerdict(passed: false, reasons: ["empty"], score: 0)
        }

        let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        let wordCount = words.count

        if wordCount < rules.minWords { reasons.append("too_few_words(\(wordCount))") }
        if wordCount > rules.maxWords { reasons.append("too_many_words(\(wordCount))") }

        if wordCount > 0 {
            let meanLen = Double(words.reduce(0) { $0 + $1.count }) / Double(wordCount)
            if meanLen < rules.minMeanWordLength { reasons.append("mean_word_length_low(\(String(format: "%.1f", meanLen)))") }
            if meanLen > rules.maxMeanWordLength { reasons.append("mean_word_length_high(\(String(format: "%.1f", meanLen)))") }
        }

        // Character class ratios
        var letters = 0, digits = 0, symbols = 0, uppers = 0, nonSpace = 0
        for ch in trimmed {
            if ch.isWhitespace { continue }
            nonSpace += 1
            if ch.isLetter {
                letters += 1
                if ch.isUppercase { uppers += 1 }
            } else if ch.isNumber {
                digits += 1
            } else {
                symbols += 1
            }
        }
        if nonSpace > 0 {
            let symbolRatio = Double(symbols) / Double(nonSpace)
            let digitRatio = Double(digits) / Double(nonSpace)
            let alphaRatio = Double(letters) / Double(nonSpace)
            if symbolRatio > rules.maxSymbolRatio { reasons.append("symbol_ratio(\(String(format: "%.2f", symbolRatio)))") }
            if digitRatio > rules.maxDigitRatio { reasons.append("digit_ratio(\(String(format: "%.2f", digitRatio)))") }
            if alphaRatio < rules.minAlphaRatio { reasons.append("alpha_ratio_low(\(String(format: "%.2f", alphaRatio)))") }
        }
        if letters > 20 {
            let upperRatio = Double(uppers) / Double(letters)
            if upperRatio > rules.maxUppercaseRatio { reasons.append("uppercase_ratio(\(String(format: "%.2f", upperRatio)))") }
        }

        // Duplicate lines
        let lines = trimmed.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.count >= 4 {
            let unique = Set(lines).count
            let dupRatio = 1.0 - Double(unique) / Double(lines.count)
            if dupRatio > rules.maxDuplicateLineRatio { reasons.append("duplicate_lines(\(String(format: "%.2f", dupRatio)))") }
        }

        // n-gram bloat: most frequent bigram share
        if wordCount >= 20 {
            var bigrams: [UInt64: Int] = [:]
            let lowered = words.map { $0.lowercased() }
            for i in 0..<(lowered.count - 1) {
                bigrams[stableHash64(lowered[i] + " " + lowered[i + 1]), default: 0] += 1
            }
            if let top = bigrams.values.max() {
                let share = Double(top) / Double(lowered.count - 1)
                if share > rules.maxTopBigramRatio { reasons.append("repetitive_bigram(\(String(format: "%.2f", share)))") }
            }
        }

        if rules.requireTerminalPunctuation {
            let terminals: Set<Character> = [".", "!", "?", "\"", "\u{201D}", "。", "！", "？", ")", ":"]
            if let last = trimmed.last, !terminals.contains(last) {
                reasons.append("no_terminal_punctuation")
            }
        }

        if rules.flagTruncated && wordCount >= 10 {
            let danglers: Set<String> = ["the", "a", "an", "and", "or", "but", "of", "to", "in", "with", "for", "is", "was", "der", "die", "das", "und", "le", "la", "et", "de"]
            if let lastWord = words.last?.lowercased(), danglers.contains(lastWord) {
                reasons.append("truncated_ending")
            } else if trimmed.hasSuffix("...") || trimmed.hasSuffix("…") || trimmed.hasSuffix(",") || trimmed.hasSuffix("-") {
                reasons.append("truncated_ending")
            }
        }

        let score = max(0.0, 1.0 - Double(reasons.count) * 0.25)
        return QualityVerdict(passed: reasons.isEmpty, reasons: reasons, score: score)
    }
}
