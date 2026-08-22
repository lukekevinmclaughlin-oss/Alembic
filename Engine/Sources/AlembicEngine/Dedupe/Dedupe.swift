import Foundation

/// Exact + near-duplicate detection. Near-dup uses MinHash over word shingles
/// with LSH banding for candidate generation, then true Jaccard verification —
/// the standard recipe for training-corpus dedup, implemented deterministically.
public enum Dedupe {

    public struct DedupeResult: Sendable {
        public let keptIDs: [Int]           // record ids to keep, original order
        public let droppedIDs: [Int]        // record ids removed
        public let clusters: [[Int]]        // groups of near-identical record ids (first = kept)
    }

    // MARK: - Exact

    /// Exact dedup on the concatenation of the given columns (all columns if empty).
    public static func exact(_ dataset: Dataset, columns: [String] = []) -> DedupeResult {
        let idxs = columnIndices(dataset, columns: columns)
        var seen: [UInt64: Int] = [:]
        var kept: [Int] = []
        var dropped: [Int] = []
        var clusterMap: [Int: [Int]] = [:]

        for record in dataset.records {
            let key = idxs.map { $0 < record.values.count ? record.values[$0].display : "" }
                .joined(separator: "\u{1F}")
            let h = stableHash64(key)
            if let first = seen[h] {
                dropped.append(record.id)
                clusterMap[first, default: [first]].append(record.id)
            } else {
                seen[h] = record.id
                kept.append(record.id)
            }
        }
        return DedupeResult(keptIDs: kept, droppedIDs: dropped,
                            clusters: clusterMap.values.sorted { $0[0] < $1[0] })
    }

    // MARK: - MinHash near-dup

    public struct MinHashConfig: Sendable {
        public var numHashes = 128
        public var bands = 32                 // 32 bands × 4 rows ⇒ catches ~0.5+ similarity
        public var shingleSize = 3            // word 3-grams
        public var jaccardThreshold = 0.8
        public init() {}
        public init(threshold: Double) {
            self.init()
            jaccardThreshold = threshold
            // Tune banding to the threshold: s ≈ (1/b)^(1/r)
            if threshold >= 0.9 { bands = 16 }        // r=8 → knee ~0.71
            else if threshold >= 0.7 { bands = 32 }   // r=4 → knee ~0.42
            else { bands = 64 }                       // r=2 → knee ~0.12
        }
    }

    /// Near-duplicate dedup on one text column.
    public static func nearDuplicates(_ dataset: Dataset, column: String,
                                      config: MinHashConfig = MinHashConfig()) -> DedupeResult {
        guard let colIdx = dataset.columnIndex(of: column) else {
            return DedupeResult(keptIDs: dataset.records.map(\.id), droppedIDs: [], clusters: [])
        }
        let texts: [(id: Int, text: String)] = dataset.records.map {
            ($0.id, colIdx < $0.values.count ? $0.values[colIdx].display : "")
        }

        // Signatures
        let sigs = texts.map { minHashSignature(shingles(of: $0.text, size: config.shingleSize),
                                                numHashes: config.numHashes) }

        // LSH banding → candidate pairs
        let rowsPerBand = max(1, config.numHashes / config.bands)
        var buckets: [UInt64: [Int]] = [:]   // bucket hash → indices into texts
        var candidatePairs = Set<UInt64>()
        for band in 0..<config.bands {
            buckets.removeAll(keepingCapacity: true)
            let start = band * rowsPerBand
            let end = min(start + rowsPerBand, config.numHashes)
            guard start < end else { break }
            for (i, sig) in sigs.enumerated() {
                var h: UInt64 = 0xcbf29ce484222325 ^ UInt64(band)
                for k in start..<end {
                    h ^= sig[k]
                    h = h &* 0x100000001b3
                }
                buckets[h, default: []].append(i)
            }
            for (_, members) in buckets where members.count > 1 && members.count < 500 {
                for a in 0..<members.count {
                    for b in (a + 1)..<members.count {
                        candidatePairs.insert(UInt64(members[a]) << 32 | UInt64(members[b]))
                    }
                }
            }
        }

        // Verify with true Jaccard, union-find the confirmed pairs
        var parent = Array(0..<texts.count)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var c = x
            while parent[c] != r { let n = parent[c]; parent[c] = r; c = n }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        var shingleCache: [Int: Set<UInt64>] = [:]
        func shinglesFor(_ i: Int) -> Set<UInt64> {
            if let s = shingleCache[i] { return s }
            let s = shingles(of: texts[i].text, size: config.shingleSize)
            shingleCache[i] = s
            return s
        }

        for pair in candidatePairs.sorted() {
            let a = Int(pair >> 32), b = Int(pair & 0xFFFFFFFF)
            let sa = shinglesFor(a), sb = shinglesFor(b)
            guard !sa.isEmpty || !sb.isEmpty else { union(a, b); continue }
            let inter = sa.intersection(sb).count
            let uni = sa.union(sb).count
            if uni > 0 && Double(inter) / Double(uni) >= config.jaccardThreshold {
                union(a, b)
            }
        }

        // First member of each cluster (lowest original index) is kept
        var kept: [Int] = []
        var dropped: [Int] = []
        var clusterMap: [Int: [Int]] = [:]
        for i in 0..<texts.count {
            let root = find(i)
            if root == i {
                kept.append(texts[i].id)
            } else {
                dropped.append(texts[i].id)
            }
            clusterMap[root, default: []].append(texts[i].id)
        }
        let clusters = clusterMap.values.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }
        return DedupeResult(keptIDs: kept, droppedIDs: dropped, clusters: clusters)
    }

    /// Word shingles hashed to 64-bit. Falls back to character shingles for CJK
    /// or very short texts.
    public static func shingles(of text: String, size: Int) -> Set<UInt64> {
        let lowered = text.lowercased()
        let words = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        var out = Set<UInt64>()
        if words.count >= size {
            for i in 0...(words.count - size) {
                out.insert(stableHash64(words[i..<(i + size)].joined(separator: " ")))
            }
        } else if !words.isEmpty {
            out.insert(stableHash64(words.joined(separator: " ")))
        } else {
            // character 5-grams for scriptio continua
            let chars = Array(lowered.unicodeScalars.filter { $0.properties.isAlphabetic }.map { String($0) })
            let n = 5
            if chars.count >= n {
                for i in 0...(chars.count - n) {
                    out.insert(stableHash64(chars[i..<(i + n)].joined()))
                }
            } else if !chars.isEmpty {
                out.insert(stableHash64(chars.joined()))
            }
        }
        return out
    }

    /// MinHash signature via the "one hash, many mixes" trick: h_i(x) = mix(x, seed_i).
    static func minHashSignature(_ shingleSet: Set<UInt64>, numHashes: Int) -> [UInt64] {
        guard !shingleSet.isEmpty else { return Array(repeating: UInt64.max, count: numHashes) }
        var sig = [UInt64](repeating: .max, count: numHashes)
        for shingle in shingleSet {
            var rng = SeededRNG(seed: shingle)
            for i in 0..<numHashes {
                let v = rng.next()
                if v < sig[i] { sig[i] = v }
            }
        }
        return sig
    }

    // MARK: - SimHash (fast fingerprint, exposed for reporting/analysis)

    public static func simHash(_ text: String) -> UInt64 {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return 0 }
        var counts = [Int](repeating: 0, count: 64)
        for w in words {
            let h = stableHash64(w)
            for bit in 0..<64 {
                counts[bit] += (h >> UInt64(bit)) & 1 == 1 ? 1 : -1
            }
        }
        var out: UInt64 = 0
        for bit in 0..<64 where counts[bit] > 0 {
            out |= 1 << UInt64(bit)
        }
        return out
    }

    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    static func columnIndices(_ dataset: Dataset, columns: [String]) -> [Int] {
        if columns.isEmpty { return Array(0..<dataset.columns.count) }
        return columns.compactMap { dataset.columnIndex(of: $0) }
    }
}
