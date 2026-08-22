import XCTest
@testable import AlembicEngine

final class IODetectTests: XCTestCase {

    // MARK: - CSV

    func testCSVBasicWithHeader() throws {
        let csv = "name,age,city\nAlice,30,Berlin\nBob,25,Munich\n"
        let r = try CSVReader.read(text: csv)
        XCTAssertEqual(r.dataset.columns, ["name", "age", "city"])
        XCTAssertEqual(r.dataset.rowCount, 2)
        XCTAssertTrue(r.hadHeader)
        XCTAssertEqual(r.dataset.value(row: 0, column: "name"), .string("Alice"))
    }

    func testCSVQuotedFieldsEmbeddedDelimiterAndNewline() throws {
        let csv = "id,note\n1,\"hello, world\"\n2,\"line one\nline two\"\n3,\"she said \"\"hi\"\"\"\n"
        let r = try CSVReader.read(text: csv)
        XCTAssertEqual(r.dataset.rowCount, 3)
        XCTAssertEqual(r.dataset.value(row: 0, column: "note"), .string("hello, world"))
        XCTAssertEqual(r.dataset.value(row: 1, column: "note"), .string("line one\nline two"))
        XCTAssertEqual(r.dataset.value(row: 2, column: "note"), .string("she said \"hi\""))
    }

    func testCSVSniffsSemicolonAndTab() throws {
        let semi = "a;b;c\n1;2;3\n4;5;6\n"
        XCTAssertEqual(CSVReader.sniffDelimiter(semi), ";")
        let tab = "a\tb\tc\n1\t2\t3\n"
        XCTAssertEqual(CSVReader.sniffDelimiter(tab), "\t")
        let comma = "a,b\n\"x;y;z\",2\n\"p;q;r\",4\n"
        XCTAssertEqual(CSVReader.sniffDelimiter(comma), ",")
    }

    func testCSVRaggedRowsRepaired() throws {
        let csv = "a,b,c\n1,2,3\n4,5\n6,7,8,9\n"
        let r = try CSVReader.read(text: csv)
        XCTAssertEqual(r.dataset.rowCount, 3)
        XCTAssertEqual(r.raggedRowsRepaired, 2)
        XCTAssertEqual(r.dataset.value(row: 1, column: "c"), .null)          // padded
        XCTAssertEqual(r.dataset.value(row: 2, column: "c"), .string("8"))   // truncated
    }

    func testCSVNoHeaderDetected() throws {
        let csv = "1,2,3\n4,5,6\n7,8,9\n"
        let r = try CSVReader.read(text: csv)
        XCTAssertFalse(r.hadHeader)
        XCTAssertEqual(r.dataset.columns, ["column_1", "column_2", "column_3"])
        XCTAssertEqual(r.dataset.rowCount, 3)
    }

    func testCSVDuplicateHeaderNamesDisambiguated() throws {
        let csv = "id,name,name\n1,a,b\n"
        let r = try CSVReader.read(text: csv)
        XCTAssertEqual(r.dataset.columns, ["id", "name", "name_2"])
    }

    func testCSVWriterRoundTrip() throws {
        let csv = "name,note\nAlice,\"has, comma\"\nBob,\"has \"\"quote\"\"\"\n"
        let r = try CSVReader.read(text: csv)
        let written = CSVWriter.write(r.dataset)
        let reparsed = try CSVReader.read(text: written)
        XCTAssertEqual(reparsed.dataset.value(row: 0, column: "note"), .string("has, comma"))
        XCTAssertEqual(reparsed.dataset.value(row: 1, column: "note"), .string("has \"quote\""))
    }

    // MARK: - Encoding

    func testUTF8BOMStripped() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append("hello".data(using: .utf8)!)
        let r = EncodingDetector.decode(data)
        XCTAssertEqual(r.text, "hello")
        XCTAssertTrue(r.hadBOM)
    }

    func testWindows1252Fallback() {
        // "café" in windows-1252: caf + 0xE9
        let data = Data([0x63, 0x61, 0x66, 0xE9])
        let r = EncodingDetector.decode(data)
        XCTAssertEqual(r.text, "café")
        XCTAssertEqual(r.detectedEncoding, "windows-1252")
    }

    func testMojibakeRepair() {
        // UTF-8 "café résumé" wrongly decoded as latin1 → "cafÃ© rÃ©sumÃ©"
        let mangled = "cafÃ© rÃ©sumÃ© â€” itâ€™s Ã¼ber"
        let data = mangled.data(using: .utf8)!
        let r = EncodingDetector.decode(data)
        XCTAssertTrue(r.mojibakeRepairs > 0)
        XCTAssertTrue(r.text.contains("café"))
        XCTAssertTrue(r.text.contains("über"))
    }

    func testUTF16LEWithoutBOM() {
        let data = "hello world this is utf16".data(using: .utf16LittleEndian)!
        let r = EncodingDetector.decode(data)
        XCTAssertEqual(r.text, "hello world this is utf16")
    }

    // MARK: - JSON / JSONL

    func testJSONLBasic() throws {
        let jsonl = """
        {"prompt": "hi", "completion": "hello", "score": 5}
        {"prompt": "bye", "completion": "goodbye", "score": 3}
        """
        let r = try JSONReader.read(text: jsonl)
        XCTAssertEqual(r.format, "jsonl")
        XCTAssertEqual(r.dataset.rowCount, 2)
        XCTAssertEqual(r.dataset.value(row: 0, column: "score"), .int(5))
    }

    func testJSONArrayAndNestedFlattening() throws {
        let json = """
        [{"user": {"name": "a", "meta": {"age": 3}}, "tags": ["x", "y"]}]
        """
        let r = try JSONReader.read(text: json)
        XCTAssertEqual(r.format, "json-array")
        XCTAssertEqual(r.dataset.value(row: 0, column: "user.name"), .string("a"))
        XCTAssertEqual(r.dataset.value(row: 0, column: "user.meta.age"), .int(3))
        XCTAssertEqual(r.dataset.value(row: 0, column: "tags"), .string("x; y"))
    }

    func testJSONNestedFindsLargestArray() throws {
        let json = """
        {"meta": "x", "data": {"items": [{"a": 1}, {"a": 2}, {"a": 3}]}}
        """
        let r = try JSONReader.read(text: json)
        XCTAssertEqual(r.dataset.rowCount, 3)
    }

    func testJSONLBadLinesCounted() throws {
        let jsonl = """
        {"a": 1}
        NOT JSON
        {"a": 2}
        """
        let r = try JSONReader.read(text: jsonl)
        XCTAssertEqual(r.dataset.rowCount, 2)
        XCTAssertEqual(r.badLines, 1)
    }

    func testJSONLWriterRoundTrip() throws {
        let ds = Dataset.fresh(columns: ["text", "n"], rows: [
            [.string("hello"), .int(1)],
            [.string("line\nbreak"), .null]
        ])
        let jsonl = JSONLWriter.write(ds)
        let r = try JSONReader.read(text: jsonl)
        XCTAssertEqual(r.dataset.rowCount, 2)
        XCTAssertEqual(r.dataset.value(row: 1, column: "text"), .string("line\nbreak"))
    }

    // MARK: - Text / Markdown

    func testMarkdownSectionSplit() {
        let md = """
        Preamble text.

        # Title
        Intro paragraph.

        ## Section A
        Content A.

        ```
        # not a heading
        ```

        ## Section B
        Content B.
        """
        let sections = TextReader.splitMarkdownSections(md)
        XCTAssertEqual(sections.count, 4)
        XCTAssertEqual(sections[0].level, 0)
        XCTAssertEqual(sections[1].heading, "Title")
        XCTAssertEqual(sections[2].heading, "Section A")
        XCTAssertTrue(sections[2].body.contains("# not a heading"))
        XCTAssertEqual(sections[3].heading, "Section B")
    }

    func testParagraphSplit() {
        let ds = TextReader.read(text: "one\ntwo\n\nthree\n\n\nfour", sourceName: "t", mode: .paragraphs)
        XCTAssertEqual(ds.rowCount, 3)
        XCTAssertEqual(ds.value(row: 0, column: "text"), .string("one\ntwo"))
    }

    // MARK: - Type inference & dates

    func testTypeInference() {
        XCTAssertEqual(TypeInference.inferType(samples: ["1", "2", "300"]), .int)
        XCTAssertEqual(TypeInference.inferType(samples: ["1.5", "2", "3.7"]), .double)
        XCTAssertEqual(TypeInference.inferType(samples: ["true", "false", "yes"]), .bool)
        XCTAssertEqual(TypeInference.inferType(samples: ["2024-01-15", "2023-06-01"]), .date)
        XCTAssertEqual(TypeInference.inferType(samples: ["hello", "1", "world"]), .string)
        XCTAssertEqual(TypeInference.inferType(samples: ["NA", "", "5", "7"]), .int)  // sentinels ignored
    }

    func testNumberParsing() {
        XCTAssertEqual(TypeInference.parseInt("1,234,567"), 1_234_567)
        XCTAssertNil(TypeInference.parseInt("1,23"))
        XCTAssertEqual(TypeInference.parseDouble("1.234,56"), 1234.56)   // European
        XCTAssertEqual(TypeInference.parseDouble("1,234.56"), 1234.56)   // US
        XCTAssertEqual(TypeInference.parseDouble("3,14"), 3.14)          // decimal comma
        XCTAssertEqual(TypeInference.parseDouble("50%"), 0.5)
        XCTAssertNil(TypeInference.parseDouble("0x1F"))
    }

    func testDateParsing() {
        func day(_ d: Date?) -> DateComponents? {
            guard let d else { return nil }
            return DateParser.utcCalendar.dateComponents([.year, .month, .day], from: d)
        }
        let iso = day(DateParser.parse("2024-01-15"))
        XCTAssertEqual([iso?.year, iso?.month, iso?.day], [2024, 1, 15])

        let dmyForced = day(DateParser.parse("25/12/2023"))     // 25 > 12 ⇒ day-first
        XCTAssertEqual([dmyForced?.month, dmyForced?.day], [12, 25])

        let mdyForced = day(DateParser.parse("12/25/2023"))     // 25 > 12 in slot 2 ⇒ month-first
        XCTAssertEqual([mdyForced?.month, mdyForced?.day], [12, 25])

        let german = day(DateParser.parse("15.01.2024"))        // dot ⇒ day-first
        XCTAssertEqual([german?.month, german?.day], [1, 15])

        let name = day(DateParser.parse("Jan 15, 2024"))
        XCTAssertEqual([name?.year, name?.month, name?.day], [2024, 1, 15])

        let name2 = day(DateParser.parse("15 January 2024"))
        XCTAssertEqual([name2?.month, name2?.day], [1, 15])

        XCTAssertNotNil(DateParser.parse("2024-01-15T10:30:00Z"))
        XCTAssertNotNil(DateParser.parse("1700000000"))          // epoch
        XCTAssertNotNil(DateParser.parse("20240115"))            // compact

        XCTAssertNil(DateParser.parse("30/02/2024"))             // impossible date
        XCTAssertNil(DateParser.parse("hello"))
        XCTAssertNil(DateParser.parse("12345"))
    }

    // MARK: - Language ID

    func testLanguageDetection() {
        XCTAssertEqual(LanguageID.detect("The quick brown fox jumps over the lazy dog and it was good.").code, "en")
        XCTAssertEqual(LanguageID.detect("Der schnelle braune Fuchs springt über den faulen Hund und das ist gut.").code, "de")
        XCTAssertEqual(LanguageID.detect("Le renard brun rapide saute par-dessus le chien paresseux dans la forêt.").code, "fr")
        XCTAssertEqual(LanguageID.detect("这是一段中文文本，用来测试语言检测功能是否正常工作。").code, "zh")
        XCTAssertEqual(LanguageID.detect("これは日本語のテキストです。言語検出のテストに使います。").code, "ja")
        XCTAssertEqual(LanguageID.detect("Это русский текст для проверки определения языка в системе.").code, "ru")
        XCTAssertEqual(LanguageID.detect("12345 67890 !!!").code, "und")
    }

    // MARK: - SQLite

    func testSQLiteRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alembic-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("test.sqlite")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE items (id INTEGER, name TEXT, price REAL, blob_col BLOB)", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO items VALUES (1, 'apple', 1.5, x'DEAD'), (2, 'pear', NULL, NULL)", nil, nil, nil)
        sqlite3_close(db)

        let tables = try SQLiteReader.tableNames(url: dbURL)
        XCTAssertEqual(tables, ["items"])
        let ds = try SQLiteReader.read(url: dbURL, table: "items")
        XCTAssertEqual(ds.rowCount, 2)
        XCTAssertEqual(ds.value(row: 0, column: "id"), .int(1))
        XCTAssertEqual(ds.value(row: 0, column: "price"), .double(1.5))
        XCTAssertEqual(ds.value(row: 1, column: "price"), .null)
    }

    // MARK: - Importer

    func testImporterDetection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alembic-imp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let csvURL = dir.appendingPathComponent("data.csv")
        try "a,b\n1,2\n".write(to: csvURL, atomically: true, encoding: .utf8)
        let outcome = try Importer.importFile(url: csvURL)
        XCTAssertEqual(outcome.format, .csv)
        XCTAssertEqual(outcome.dataset.rowCount, 1)

        let jsonlURL = dir.appendingPathComponent("data.jsonl")
        try "{\"x\": 1}\n{\"x\": 2}\n".write(to: jsonlURL, atomically: true, encoding: .utf8)
        let j = try Importer.importFile(url: jsonlURL)
        XCTAssertEqual(j.dataset.rowCount, 2)
    }
}

import SQLite3
