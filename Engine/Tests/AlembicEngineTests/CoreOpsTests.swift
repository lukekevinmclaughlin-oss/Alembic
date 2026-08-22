import XCTest
@testable import AlembicEngine

final class CoreOpsTests: XCTestCase {

    // MARK: - Normalization

    func testNormalizeStandard() {
        let opts = NormalizeOptions.standard
        XCTAssertEqual(TextNormalizer.normalize("  hello \r\nworld  ", options: opts), "hello \nworld")
        XCTAssertEqual(TextNormalizer.normalize("a\u{200B}b\u{FEFF}c", options: opts), "abc")   // zero-width stripped
        XCTAssertEqual(TextNormalizer.normalize("x\u{0007}y", options: opts), "xy")             // control char stripped
    }

    func testNormalizeAggressive() {
        let opts = NormalizeOptions.aggressive
        let input = "\u{201C}Smart\u{201D} \u{2014} quotes&hellip; <b>bold</b>   spaces!!!!"
        let out = TextNormalizer.normalize(input, options: opts)
        // NFKC decomposes U+2026 ellipsis to three dots; punctuation collapse keeps them
        XCTAssertEqual(out, "\"Smart\" - quotes... bold spaces!")
    }

    func testNFKCNormalization() {
        var opts = NormalizeOptions()
        opts.unicodeForm = .nfkc
        XCTAssertEqual(TextNormalizer.normalize("ﬁle", options: opts), "file")    // ligature fi
        XCTAssertEqual(TextNormalizer.normalize("①", options: opts), "1")
    }

    func testHTMLStripping() {
        let html = """
        <html><head><title>T</title><style>body{color:red}</style></head>
        <body><script>alert(1)</script><h1>Header</h1><p>Para one.</p><p>Para &amp; two.</p>
        <!-- comment --><div>End</div></body></html>
        """
        let stripped = HTMLCleaner.stripTags(html)
        XCTAssertFalse(stripped.contains("alert"))
        XCTAssertFalse(stripped.contains("color:red"))
        XCTAssertFalse(stripped.contains("<"))
        XCTAssertTrue(stripped.contains("Header"))
        XCTAssertTrue(stripped.contains("Para one."))
        let decoded = HTMLCleaner.decodeEntities(stripped)
        XCTAssertTrue(decoded.contains("Para & two."))
    }

    func testEntityDecoding() {
        XCTAssertEqual(HTMLCleaner.decodeEntities("&lt;a&gt; &amp; &#65; &#x42; &nbsp;x"), "<a> & A B \u{00A0}x")
        XCTAssertEqual(HTMLCleaner.decodeEntities("no entities & here"), "no entities & here")
    }

    // MARK: - Dedupe

    func testExactDedupe() {
        let ds = Dataset.fresh(columns: ["text"], rows: [
            [.string("hello world")],
            [.string("different")],
            [.string("hello world")],
            [.string("hello world")]
        ])
        let r = Dedupe.exact(ds, columns: ["text"])
        XCTAssertEqual(r.keptIDs, [0, 1])
        XCTAssertEqual(r.droppedIDs, [2, 3])
        XCTAssertEqual(r.clusters.count, 1)
        XCTAssertEqual(r.clusters[0], [0, 2, 3])
    }

    func testNearDuplicateDedupe() {
        let base = "The quick brown fox jumps over the lazy dog near the quiet river bank while birds sing softly in the morning light of early spring"
        let nearDup = base + " today"   // tiny edit
        let distinct = "Completely unrelated content about database indexing strategies and query optimization techniques for large scale distributed storage systems in production"
        let ds = Dataset.fresh(columns: ["text"], rows: [
            [.string(base)], [.string(nearDup)], [.string(distinct)]
        ])
        let r = Dedupe.nearDuplicates(ds, column: "text", config: .init(threshold: 0.7))
        XCTAssertEqual(Set(r.keptIDs), Set([0, 2]))
        XCTAssertEqual(r.droppedIDs, [1])
    }

    func testNearDupKeepsDistinctRows() {
        let rows = (0..<50).map { i in
            [Value.string("Unique document number \(i) discussing topic \(i * 7) with completely specific content about subject \(i * 13) and detail \(i * 31) plus extra \(i)")]
        }
        let ds = Dataset.fresh(columns: ["text"], rows: rows)
        let r = Dedupe.nearDuplicates(ds, column: "text", config: .init(threshold: 0.8))
        XCTAssertEqual(r.droppedIDs.count, 0)
    }

    func testSimHash() {
        let a = Dedupe.simHash("the quick brown fox jumps over the lazy dog")
        let b = Dedupe.simHash("the quick brown fox jumps over the lazy cat")
        let c = Dedupe.simHash("totally different text about quantum physics")
        XCTAssertLessThan(Dedupe.hammingDistance(a, b), Dedupe.hammingDistance(a, c))
    }

    // MARK: - Tokenizer

    func testBPETokenizerLoadsAndMatchesKnownCounts() throws {
        guard let tok = BPETokenizer.shared else {
            XCTFail("Bundled cl100k vocab failed to load")
            return
        }
        // Known cl100k encodings
        XCTAssertEqual(tok.encode("hello world"), [15339, 1917])
        XCTAssertEqual(tok.encode("Hello, world!"), [9906, 11, 1917, 0])
        XCTAssertEqual(tok.countTokens("hello world"), 2)
        XCTAssertEqual(tok.encode(""), [])
        // Multibyte / emoji safety
        XCTAssertGreaterThan(tok.countTokens("café über naïve 日本語 🚀"), 0)
        // Count == encode.count always
        let s = "The 3 quick brown foxes jumped!\n\nNew paragraph with numbers 12345."
        XCTAssertEqual(tok.countTokens(s), tok.encode(s).count)
    }

    func testEstimatorTokenizerSane() {
        let est = EstimatorTokenizer()
        let text = "The quick brown fox jumps over the lazy dog."
        let n = est.countTokens(text)
        XCTAssertGreaterThan(n, 4)
        XCTAssertLessThan(n, 20)
    }

    // MARK: - Chunker

    func testChunkerRespectsBudgetAndSentences() {
        let sentence = "This is a reasonably long sentence that contains around fifteen tokens or so in total."
        let text = Array(repeating: sentence, count: 40).joined(separator: " ")
        var config = ChunkerConfig()
        config.targetTokens = 100
        config.overlapTokens = 20
        config.respectMarkdown = false
        let chunks = Chunker.chunk(text, config: config)
        XCTAssertGreaterThan(chunks.count, 3)
        for c in chunks {
            XCTAssertLessThanOrEqual(c.tokenCount, 140)   // budget + slack for overlap merge
            // never cut mid-sentence: every chunk ends with terminal punctuation
            XCTAssertTrue(c.text.hasSuffix("."), "chunk should end at sentence boundary: …\(c.text.suffix(20))")
        }
    }

    func testChunkerOverlap() {
        let sentences = (1...30).map { "Sentence number \($0) has some words in it." }
        var config = ChunkerConfig()
        config.targetTokens = 80
        config.overlapTokens = 25
        config.respectMarkdown = false
        let chunks = Chunker.chunk(sentences.joined(separator: " "), config: config)
        guard chunks.count >= 2 else { return XCTFail("expected multiple chunks") }
        // Overlap: last sentence of chunk N appears in chunk N+1
        let firstChunkLastSentence = Chunker.splitSentences(chunks[0].text).last!
        XCTAssertTrue(chunks[1].text.contains(firstChunkLastSentence))
    }

    func testChunkerMarkdownHeadingContext() {
        let md = """
        # Guide
        Intro text here with several words to avoid the min-chunk merge.

        ## Install
        Run the installer and follow the steps carefully to completion.
        """
        var config = ChunkerConfig()
        config.targetTokens = 512
        config.minChunkTokens = 2
        let chunks = Chunker.chunk(md, config: config)
        XCTAssertTrue(chunks.contains { $0.headingPath == "Guide" })
        XCTAssertTrue(chunks.contains { $0.headingPath == "Guide > Install" })
        XCTAssertTrue(chunks.first { $0.headingPath == "Guide > Install" }!.text.hasPrefix("[Guide > Install]"))
    }

    func testSentenceSplitterGuards() {
        let text = "Dr. Smith went to Washington. He arrived at 3.14 p.m. sharp. Great!"
        let sentences = Chunker.splitSentences(text)
        XCTAssertEqual(sentences.count, 3)
        XCTAssertTrue(sentences[0].hasPrefix("Dr. Smith"))
    }

    func testChunkerGiantSentence() {
        let giant = Array(repeating: "word", count: 3000).joined(separator: " ")
        var config = ChunkerConfig()
        config.targetTokens = 100
        config.respectMarkdown = false
        let chunks = Chunker.chunk(giant, config: config)
        XCTAssertGreaterThan(chunks.count, 10)
        for c in chunks { XCTAssertLessThanOrEqual(c.tokenCount, 130) }
    }

    // MARK: - Quality

    func testQualityFilterPassesGoodText() {
        let good = "The distillation process requires careful temperature control. Operators monitor the vessel throughout the procedure, adjusting heat as needed."
        XCTAssertTrue(QualityFilter.evaluate(good).passed)
    }

    func testQualityFilterCatchesJunk() {
        XCTAssertFalse(QualityFilter.evaluate("").passed)
        XCTAssertFalse(QualityFilter.evaluate("a b").passed)                                       // too few words
        XCTAssertFalse(QualityFilter.evaluate("$$$ ### @@@ %%% &&& *** ((( ))) !!!").passed)       // symbols
        XCTAssertFalse(QualityFilter.evaluate("THIS IS ALL CAPS SHOUTING TEXT THAT GOES ON AND ON FOREVER AND EVER LOUDLY").passed)
        let repeated = Array(repeating: "buy now click here", count: 20).joined(separator: " ")
        XCTAssertFalse(QualityFilter.evaluate(repeated).passed)                                    // bigram bloat
        let dupLines = Array(repeating: "same line here", count: 10).joined(separator: "\n")
        XCTAssertFalse(QualityFilter.evaluate(dupLines).passed)                                    // dup lines
        let truncated = "This sentence was going quite well until it suddenly ends with the"
        XCTAssertFalse(QualityFilter.evaluate(truncated).passed)                                   // dangler
    }

    // MARK: - PII

    func testPIIEmail() {
        let (out, counts) = PIIDetector.redact("Contact alice@example.com or bob.smith+tag@sub.domain.org today.")
        XCTAssertEqual(counts[.email], 2)
        XCTAssertFalse(out.contains("@"))
        XCTAssertTrue(out.contains("[EMAIL]"))
    }

    func testPIICreditCardLuhn() {
        // 4532015112830366 passes Luhn; 4532015112830367 fails
        let (_, hit) = PIIDetector.redact("Card: 4532 0151 1283 0366 thanks")
        XCTAssertEqual(hit[.creditCard], 1)
        let (_, miss) = PIIDetector.redact("Ref: 4532 0151 1283 0367 thanks")
        XCTAssertNil(miss[.creditCard])
    }

    func testPIIIBAN() {
        // Valid German IBAN test number
        let (_, hit) = PIIDetector.redact("Pay to DE89370400440532013000 please")
        XCTAssertEqual(hit[.iban], 1)
        let (_, miss) = PIIDetector.redact("Code DE00000000000000000001 is not an IBAN")
        XCTAssertNil(miss[.iban])
    }

    func testPIIAPIKeys() {
        let text = "key=sk-ant-abc123def456ghi789jkl012mno345 and AKIAIOSFODNN7EXAMPLE and ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let matches = PIIDetector.detect(text, kinds: [.apiKey])
        XCTAssertEqual(matches.count, 3)
    }

    func testPIIPhoneAndFalsePositives() {
        let (_, hit) = PIIDetector.redact("Call +49 89 1234 5678 now", kinds: [.phone])
        XCTAssertEqual(hit[.phone], 1)
        // Years, plain integers, versions should NOT match
        let (_, miss) = PIIDetector.redact("In 2024 we shipped version 1.2.3 with 10000 users", kinds: [.phone])
        XCTAssertNil(miss[.phone])
    }

    func testPIIIPAddress() {
        let (_, counts) = PIIDetector.redact("Server at 192.168.1.100 and localhost 127.0.0.1", kinds: [.ipAddress])
        XCTAssertEqual(counts[.ipAddress], 1)   // localhost excluded
    }

    func testPIIHashModeStable() {
        let (a, _) = PIIDetector.redact("mail: x@y.com", mode: .hash)
        let (b, _) = PIIDetector.redact("mail: x@y.com", mode: .hash)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.contains("[EMAIL:"))
    }

    func testPIISSN() {
        let (_, hit) = PIIDetector.redact("SSN 123-45-6789 on file", kinds: [.ssn])
        XCTAssertEqual(hit[.ssn], 1)
        let (_, miss) = PIIDetector.redact("SSN 000-45-6789 invalid", kinds: [.ssn])
        XCTAssertNil(miss[.ssn])
    }

    // MARK: - Decontamination

    func testDecontamination() {
        let evalSet = ["What is the capital of France? The capital of France is Paris, a major European city."]
        let index = Decontaminator.EvalIndex(evalTexts: evalSet, nGramSize: 8)
        let ds = Dataset.fresh(columns: ["text"], rows: [
            [.string("Unrelated training row about cooking pasta with fresh tomatoes and basil leaves in summer")],
            [.string("Quiz answer: the capital of France is Paris, a major European city with rich history")]
        ])
        let hits = Decontaminator.screen(ds, column: "text", against: index)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].recordID, 1)
    }

    // MARK: - Expression language

    func testExpressionArithmeticAndLogic() throws {
        let cols = ["a", "b", "name"]
        let vals: [Value] = [.int(10), .double(2.5), .string("Alice")]
        func eval(_ s: String) throws -> Value {
            try ExpressionEvaluator.evaluate(ExpressionParser.parse(s), columns: cols, values: vals)
        }
        XCTAssertEqual(try eval("a + 5"), .int(15))
        XCTAssertEqual(try eval("a * b"), .double(25.0))
        XCTAssertEqual(try eval("a > 5 and b < 3"), .bool(true))
        XCTAssertEqual(try eval("a > 5 or 1 == 2"), .bool(true))
        XCTAssertEqual(try eval("not (a == 10)"), .bool(false))
        XCTAssertEqual(try eval("-a"), .int(-10))
        XCTAssertEqual(try eval("a % 3"), .int(1))
        XCTAssertEqual(try eval("a / 0"), .null)
    }

    func testExpressionStringFunctions() throws {
        let cols = ["name", "text"]
        let vals: [Value] = [.string("Alice"), .string("  Hello World  ")]
        func eval(_ s: String) throws -> Value {
            try ExpressionEvaluator.evaluate(ExpressionParser.parse(s), columns: cols, values: vals)
        }
        XCTAssertEqual(try eval("len(name)"), .int(5))
        XCTAssertEqual(try eval("lower(name)"), .string("alice"))
        XCTAssertEqual(try eval("trim(text)"), .string("Hello World"))
        XCTAssertEqual(try eval("contains(name, 'lic')"), .bool(true))
        XCTAssertEqual(try eval("starts_with(name, 'Al')"), .bool(true))
        XCTAssertEqual(try eval("replace(name, 'A', 'E')"), .string("Elice"))
        XCTAssertEqual(try eval("substr(name, 1, 3)"), .string("lic"))
        XCTAssertEqual(try eval("name + \" x\""), .string("Alice x"))
        XCTAssertEqual(try eval("coalesce(null, name)"), .string("Alice"))
        XCTAssertEqual(try eval("if(len(name) > 3, 'long', 'short')"), .string("long"))
        XCTAssertEqual(try eval("words(trim(text))"), .int(2))
        XCTAssertEqual(try eval("col(\"name\")"), .string("Alice"))
        XCTAssertEqual(try eval("is_null(null)"), .bool(true))
    }

    func testExpressionErrors() {
        XCTAssertThrowsError(try ExpressionParser.parse("1 +"))
        XCTAssertThrowsError(try ExpressionParser.parse("'unterminated"))
        XCTAssertThrowsError(try ExpressionParser.parse("foo(1"))
        XCTAssertThrowsError(try ExpressionEvaluator.evaluate(
            ExpressionParser.parse("nosuchcol > 1"), columns: ["a"], values: [.int(1)]))
        XCTAssertThrowsError(try ExpressionEvaluator.evaluate(
            ExpressionParser.parse("nosuchfn(1)"), columns: ["a"], values: [.int(1)]))
    }
}
