import XCTest
@testable import AlembicEngine

final class PipelineTests: XCTestCase {

    func makeMessyDataset() -> Dataset {
        Dataset.fresh(columns: ["text", "score", "when"], rows: [
            [.string("  The distillation process requires careful temperature control throughout. "), .string("5"), .string("2024-01-15")],
            [.string("The distillation process requires careful temperature control throughout."), .string("5"), .string("2024-01-15")],  // dup after trim
            [.string("Contact me at alice@example.com for details about the experiment results."), .string("N/A"), .string("15.01.2024")],
            [.string("$$$ ### @@@ %%%"), .string("1"), .string("2024-02-01")],
            [.string("Ce texte est écrit en français pour tester le filtre de langue dans le pipeline."), .string("3"), .string("2024-03-01")]
        ])
    }

    // MARK: - Recipe round-trip

    func testRecipeCodableRoundTrip() throws {
        var norm = NormalizeOptions.aggressive
        norm.lowercase = true
        // Whole-second date: ISO8601 recipe encoding drops sub-second precision
        let recipe = Recipe(name: "Test", createdAt: Date(timeIntervalSince1970: 1_752_000_000), ops: [
            .normalizeText(columns: ["text"], options: norm),
            .unifyNulls(columns: []),
            .autoType,
            .dedupeExact(columns: ["text"]),
            .dedupeFuzzy(column: "text", threshold: 0.85),
            .redactPII(columns: ["text"], kinds: [.email, .apiKey], mode: .hash),
            .qualityFilter(column: "text", rules: .standard),
            .languageFilter(column: "text", allowed: ["en"], minConfidence: 0.3),
            .decontaminate(column: "text", evalTexts: ["eval one"], nGramSize: 8),
            .addTokenCount(column: "text"),
            .chunkText(column: "text", config: ChunkerConfig()),
            .split(train: 0.8, validation: 0.1, test: 0.1, seed: 7, stratifyBy: nil),
            .addColumn(name: "wc", expression: "words(text)"),
            .filterRows(expression: "wc > 2"),
            .augment(config: AugmentConfig(kind: .judgeScore, column: "text"))
        ])
        let data = try recipe.encoded()
        let decoded = try Recipe.decode(data)
        XCTAssertEqual(decoded, recipe)
        XCTAssertEqual(decoded.ops.count, 15)
    }

    func testRecipeVersionGuard() throws {
        var recipe = Recipe(name: "Future")
        recipe.version = 999
        let data = try recipe.encoded()
        XCTAssertThrowsError(try Recipe.decode(data))
    }

    // MARK: - Executor end-to-end

    func testFullPipelineRun() async throws {
        let ds = makeMessyDataset()
        let ops: [Op] = [
            .normalizeText(columns: ["text"], options: .standard),
            .unifyNulls(columns: []),
            .autoType,
            .dedupeExact(columns: ["text"]),
            .redactPII(columns: ["text"], kinds: [.email], mode: .tag),
            .qualityFilter(column: "text", rules: .standard),
            .languageFilter(column: "text", allowed: ["en"], minConfidence: 0.2),
            .addTokenCount(column: "text")
        ]
        let result = try await PipelineExecutor.run(ds, ops: ops)
        let out = result.dataset

        // 5 rows → trim-dedup removes 1, junk removes 1, French removes 1 ⇒ 2 left
        XCTAssertEqual(out.rowCount, 2)
        // Email got redacted
        let texts = out.columnValues("text").map(\.display)
        XCTAssertTrue(texts.contains { $0.contains("[EMAIL]") })
        XCTAssertFalse(texts.contains { $0.contains("alice@example.com") })
        // autoType coerced score to int and when to date
        XCTAssertEqual(out.value(row: 0, column: "score").typeName, "int")
        XCTAssertEqual(out.value(row: 0, column: "when").typeName, "date")
        // token_count column added with positive ints
        XCTAssertTrue(out.columns.contains("token_count"))
        for v in out.columnValues("token_count") {
            guard case .int(let n) = v else { return XCTFail("expected int token count") }
            XCTAssertGreaterThan(n, 0)
        }
        // Metrics chain is consistent
        XCTAssertEqual(result.metrics.count, ops.count)
        XCTAssertEqual(result.metrics[0].rowsIn, 5)
        for i in 1..<result.metrics.count {
            XCTAssertEqual(result.metrics[i].rowsIn, result.metrics[i - 1].rowsOut)
        }
    }

    func testStructuralOps() async throws {
        let ds = Dataset.fresh(columns: ["a", "b", "c"], rows: [
            [.int(1), .string("x"), .double(1.5)],
            [.int(2), .string("y"), .double(2.5)]
        ])
        var (out, _) = try await PipelineExecutor.apply(.renameColumn(from: "b", to: "label"), to: ds)
        XCTAssertEqual(out.columns, ["a", "label", "c"])
        (out, _) = try await PipelineExecutor.apply(.dropColumns(columns: ["c"]), to: out)
        XCTAssertEqual(out.columns, ["a", "label"])
        (out, _) = try await PipelineExecutor.apply(.addColumn(name: "doubled", expression: "a * 2"), to: out)
        XCTAssertEqual(out.value(row: 1, column: "doubled"), .int(4))
        (out, _) = try await PipelineExecutor.apply(.filterRows(expression: "a > 1"), to: out)
        XCTAssertEqual(out.rowCount, 1)
        (out, _) = try await PipelineExecutor.apply(.selectColumns(columns: ["label"]), to: out)
        XCTAssertEqual(out.columns, ["label"])
    }

    func testChunkOpExplodesRows() async throws {
        let long = (1...60).map { "Sentence number \($0) contains a handful of words." }.joined(separator: " ")
        let ds = Dataset.fresh(columns: ["text", "source"], rows: [[.string(long), .string("doc.md")]])
        var config = ChunkerConfig()
        config.targetTokens = 100
        config.overlapTokens = 10
        let (out, m) = try await PipelineExecutor.apply(.chunkText(column: "text", config: config), to: ds)
        XCTAssertGreaterThan(out.rowCount, 2)
        XCTAssertTrue(out.columns.contains("chunk_index"))
        XCTAssertTrue(out.columns.contains("chunk_tokens"))
        // Source metadata carried through to every chunk
        for v in out.columnValues("source") { XCTAssertEqual(v, .string("doc.md")) }
        XCTAssertEqual(m.rowsIn, 1)
        XCTAssertEqual(m.rowsOut, out.rowCount)
    }

    func testSplitDeterministic() async throws {
        let rows = (0..<100).map { [Value.string("row \($0) content")] }
        let ds = Dataset.fresh(columns: ["text"], rows: rows)
        let op = Op.split(train: 0.8, validation: 0.1, test: 0.1, seed: 42, stratifyBy: nil)
        let (a, _) = try await PipelineExecutor.apply(op, to: ds)
        let (b, _) = try await PipelineExecutor.apply(op, to: ds)
        XCTAssertEqual(a.columnValues("split"), b.columnValues("split"))
        let splits = a.columnValues("split").map(\.display)
        XCTAssertEqual(splits.filter { $0 == "train" }.count, 80)
        XCTAssertEqual(splits.filter { $0 == "validation" }.count, 10)
        XCTAssertEqual(splits.filter { $0 == "test" }.count, 10)
    }

    func testDecontaminateOp() async throws {
        let ds = Dataset.fresh(columns: ["text"], rows: [
            [.string("Training row about cooking pasta with fresh tomatoes and basil leaves in summer heat")],
            [.string("The mitochondria is the powerhouse of the cell as everyone knows from school biology")]
        ])
        let op = Op.decontaminate(column: "text",
                                  evalTexts: ["Remember: the mitochondria is the powerhouse of the cell as everyone knows well"],
                                  nGramSize: 8)
        let (out, m) = try await PipelineExecutor.apply(op, to: ds)
        XCTAssertEqual(out.rowCount, 1)
        XCTAssertEqual(m.notes["contaminated"], "1")
    }

    // MARK: - Shaping

    func testShapeAlpaca() {
        let ds = Dataset.fresh(columns: ["question", "answer"], rows: [
            [.string("What is 2+2?"), .string("4")],
            [.null, .string("orphan answer")]   // missing instruction → quarantined
        ])
        let mapping = FieldMapping.autoMap(schema: .alpaca, columns: ds.columns)
        XCTAssertEqual(mapping.map["instruction"], "question")
        XCTAssertEqual(mapping.map["output"], "answer")
        let result = SchemaShaper.shape(ds, schema: .alpaca, mapping: mapping)
        XCTAssertEqual(result.validCount, 1)
        XCTAssertEqual(result.quarantined.count, 1)
        XCTAssertTrue(result.jsonl.contains("\"instruction\":\"What is 2+2?\""))
    }

    func testShapeOpenAIAndAnthropic() throws {
        let ds = Dataset.fresh(columns: ["system", "user", "assistant"], rows: [
            [.string("Be brief."), .string("Hi"), .string("Hello!")]
        ])
        let mapping = FieldMapping(["system": "system", "user": "user", "assistant": "assistant"])

        let oai = SchemaShaper.shape(ds, schema: .openaiMessages, mapping: mapping)
        let line = try XCTUnwrap(oai.jsonl.split(separator: "\n").first)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let messages = try XCTUnwrap(obj["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user", "assistant"])

        let ant = SchemaShaper.shape(ds, schema: .anthropicTurns, mapping: mapping)
        let aline = try XCTUnwrap(ant.jsonl.split(separator: "\n").first)
        let aobj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(aline.utf8)) as? [String: Any])
        XCTAssertEqual(aobj["system"] as? String, "Be brief.")
        XCTAssertEqual((aobj["messages"] as? [[String: Any]])?.count, 2)
    }

    func testShapeChatML() {
        let ds = Dataset.fresh(columns: ["user", "assistant"], rows: [
            [.string("Q"), .string("A")]
        ])
        let result = SchemaShaper.shape(ds, schema: .chatml,
                                        mapping: FieldMapping(["user": "user", "assistant": "assistant"]))
        XCTAssertTrue(result.jsonl.contains("<|im_start|>user\\nQ<|im_end|>"))
    }

    func testShapeDPORejectsIdenticalPair() {
        let ds = Dataset.fresh(columns: ["prompt", "chosen", "rejected"], rows: [
            [.string("p"), .string("good"), .string("bad")],
            [.string("p2"), .string("same"), .string("same")]
        ])
        let result = SchemaShaper.shape(ds, schema: .dpo,
                                        mapping: FieldMapping(["prompt": "prompt", "chosen": "chosen", "rejected": "rejected"]))
        XCTAssertEqual(result.validCount, 1)
        XCTAssertEqual(result.quarantined.count, 1)
        XCTAssertTrue(result.quarantined[0].reason.contains("chosen == rejected"))
    }

    func testShapeRAGChunksCarriesMetadata() throws {
        let ds = Dataset.fresh(columns: ["text", "source", "extra_meta"], rows: [
            [.string("chunk body"), .string("doc.md"), .string("keepme")]
        ])
        let result = SchemaShaper.shape(ds, schema: .ragChunks,
                                        mapping: FieldMapping(["text": "text", "source": "source"]))
        let line = try XCTUnwrap(result.jsonl.split(separator: "\n").first)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let meta = try XCTUnwrap(obj["metadata"] as? [String: Any])
        XCTAssertEqual(meta["source"] as? String, "doc.md")
        XCTAssertEqual(meta["extra_meta"] as? String, "keepme")
    }

    // MARK: - Dataset card & diff

    func testDatasetCard() async throws {
        let ds = makeMessyDataset()
        let result = try await PipelineExecutor.run(ds, ops: [
            .normalizeText(columns: ["text"], options: .standard),
            .addTokenCount(column: "text")
        ])
        let card = DatasetCard.compute(dataset: result.dataset, metrics: result.metrics)
        XCTAssertEqual(card.rowCount, 5)
        XCTAssertTrue(card.columns.contains { $0.tokenStats != nil })
        XCTAssertFalse(card.languageMix.isEmpty)
        let md = card.markdown()
        XCTAssertTrue(md.contains("# Dataset Card"))
        XCTAssertTrue(md.contains("Pipeline provenance"))
        XCTAssertNoThrow(try card.json())
    }

    func testDatasetDiff() async throws {
        let before = makeMessyDataset()
        let result = try await PipelineExecutor.run(before, ops: [
            .normalizeText(columns: ["text"], options: .standard),   // trims row 0
            .dedupeExact(columns: ["text"]),                          // drops row 1
            .addTokenCount(column: "text")                            // new column
        ])
        let diff = DatasetDiff.diff(before: before, after: result.dataset)
        XCTAssertTrue(diff.droppedIDs.contains(1))
        XCTAssertTrue(diff.addedColumns.contains("token_count"))
        if case .modified(let cols)? = diff.rowChanges[0] {
            XCTAssertTrue(cols.contains("text"))
        } else {
            XCTFail("row 0 should be modified (trimmed)")
        }
        if case .unchanged? = diff.rowChanges[3] {} else {
            XCTFail("junk row unchanged by trim")
        }
    }

    // MARK: - Augmentation with mock client

    struct MockClient: LLMClient {
        let providerName = "mock"
        let response: @Sendable (String) -> String
        func complete(system: String?, user: String, maxTokens: Int) async throws -> String {
            response(user)
        }
    }

    func testAugmentGenerateQA() async throws {
        let ds = Dataset.fresh(columns: ["text"], rows: [
            [.string("The alembic was used in medieval alchemy for distillation.")],
            [.string("")]   // empty → skipped
        ])
        let client = MockClient { _ in
            "```json\n{\"question\": \"What was the alembic used for?\", \"answer\": \"Distillation in medieval alchemy.\"}\n```"
        }
        let config = AugmentConfig(kind: .generateQA, column: "text")
        let (out, stats) = try await Augmentor.run(config, dataset: ds, client: client)
        XCTAssertEqual(stats.processed, 1)
        XCTAssertTrue(out.columns.contains("gen_question"))
        XCTAssertEqual(out.value(row: 0, column: "gen_question"), .string("What was the alembic used for?"))
        XCTAssertEqual(out.value(row: 1, column: "gen_question"), .null)
    }

    func testAugmentJudgeScoreAndResume() async throws {
        let ds = Dataset.fresh(columns: ["text"], rows: [
            [.string("Some quality content here.")],
            [.string("Other content follows.")]
        ])
        let client = MockClient { _ in "{\"score\": 8, \"rationale\": \"coherent\"}" }
        let config = AugmentConfig(kind: .judgeScore, column: "text")
        let (out, stats) = try await Augmentor.run(config, dataset: ds, client: client)
        XCTAssertEqual(stats.processed, 2)
        XCTAssertEqual(out.value(row: 0, column: "judge_score"), .int(8))

        // Resume: re-running skips rows already scored
        let (_, stats2) = try await Augmentor.run(config, dataset: out, client: client)
        XCTAssertEqual(stats2.processed, 0)
        XCTAssertEqual(stats2.skipped, 2)
    }

    func testAugmentViaExecutorRequiresClient() async {
        let ds = Dataset.fresh(columns: ["text"], rows: [[.string("x")]])
        do {
            _ = try await PipelineExecutor.apply(.augment(config: .init(kind: .rewrite, column: "text")), to: ds)
            XCTFail("should throw without a client")
        } catch {
            XCTAssertTrue("\(error)".contains("provider"))
        }
    }

    func testAugmentCostEstimate() {
        let ds = Dataset.fresh(columns: ["text"], rows: (0..<10).map { [Value.string("Row \($0) with some content to estimate")] })
        let est = Augmentor.estimate(AugmentConfig(kind: .judgeScore, column: "text"), dataset: ds)
        XCTAssertEqual(est.calls, 10)
        XCTAssertGreaterThan(est.estimatedInputTokens, 100)
        let cost = est.cost(inputPerMTok: 3.0, outputPerMTok: 15.0)
        XCTAssertGreaterThan(cost, 0)
    }

    func testAugmentAbortsOnConsistentFailure() async throws {
        struct FailingClient: LLMClient {
            let providerName = "failing"
            func complete(system: String?, user: String, maxTokens: Int) async throws -> String {
                throw AlembicError.providerError("401 unauthorized")
            }
        }
        let ds = Dataset.fresh(columns: ["text"], rows: (0..<30).map { [Value.string("row \($0)")] })
        var config = AugmentConfig(kind: .rewrite, column: "text")
        config.concurrency = 5
        do {
            _ = try await Augmentor.run(config, dataset: ds, client: FailingClient())
            XCTFail("should abort early")
        } catch {
            XCTAssertTrue("\(error)".contains("check provider"))
        }
    }
}
