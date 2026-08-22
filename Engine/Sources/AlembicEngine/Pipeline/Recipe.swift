import Foundation

/// A pipeline operation. The enum's synthesized Codable gives each case a keyed
/// representation ({"normalizeText": {...}}) — that IS the recipe format.
public enum Op: Codable, Sendable, Equatable {
    // Structure
    case selectColumns(columns: [String])
    case dropColumns(columns: [String])
    case renameColumn(from: String, to: String)
    case addColumn(name: String, expression: String)
    case filterRows(expression: String)
    // Cleaning
    case normalizeText(columns: [String], options: NormalizeOptions)
    case unifyNulls(columns: [String])
    case autoType
    case coerceType(column: String, type: TypeInference.ColumnType)
    // Dedup
    case dedupeExact(columns: [String])
    case dedupeFuzzy(column: String, threshold: Double)
    // LLM-specific quality
    case redactPII(columns: [String], kinds: [PIIKind], mode: RedactionMode)
    case qualityFilter(column: String, rules: QualityRules)
    case languageFilter(column: String, allowed: [String], minConfidence: Double)
    case decontaminate(column: String, evalTexts: [String], nGramSize: Int)
    // Enrichment
    case addTokenCount(column: String)
    case addLanguage(column: String)
    case addQualityScore(column: String)
    // RAG
    case chunkText(column: String, config: ChunkerConfig)
    // Training prep
    case split(train: Double, validation: Double, test: Double, seed: UInt64, stratifyBy: String?)
    // BYO-key augmentation
    case augment(config: AugmentConfig)

    /// Stable key used for recipe docs and UI identity of the op *type*.
    public var kindName: String {
        switch self {
        case .selectColumns: return "selectColumns"
        case .dropColumns: return "dropColumns"
        case .renameColumn: return "renameColumn"
        case .addColumn: return "addColumn"
        case .filterRows: return "filterRows"
        case .normalizeText: return "normalizeText"
        case .unifyNulls: return "unifyNulls"
        case .autoType: return "autoType"
        case .coerceType: return "coerceType"
        case .dedupeExact: return "dedupeExact"
        case .dedupeFuzzy: return "dedupeFuzzy"
        case .redactPII: return "redactPII"
        case .qualityFilter: return "qualityFilter"
        case .languageFilter: return "languageFilter"
        case .decontaminate: return "decontaminate"
        case .addTokenCount: return "addTokenCount"
        case .addLanguage: return "addLanguage"
        case .addQualityScore: return "addQualityScore"
        case .chunkText: return "chunkText"
        case .split: return "split"
        case .augment: return "augment"
        }
    }

    public var displayName: String {
        switch self {
        case .selectColumns: return "Select columns"
        case .dropColumns: return "Drop columns"
        case .renameColumn: return "Rename column"
        case .addColumn: return "Add computed column"
        case .filterRows: return "Filter rows"
        case .normalizeText: return "Normalize text"
        case .unifyNulls: return "Unify nulls"
        case .autoType: return "Auto-detect types"
        case .coerceType: return "Coerce type"
        case .dedupeExact: return "Dedupe (exact)"
        case .dedupeFuzzy: return "Dedupe (near-duplicate)"
        case .redactPII: return "Redact PII & secrets"
        case .qualityFilter: return "Quality filter"
        case .languageFilter: return "Language filter"
        case .decontaminate: return "Decontaminate vs eval set"
        case .addTokenCount: return "Add token count"
        case .addLanguage: return "Add language"
        case .addQualityScore: return "Add quality score"
        case .chunkText: return "Chunk for RAG"
        case .split: return "Train/val/test split"
        case .augment(let c): return "LLM: \(c.kind.displayName)"
        }
    }

    public var isAugmentation: Bool {
        if case .augment = self { return true }
        return false
    }
}

/// The saved, replayable pipeline. Pipeline == recipe == undo history.
public struct Recipe: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var name: String
    public var createdAt: Date
    public var ops: [Op]

    public init(name: String = "Untitled Recipe", createdAt: Date = Date(), ops: [Op] = []) {
        self.version = Self.currentVersion
        self.name = name
        self.createdAt = createdAt
        self.ops = ops
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Recipe {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let recipe = try decoder.decode(Recipe.self, from: data)
            guard recipe.version <= currentVersion else {
                throw AlembicError.invalidRecipe("Recipe version \(recipe.version) is newer than this app understands")
            }
            return recipe
        } catch let e as AlembicError {
            throw e
        } catch {
            throw AlembicError.invalidRecipe("\(error.localizedDescription)")
        }
    }
}
