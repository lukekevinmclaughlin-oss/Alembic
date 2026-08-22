import Foundation

/// Benchmark decontamination: flag training rows that share long n-gram spans
/// with a held-out eval set. Standard practice (GPT-3 used 13-gram overlap);
/// we default to 8 *word* n-grams which is comparably strict.
public enum Decontaminator {

    public struct Config: Codable, Sendable, Equatable {
        public var nGramSize = 8
        public var minMatches = 1     // n-gram hits needed to flag a row
        public init() {}
    }

    public struct ContaminationHit: Sendable, Equatable {
        public let recordID: Int
        public let matchCount: Int
    }

    /// Build the eval-set n-gram index once, then screen any number of rows.
    public struct EvalIndex: Sendable {
        let grams: Set<UInt64>
        public let nGramSize: Int
        public let sourceCount: Int

        public init(evalTexts: [String], nGramSize: Int = 8) {
            var set = Set<UInt64>()
            for text in evalTexts {
                for g in Decontaminator.nGrams(text, n: nGramSize) {
                    set.insert(g)
                }
            }
            self.grams = set
            self.nGramSize = nGramSize
            self.sourceCount = evalTexts.count
        }

        public func matchCount(_ text: String) -> Int {
            var count = 0
            for g in Decontaminator.nGrams(text, n: nGramSize) where grams.contains(g) {
                count += 1
            }
            return count
        }
    }

    public static func screen(_ dataset: Dataset, column: String,
                              against index: EvalIndex,
                              config: Config = Config()) -> [ContaminationHit] {
        guard let colIdx = dataset.columnIndex(of: column) else { return [] }
        var hits: [ContaminationHit] = []
        for record in dataset.records {
            guard colIdx < record.values.count else { continue }
            let text = record.values[colIdx].display
            let matches = index.matchCount(text)
            if matches >= config.minMatches {
                hits.append(ContaminationHit(recordID: record.id, matchCount: matches))
            }
        }
        return hits
    }

    /// Normalized word n-grams as stable hashes. Lowercased, punctuation-stripped
    /// so cosmetic differences don't hide contamination.
    static func nGrams(_ text: String, n: Int) -> [UInt64] {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard words.count >= n else { return [] }
        var out: [UInt64] = []
        out.reserveCapacity(words.count - n + 1)
        for i in 0...(words.count - n) {
            out.append(stableHash64(words[i..<(i + n)].joined(separator: " ")))
        }
        return out
    }
}
