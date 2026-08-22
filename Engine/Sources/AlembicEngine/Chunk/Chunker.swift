import Foundation

/// Semantic chunking for RAG: token-budgeted, sentence-aware, never cuts
/// mid-sentence (unless a single sentence exceeds the budget, in which case it
/// splits at word boundaries). Optional markdown-structure awareness keeps
/// heading context attached to every chunk.
public struct ChunkerConfig: Codable, Sendable, Equatable {
    public var targetTokens = 512
    public var overlapTokens = 64
    public var respectMarkdown = true
    public var minChunkTokens = 24          // tail chunks smaller than this merge backward
    public var includeHeadingContext = true // prefix "H1 > H2" breadcrumb to chunk text

    public init() {}
}

public struct Chunk: Sendable, Equatable {
    public let text: String
    public let tokenCount: Int
    public let index: Int
    public let headingPath: String   // "Guide > Installation" or ""
}

public enum Chunker {

    public static func chunk(_ text: String, config: ChunkerConfig = ChunkerConfig(),
                             tokenizer: any Tokenizer = TokenizerProvider.current) -> [Chunk] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var pieces: [(heading: String, body: String)]
        if config.respectMarkdown && text.contains("#") {
            let sections = TextReader.splitMarkdownSections(text)
            if sections.count > 1 {
                pieces = buildHeadingPaths(sections)
            } else {
                pieces = [("", text)]
            }
        } else {
            pieces = [("", text)]
        }

        var chunks: [Chunk] = []
        for piece in pieces {
            let body = piece.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let sectionChunks = chunkSection(body, headingPath: piece.heading,
                                             config: config, tokenizer: tokenizer)
            chunks.append(contentsOf: sectionChunks)
        }

        // Merge undersized tail chunks backward within same heading
        var merged: [Chunk] = []
        for c in chunks {
            if c.tokenCount < config.minChunkTokens, let last = merged.last,
               last.headingPath == c.headingPath,
               last.tokenCount + c.tokenCount <= config.targetTokens + config.overlapTokens {
                let combined = last.text + "\n\n" + c.text
                merged[merged.count - 1] = Chunk(text: combined,
                                                 tokenCount: tokenizer.countTokens(combined),
                                                 index: last.index, headingPath: last.headingPath)
            } else {
                merged.append(c)
            }
        }
        // Re-index
        return merged.enumerated().map { i, c in
            Chunk(text: c.text, tokenCount: c.tokenCount, index: i, headingPath: c.headingPath)
        }
    }

    static func buildHeadingPaths(_ sections: [TextReader.MarkdownSection]) -> [(String, String)] {
        var stack: [(level: Int, title: String)] = []
        var out: [(String, String)] = []
        for s in sections {
            if s.level > 0 {
                while let top = stack.last, top.level >= s.level { stack.removeLast() }
                stack.append((s.level, s.heading))
            }
            let path = stack.map(\.title).joined(separator: " > ")
            out.append((path, s.body))
        }
        return out
    }

    static func chunkSection(_ body: String, headingPath: String,
                             config: ChunkerConfig, tokenizer: any Tokenizer) -> [Chunk] {
        let prefix = (config.includeHeadingContext && !headingPath.isEmpty) ? "[\(headingPath)]\n" : ""
        let prefixTokens = prefix.isEmpty ? 0 : tokenizer.countTokens(prefix)
        let budget = max(32, config.targetTokens - prefixTokens)

        let sentences = splitSentences(body)
        let sentenceTokens = sentences.map { tokenizer.countTokens($0) }

        var chunks: [Chunk] = []
        var current: [Int] = []       // sentence indices
        var currentTokens = 0

        func flush() {
            guard !current.isEmpty else { return }
            let text = prefix + current.map { sentences[$0] }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            chunks.append(Chunk(text: text, tokenCount: tokenizer.countTokens(text),
                                index: chunks.count, headingPath: headingPath))
        }

        var i = 0
        while i < sentences.count {
            let tks = sentenceTokens[i]
            if tks > budget {
                // Giant sentence: flush current, then hard-split at word boundaries
                flush(); current = []; currentTokens = 0
                for part in splitLongSentence(sentences[i], budget: budget, tokenizer: tokenizer) {
                    let text = prefix + part
                    chunks.append(Chunk(text: text, tokenCount: tokenizer.countTokens(text),
                                        index: chunks.count, headingPath: headingPath))
                }
                i += 1
                continue
            }
            if currentTokens + tks > budget && !current.isEmpty {
                flush()
                // Overlap: walk back sentences until overlap budget reached
                var overlap: [Int] = []
                var overlapTokens = 0
                for j in current.reversed() {
                    if overlapTokens + sentenceTokens[j] > config.overlapTokens { break }
                    overlap.insert(j, at: 0)
                    overlapTokens += sentenceTokens[j]
                }
                current = overlap
                currentTokens = overlapTokens
            }
            current.append(i)
            currentTokens += tks
            i += 1
        }
        flush()
        return chunks
    }

    /// Sentence splitter: terminal punctuation + newlines, with abbreviation and
    /// decimal-number guards. Not Punkt, but deliberate and deterministic.
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "eg", "ie",
        "e.g", "i.e", "inc", "ltd", "co", "corp", "dept", "est", "fig", "no", "vol",
        "approx", "appt", "apt", "ave", "blvd", "cf", "al", "ed", "eds", "min", "max"
    ]

    public static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""

        func flushCurrent() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { sentences.append(t) }
            current = ""
        }

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            current.append(ch)

            if ch == "\n" {
                // Paragraph/newline boundary is always a sentence boundary
                flushCurrent()
            } else if ch == "." || ch == "!" || ch == "?" || ch == "。" || ch == "！" || ch == "？" {
                // Look ahead: boundary only if followed by whitespace + capital/EOF/quote
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                let isEnd = i + 1 >= chars.count
                if ch == "." {
                    // Decimal number guard: 3.14
                    if i + 1 < chars.count, chars[i + 1].isNumber, i > 0, chars[i - 1].isNumber {
                        i += 1; continue
                    }
                    // Abbreviation guard
                    let lastWord = lastToken(of: current.dropLast())
                    if abbreviations.contains(lastWord.lowercased()) { i += 1; continue }
                    // Initials like "J. K."
                    if lastWord.count == 1, lastWord.first?.isUppercase == true { i += 1; continue }
                }
                // Lowercase lookahead: "3 p.m. sharp" — a period followed by a
                // lowercase word is (almost) never a sentence boundary.
                if ch == "." && !isEnd {
                    var k = i + 1
                    while k < chars.count && chars[k] == " " { k += 1 }
                    if k < chars.count && chars[k].isLowercase { i += 1; continue }
                }
                if isEnd || next == " " || next == "\n" || next == "\"" || next == "\u{201D}" || next == ")" {
                    // Consume trailing quote/paren into this sentence
                    while i + 1 < chars.count, chars[i + 1] == "\"" || chars[i + 1] == "\u{201D}" || chars[i + 1] == ")" {
                        i += 1
                        current.append(chars[i])
                    }
                    flushCurrent()
                }
            }
            i += 1
        }
        flushCurrent()
        return sentences
    }

    static func lastToken(of s: Substring) -> String {
        var out = ""
        for ch in s.reversed() {
            if ch.isLetter || ch == "." { out.insert(ch, at: out.startIndex) }
            else { break }
        }
        if out.hasSuffix(".") { out.removeLast() }
        if let dotIdx = out.lastIndex(of: ".") {
            out = String(out[out.index(after: dotIdx)...])
        }
        return out
    }

    static func splitLongSentence(_ sentence: String, budget: Int, tokenizer: any Tokenizer) -> [String] {
        let words = sentence.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [sentence] }
        var parts: [String] = []
        var current: [String] = []
        var tokens = 0
        for w in words {
            let wt = tokenizer.countTokens(w) + 1
            if tokens + wt > budget && !current.isEmpty {
                parts.append(current.joined(separator: " "))
                current = []
                tokens = 0
            }
            current.append(w)
            tokens += wt
        }
        if !current.isEmpty { parts.append(current.joined(separator: " ")) }
        return parts
    }
}
