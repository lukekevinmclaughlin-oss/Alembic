import Foundation

/// Target training/inference schemas and exporters. Every export validates
/// each row against the schema; invalid rows are quarantined with reasons,
/// never silently dropped.
public enum TrainingSchema: String, Codable, Sendable, CaseIterable, Identifiable {
    case alpaca          // {"instruction", "input", "output"}
    case openaiMessages  // {"messages": [{"role","content"}...]}
    case anthropicTurns  // {"system", "messages": [{"role","content"}...]}
    case chatml          // rendered <|im_start|> text
    case dpo             // {"prompt", "chosen", "rejected"}
    case completion      // {"prompt", "completion"}
    case corpus          // {"text"} — continued pretraining
    case ragChunks       // {"id", "text", "metadata": {...}} — embedding-ready

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .alpaca: return "Instruction (Alpaca)"
        case .openaiMessages: return "Chat (OpenAI messages)"
        case .anthropicTurns: return "Chat (Anthropic)"
        case .chatml: return "ChatML (rendered)"
        case .dpo: return "Preference pairs (DPO)"
        case .completion: return "Prompt → Completion"
        case .corpus: return "Raw corpus (pretraining)"
        case .ragChunks: return "RAG chunks (embedding-ready)"
        }
    }

    /// Logical fields the user must map dataset columns onto. Optional fields
    /// are suffixed with "?" in this listing.
    public var fields: [SchemaField] {
        switch self {
        case .alpaca:
            return [SchemaField("instruction", required: true),
                    SchemaField("input", required: false),
                    SchemaField("output", required: true)]
        case .openaiMessages, .anthropicTurns, .chatml:
            return [SchemaField("system", required: false),
                    SchemaField("user", required: true),
                    SchemaField("assistant", required: true)]
        case .dpo:
            return [SchemaField("prompt", required: true),
                    SchemaField("chosen", required: true),
                    SchemaField("rejected", required: true)]
        case .completion:
            return [SchemaField("prompt", required: true),
                    SchemaField("completion", required: true)]
        case .corpus:
            return [SchemaField("text", required: true)]
        case .ragChunks:
            return [SchemaField("text", required: true),
                    SchemaField("source", required: false),
                    SchemaField("heading", required: false)]
        }
    }
}

public struct SchemaField: Sendable, Equatable, Identifiable {
    public let name: String
    public let required: Bool
    public var id: String { name }
    public init(_ name: String, required: Bool) {
        self.name = name
        self.required = required
    }
}

/// Column → schema-field mapping chosen by the user (or auto-guessed).
public struct FieldMapping: Codable, Sendable, Equatable {
    public var map: [String: String]   // schemaField → datasetColumn
    public init(_ map: [String: String] = [:]) { self.map = map }

    /// Heuristic auto-mapping by common column-name conventions.
    public static func autoMap(schema: TrainingSchema, columns: [String]) -> FieldMapping {
        let lowered = Dictionary(uniqueKeysWithValues: columns.map { ($0.lowercased(), $0) })
        var m: [String: String] = [:]
        let synonyms: [String: [String]] = [
            "instruction": ["instruction", "question", "prompt", "query", "task", "q"],
            "input": ["input", "context", "passage"],
            "output": ["output", "answer", "response", "completion", "a"],
            "system": ["system", "system_prompt"],
            "user": ["user", "question", "prompt", "instruction", "human", "q", "input"],
            "assistant": ["assistant", "answer", "response", "output", "completion", "a", "bot"],
            "prompt": ["prompt", "question", "instruction", "query", "input"],
            "chosen": ["chosen", "preferred", "good", "winner"],
            "rejected": ["rejected", "dispreferred", "bad", "loser"],
            "completion": ["completion", "output", "answer", "response", "text"],
            "text": ["text", "content", "body", "document", "passage"],
            "source": ["source", "file", "url", "origin", "doc"],
            "heading": ["heading", "title", "section", "heading_path"]
        ]
        for field in schema.fields {
            if let candidates = synonyms[field.name] {
                for c in candidates {
                    if let col = lowered[c] { m[field.name] = col; break }
                }
            }
        }
        return FieldMapping(m)
    }
}

public struct ShapeResult: Sendable {
    public let jsonl: String
    public let validCount: Int
    public let quarantined: [(recordID: Int, reason: String)]
}

public enum SchemaShaper {

    /// Shape a dataset into the target schema as validated JSONL.
    public static func shape(_ dataset: Dataset, schema: TrainingSchema,
                             mapping: FieldMapping) -> ShapeResult {
        var objects: [[String: Any]] = []
        var quarantined: [(Int, String)] = []

        func fieldValue(_ record: Record, _ field: String) -> String? {
            guard let col = mapping.map[field],
                  let idx = dataset.columnIndex(of: col),
                  idx < record.values.count else { return nil }
            let v = record.values[idx]
            return v.isNull ? nil : v.display
        }

        for record in dataset.records {
            // Required-field validation
            var missing: [String] = []
            for f in schema.fields where f.required {
                let v = fieldValue(record, f.name)
                if v == nil || v?.isEmpty == true { missing.append(f.name) }
            }
            guard missing.isEmpty else {
                quarantined.append((record.id, "missing: \(missing.joined(separator: ", "))"))
                continue
            }

            switch schema {
            case .alpaca:
                var obj: [String: Any] = [
                    "instruction": fieldValue(record, "instruction") ?? "",
                    "output": fieldValue(record, "output") ?? ""
                ]
                obj["input"] = fieldValue(record, "input") ?? ""
                objects.append(obj)

            case .openaiMessages:
                var messages: [[String: String]] = []
                if let sys = fieldValue(record, "system"), !sys.isEmpty {
                    messages.append(["role": "system", "content": sys])
                }
                messages.append(["role": "user", "content": fieldValue(record, "user") ?? ""])
                messages.append(["role": "assistant", "content": fieldValue(record, "assistant") ?? ""])
                objects.append(["messages": messages])

            case .anthropicTurns:
                var obj: [String: Any] = [:]
                if let sys = fieldValue(record, "system"), !sys.isEmpty { obj["system"] = sys }
                obj["messages"] = [
                    ["role": "user", "content": fieldValue(record, "user") ?? ""],
                    ["role": "assistant", "content": fieldValue(record, "assistant") ?? ""]
                ]
                objects.append(obj)

            case .chatml:
                var text = ""
                if let sys = fieldValue(record, "system"), !sys.isEmpty {
                    text += "<|im_start|>system\n\(sys)<|im_end|>\n"
                }
                text += "<|im_start|>user\n\(fieldValue(record, "user") ?? "")<|im_end|>\n"
                text += "<|im_start|>assistant\n\(fieldValue(record, "assistant") ?? "")<|im_end|>"
                objects.append(["text": text])

            case .dpo:
                let prompt = fieldValue(record, "prompt") ?? ""
                let chosen = fieldValue(record, "chosen") ?? ""
                let rejected = fieldValue(record, "rejected") ?? ""
                if chosen == rejected {
                    quarantined.append((record.id, "chosen == rejected"))
                    continue
                }
                objects.append(["prompt": prompt, "chosen": chosen, "rejected": rejected])

            case .completion:
                objects.append(["prompt": fieldValue(record, "prompt") ?? "",
                                "completion": fieldValue(record, "completion") ?? ""])

            case .corpus:
                objects.append(["text": fieldValue(record, "text") ?? ""])

            case .ragChunks:
                var meta: [String: Any] = [:]
                if let s = fieldValue(record, "source") { meta["source"] = s }
                if let h = fieldValue(record, "heading") { meta["heading"] = h }
                // Carry all unmapped columns into metadata
                let mappedCols = Set(mapping.map.values)
                for (i, col) in dataset.columns.enumerated()
                where !mappedCols.contains(col) && i < record.values.count && !record.values[i].isNull {
                    meta[col] = JSONLWriter.jsonObject(record.values[i])
                }
                objects.append(["id": record.id,
                                "text": fieldValue(record, "text") ?? "",
                                "metadata": meta])
            }
        }

        return ShapeResult(jsonl: JSONLWriter.writeObjects(objects),
                           validCount: objects.count,
                           quarantined: quarantined)
    }
}

/// Deterministic train/val/test splitting.
public enum DatasetSplitter {

    public struct Fractions: Codable, Sendable, Equatable {
        public var train: Double
        public var validation: Double
        public var test: Double
        public init(train: Double = 0.9, validation: Double = 0.05, test: Double = 0.05) {
            self.train = train
            self.validation = validation
            self.test = test
        }
    }

    /// Adds a "split" column with values train/validation/test. Seeded shuffle,
    /// optional stratification on a column (each stratum split proportionally).
    public static func split(_ dataset: Dataset, fractions: Fractions = Fractions(),
                             seed: UInt64 = 42, stratifyBy: String? = nil) -> Dataset {
        var assignment: [Int: String] = [:]   // record.id → split

        func assign(_ ids: [Int]) {
            var rng = SeededRNG(seed: seed &+ stableHash64(ids.map(String.init).joined(separator: ",")))
            var shuffled = ids
            shuffled.shuffle(using: &rng)
            let n = shuffled.count
            let trainEnd = Int((fractions.train * Double(n)).rounded())
            let valEnd = trainEnd + Int((fractions.validation * Double(n)).rounded())
            for (i, id) in shuffled.enumerated() {
                assignment[id] = i < trainEnd ? "train" : i < valEnd ? "validation" : "test"
            }
        }

        if let strat = stratifyBy, let idx = dataset.columnIndex(of: strat) {
            var groups: [String: [Int]] = [:]
            for r in dataset.records {
                let key = idx < r.values.count ? r.values[idx].display : ""
                groups[key, default: []].append(r.id)
            }
            for (_, ids) in groups.sorted(by: { $0.key < $1.key }) { assign(ids) }
        } else {
            assign(dataset.records.map(\.id))
        }

        var out = dataset
        out.columns.append("split")
        for i in 0..<out.records.count {
            out.records[i].values.append(.string(assignment[out.records[i].id] ?? "train"))
        }
        return out
    }
}
