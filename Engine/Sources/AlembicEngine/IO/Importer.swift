import Foundation

/// Format detection + one-call import for the app layer.
public enum Importer {

    public enum Format: String, Sendable, CaseIterable {
        case csv, tsv, json, jsonl, text, markdown, html, sqlite, code
    }

    public struct ImportOutcome: Sendable {
        public let dataset: Dataset
        public let format: Format
        public let details: [String: String]
    }

    public static func detectFormat(url: URL) -> Format {
        switch url.pathExtension.lowercased() {
        case "csv": return .csv
        case "tsv", "tab": return .tsv
        case "json": return .json
        case "jsonl", "ndjson": return .jsonl
        case "md", "markdown": return .markdown
        case "html", "htm", "xhtml": return .html
        case "db", "sqlite", "sqlite3": return .sqlite
        case "txt", "text", "log": return .text
        case "swift", "py", "js", "ts", "rs", "go", "java", "c", "cpp", "h", "rb", "sh", "css", "yaml", "yml", "toml", "xml": return .code
        default:
            // Content sniff for extensionless files
            if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
                let head = String(data: data.prefix(2048), encoding: .utf8) ?? ""
                let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return .json }
                if trimmed.contains("\t") && trimmed.contains("\n") { return .tsv }
                if trimmed.contains(",") && trimmed.contains("\n") { return .csv }
            }
            return .text
        }
    }

    public static func importFile(url: URL, textMode: TextReader.SplitMode = .wholeFile,
                                  sqliteTable: String? = nil) throws -> ImportOutcome {
        let format = detectFormat(url: url)
        switch format {
        case .csv:
            let r = try CSVReader.read(url: url)
            return ImportOutcome(dataset: r.dataset, format: .csv, details: [
                "delimiter": r.delimiter == "\t" ? "tab" : String(r.delimiter),
                "header": r.hadHeader ? "detected" : "generated",
                "encoding": r.encoding,
                "raggedRepaired": String(r.raggedRowsRepaired)
            ])
        case .tsv:
            let r = try CSVReader.read(url: url, options: .init(delimiter: "\t"))
            return ImportOutcome(dataset: r.dataset, format: .tsv, details: [
                "header": r.hadHeader ? "detected" : "generated",
                "encoding": r.encoding
            ])
        case .json, .jsonl:
            let r = try JSONReader.read(url: url)
            return ImportOutcome(dataset: r.dataset, format: format, details: [
                "structure": r.format,
                "badLines": String(r.badLines)
            ])
        case .markdown:
            let ds = try TextReader.read(url: url, mode: textMode == .wholeFile ? .markdownSections : textMode)
            return ImportOutcome(dataset: ds, format: .markdown, details: [:])
        case .html:
            guard let data = try? Data(contentsOf: url) else { throw AlembicError.unreadableFile(url.lastPathComponent) }
            let decoded = EncodingDetector.decode(data)
            let text = HTMLCleaner.decodeEntities(HTMLCleaner.stripTags(decoded.text))
            let ds = TextReader.read(text: text, sourceName: url.lastPathComponent,
                                     mode: textMode == .wholeFile ? .paragraphs : textMode)
            return ImportOutcome(dataset: ds, format: .html, details: ["stripped": "tags+entities"])
        case .sqlite:
            let tables = try SQLiteReader.tableNames(url: url)
            guard let table = sqliteTable ?? tables.first else {
                throw AlembicError.parseFailure("No tables in database")
            }
            let ds = try SQLiteReader.read(url: url, table: table)
            return ImportOutcome(dataset: ds, format: .sqlite, details: [
                "table": table,
                "availableTables": tables.joined(separator: ", ")
            ])
        case .text, .code:
            let ds = try TextReader.read(url: url, mode: textMode)
            return ImportOutcome(dataset: ds, format: format, details: [:])
        }
    }

    /// Import a folder: every supported file becomes rows in one combined
    /// document-style dataset (text/source columns), ready for chunking.
    public static func importFolder(url: URL, textMode: TextReader.SplitMode = .wholeFile) throws -> ImportOutcome {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw AlembicError.unreadableFile(url.lastPathComponent)
        }
        var combined = Dataset(columns: ["text", "source"])
        var rows: [[Value]] = []
        var fileCount = 0
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let format = detectFormat(url: fileURL)
            guard [.text, .markdown, .code, .html].contains(format) else { continue }
            guard let outcome = try? importFile(url: fileURL, textMode: textMode) else { continue }
            fileCount += 1
            let rel = fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
            if let textIdx = outcome.dataset.columnIndex(of: "text") {
                for r in outcome.dataset.records where textIdx < r.values.count {
                    rows.append([r.values[textIdx], .string(rel)])
                }
            }
            if fileCount >= 5000 { break }   // sanity cap
        }
        combined = Dataset.fresh(columns: ["text", "source"], rows: rows)
        return ImportOutcome(dataset: combined, format: .text, details: ["files": String(fileCount)])
    }
}
