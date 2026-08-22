import Foundation

/// Plain text / Markdown / HTML / code-file reader. Produces a document-style
/// dataset: one row per logical unit with `text` + metadata columns, ready for
/// the chunker.
public enum TextReader {

    public enum SplitMode: String, Codable, Sendable, CaseIterable {
        case wholeFile      // one row per file
        case paragraphs     // blank-line separated
        case lines          // one row per non-empty line
        case markdownSections // split at headings, heading kept as metadata
    }

    public static func read(url: URL, mode: SplitMode = .wholeFile) throws -> Dataset {
        guard let data = try? Data(contentsOf: url) else {
            throw AlembicError.unreadableFile(url.lastPathComponent)
        }
        let decoded = EncodingDetector.decode(data)
        return read(text: decoded.text, sourceName: url.lastPathComponent, mode: mode)
    }

    public static func read(text: String, sourceName: String, mode: SplitMode) -> Dataset {
        switch mode {
        case .wholeFile:
            return Dataset.fresh(columns: ["text", "source"],
                                 rows: [[.string(text), .string(sourceName)]])
        case .paragraphs:
            let paras = splitParagraphs(text)
            return Dataset.fresh(columns: ["text", "source", "position"],
                                 rows: paras.enumerated().map { [.string($1), .string(sourceName), .int(Int64($0))] })
        case .lines:
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return Dataset.fresh(columns: ["text", "source", "position"],
                                 rows: lines.enumerated().map { [.string($1), .string(sourceName), .int(Int64($0))] })
        case .markdownSections:
            let sections = splitMarkdownSections(text)
            return Dataset.fresh(columns: ["text", "heading", "level", "source", "position"],
                                 rows: sections.enumerated().map { i, s in
                                     [.string(s.body), s.heading.isEmpty ? .null : .string(s.heading),
                                      .int(Int64(s.level)), .string(sourceName), .int(Int64(i))]
                                 })
        }
    }

    static func splitParagraphs(_ text: String) -> [String] {
        var paras: [String] = []
        var current: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    paras.append(current.joined(separator: "\n"))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paras.append(current.joined(separator: "\n")) }
        return paras
    }

    public struct MarkdownSection: Sendable {
        public let heading: String
        public let level: Int
        public let body: String
    }

    /// Split at ATX headings (#, ##, …). Content before the first heading becomes
    /// a level-0 preamble section. Fenced code blocks are respected (a `# comment`
    /// inside ``` is not a heading).
    static func splitMarkdownSections(_ text: String) -> [MarkdownSection] {
        var sections: [MarkdownSection] = []
        var heading = ""
        var level = 0
        var body: [String] = []
        var inFence = false

        func flush() {
            let content = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty || !heading.isEmpty {
                sections.append(MarkdownSection(heading: heading, level: level, body: content))
            }
            body = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, let (h, lvl) = parseHeading(trimmed) {
                flush()
                heading = h
                level = lvl
            } else {
                body.append(line)
            }
        }
        flush()
        return sections
    }

    static func parseHeading(_ line: String) -> (String, Int)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex && line[idx] == "#" && level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex, line[idx] == " " else { return nil }
        let title = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        return (title, level)
    }
}
