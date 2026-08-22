import Foundation

/// Token counting/encoding abstraction. The engine ships a real byte-level BPE
/// (cl100k_base, the GPT-4/embeddings tokenizer, ~= modern LLM token economics)
/// plus a heuristic estimator fallback. Any .tiktoken-format vocab can be loaded.
public protocol Tokenizer: Sendable {
    var name: String { get }
    func encode(_ text: String) -> [Int]
    func countTokens(_ text: String) -> Int
}

public extension Tokenizer {
    func countTokens(_ text: String) -> Int { encode(text).count }
}

/// Byte-level BPE identical in behavior to tiktoken for a given vocab.
/// Vocab format: one `base64(tokenBytes) rank` pair per line.
public final class BPETokenizer: Tokenizer, @unchecked Sendable {
    public let name: String
    private let ranks: [[UInt8]: Int]
    private let splitter: NSRegularExpression

    /// cl100k_base pre-tokenization pattern (ICU supports the possessive quantifiers).
    static let cl100kPattern = #"'(?i:[sdmt]|ll|ve|re)|[^\r\n\p{L}\p{N}]?+\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]++[\r\n]*|\s*[\r\n]|\s+(?!\S)|\s+"#

    public init(name: String, vocabData: Data) throws {
        self.name = name
        guard let text = String(data: vocabData, encoding: .utf8) else {
            throw AlembicError.parseFailure("Tokenizer vocab is not UTF-8")
        }
        var r: [[UInt8]: Int] = [:]
        r.reserveCapacity(110_000)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2,
                  let tokenData = Data(base64Encoded: String(parts[0])),
                  let rank = Int(parts[1]) else { continue }
            r[[UInt8](tokenData)] = rank
        }
        guard r.count > 1000 else {
            throw AlembicError.parseFailure("Tokenizer vocab too small (\(r.count) entries)")
        }
        self.ranks = r
        self.splitter = try NSRegularExpression(pattern: Self.cl100kPattern, options: [])
    }

    /// Load the bundled cl100k_base vocab.
    public static func loadBundled() throws -> BPETokenizer {
        guard let url = Bundle.module.url(forResource: "cl100k_base", withExtension: "tiktoken"),
              let data = try? Data(contentsOf: url) else {
            throw AlembicError.unreadableFile("cl100k_base.tiktoken missing from bundle")
        }
        return try BPETokenizer(name: "cl100k_base", vocabData: data)
    }

    /// Shared instance — loads once; falls back to nil (callers use Estimator then).
    public static let shared: BPETokenizer? = try? BPETokenizer.loadBundled()

    public func encode(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        var tokens: [Int] = []
        let ns = text as NSString
        let matches = splitter.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let piece = ns.substring(with: m.range)
            tokens.append(contentsOf: encodePiece([UInt8](piece.utf8)))
        }
        return tokens
    }

    public func countTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 0
        let ns = text as NSString
        let matches = splitter.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let piece = ns.substring(with: m.range)
            count += countPiece([UInt8](piece.utf8))
        }
        return count
    }

    /// Standard BPE merge: start from single bytes, repeatedly merge the
    /// adjacent pair with the lowest rank until no merge applies.
    private func encodePiece(_ bytes: [UInt8]) -> [Int] {
        if bytes.count == 1 {
            return [ranks[bytes] ?? 0]
        }
        if let whole = ranks[bytes] { return [whole] }
        let parts = mergeParts(bytes)
        var out: [Int] = []
        out.reserveCapacity(parts.count)
        for range in parts {
            out.append(ranks[Array(bytes[range])] ?? 0)
        }
        return out
    }

    private func countPiece(_ bytes: [UInt8]) -> Int {
        if bytes.count == 1 { return 1 }
        if ranks[bytes] != nil { return 1 }
        return mergeParts(bytes).count
    }

    /// Returns the byte ranges of the final merged parts.
    private func mergeParts(_ bytes: [UInt8]) -> [Range<Int>] {
        // parts[i] = start index; sentinel at end
        var starts = Array(0...bytes.count)

        func rankOf(_ i: Int) -> Int {
            // rank of merging parts i and i+1 (bytes[starts[i]..<starts[i+2]])
            guard i + 2 < starts.count else { return Int.max }
            return ranks[Array(bytes[starts[i]..<starts[i + 2]])] ?? Int.max
        }

        while starts.count > 2 {
            var best = Int.max
            var bestIdx = -1
            for i in 0..<(starts.count - 2) {
                let r = rankOf(i)
                if r < best {
                    best = r
                    bestIdx = i
                }
            }
            guard bestIdx >= 0, best != Int.max else { break }
            starts.remove(at: bestIdx + 1)
        }
        var out: [Range<Int>] = []
        for i in 0..<(starts.count - 1) {
            out.append(starts[i]..<starts[i + 1])
        }
        return out
    }
}

/// Heuristic estimator used when no vocab is available. Calibrated against
/// cl100k on English prose (~4 chars/token, punctuation and CJK adjusted).
public struct EstimatorTokenizer: Tokenizer {
    public let name = "estimator"
    public init() {}

    public func encode(_ text: String) -> [Int] {
        // Fake ids; only the count is meaningful
        Array(repeating: 0, count: countTokens(text))
    }

    public func countTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var latinChars = 0, cjk = 0, digitsPunct = 0, spaces = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3040...0x30FF, 0xAC00...0xD7AF: cjk += 1
            case 0x30...0x39: digitsPunct += 1
            case 0x20, 0x09, 0x0A, 0x0D: spaces += 1
            default:
                if scalar.properties.isAlphabetic { latinChars += 1 } else { digitsPunct += 1 }
            }
        }
        // Words average ~1.3 tokens; CJK ~1 token per char; digits/punct ~1 per 2 chars
        let wordTokens = Double(latinChars) / 4.0 + Double(spaces) * 0.08
        let estimate = wordTokens + Double(cjk) + Double(digitsPunct) / 2.0
        return max(1, Int(estimate.rounded()))
    }
}

/// Engine-wide tokenizer access: real BPE when the bundled vocab loads,
/// estimator otherwise.
public enum TokenizerProvider {
    public static var current: any Tokenizer {
        BPETokenizer.shared ?? EstimatorTokenizer()
    }
}
