import Foundation

/// Encoding detection + normalization. Everything downstream of this file is
/// guaranteed clean UTF-8 Swift String.
public enum EncodingDetector {

    public struct Result: Sendable {
        public let text: String
        public let detectedEncoding: String
        public let hadBOM: Bool
        public let mojibakeRepairs: Int
    }

    /// Decode raw bytes into text: BOM sniffing → strict UTF-8 → UTF-16 heuristic
    /// → windows-1252 fallback. Then run mojibake repair.
    public static func decode(_ data: Data) -> Result {
        var body = data
        var hadBOM = false
        var encodingName = "utf-8"
        var text: String?

        // BOM detection
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            body = data.subdata(in: 3..<data.count)
            hadBOM = true
            text = String(data: body, encoding: .utf8)
        } else if data.count >= 2, data[0] == 0xFF, data[1] == 0xFE {
            body = data.subdata(in: 2..<data.count)
            hadBOM = true
            encodingName = "utf-16le"
            text = String(data: body, encoding: .utf16LittleEndian)
        } else if data.count >= 2, data[0] == 0xFE, data[1] == 0xFF {
            body = data.subdata(in: 2..<data.count)
            hadBOM = true
            encodingName = "utf-16be"
            text = String(data: body, encoding: .utf16BigEndian)
        }

        if text == nil {
            // UTF-16 heuristics BEFORE UTF-8: NUL bytes are technically valid
            // UTF-8, so BOM-less UTF-16 would otherwise "succeed" as garbage.
            if looksLikeUTF16LE(body), let t = String(data: body, encoding: .utf16LittleEndian) {
                text = t
                encodingName = "utf-16le"
            } else if looksLikeUTF16BE(body), let t = String(data: body, encoding: .utf16BigEndian) {
                text = t
                encodingName = "utf-16be"
            } else if let t = String(data: body, encoding: .utf8) {
                text = t
                encodingName = "utf-8"
            } else if let t = String(data: body, encoding: .windowsCP1252) {
                text = t
                encodingName = "windows-1252"
            } else {
                text = String(data: body, encoding: .isoLatin1) ?? ""
                encodingName = "iso-8859-1"
            }
        }

        var out = text ?? ""
        var repairs = 0
        if mojibakeScore(out) > 0 {
            let (repaired, count) = repairMojibake(out)
            if count > 0 && mojibakeScore(repaired) < mojibakeScore(out) {
                out = repaired
                repairs = count
            }
        }
        // Strip any stray BOM chars that survived (e.g. mid-file from concatenated exports)
        if out.contains("\u{FEFF}") {
            out = out.replacingOccurrences(of: "\u{FEFF}", with: "")
        }
        return Result(text: out, detectedEncoding: encodingName, hadBOM: hadBOM, mojibakeRepairs: repairs)
    }

    /// Heuristic: lots of NUL bytes in odd positions ⇒ UTF-16LE ASCII-ish text.
    static func looksLikeUTF16LE(_ data: Data) -> Bool {
        nulFraction(data, parity: 1) > 0.7
    }

    static func looksLikeUTF16BE(_ data: Data) -> Bool {
        nulFraction(data, parity: 0) > 0.7
    }

    private static func nulFraction(_ data: Data, parity: Int) -> Double {
        guard data.count >= 8 else { return 0 }
        let sample = [UInt8](data.prefix(512))
        var zeros = 0, total = 0
        for (i, b) in sample.enumerated() where i % 2 == parity {
            total += 1
            if b == 0 { zeros += 1 }
        }
        return total > 0 ? Double(zeros) / Double(total) : 0
    }

    /// Count classic UTF-8-decoded-as-latin1 artifact sequences.
    static func mojibakeScore(_ s: String) -> Int {
        var score = 0
        // Common artifacts: Ã©, Ã¨, Ã¼, â€™, â€œ, â€, Â  (non-breaking space artifact)
        let artifacts = ["Ã©", "Ã¨", "Ã¼", "Ã¶", "Ã¤", "Ã±", "Ã§", "Ã ", "â€™", "â€œ", "â€\u{9D}", "â€“", "â€”", "â€¦", "Â«", "Â»", "Â°", "Ã‰"]
        for a in artifacts {
            var searchRange = s.startIndex..<s.endIndex
            while let r = s.range(of: a, range: searchRange) {
                score += 1
                searchRange = r.upperBound..<s.endIndex
                if score > 200 { return score }
            }
        }
        return score
    }

    /// Attempt latin1→utf8 round-trip repair: text that was UTF-8 but got decoded
    /// as windows-1252 can be re-encoded to windows-1252 bytes and re-decoded as UTF-8.
    static func repairMojibake(_ s: String) -> (String, Int) {
        guard let bytes = s.data(using: .windowsCP1252, allowLossyConversion: false),
              let repaired = String(data: bytes, encoding: .utf8) else {
            return (s, 0)
        }
        let before = mojibakeScore(s)
        let after = mojibakeScore(repaired)
        return after < before ? (repaired, before - after) : (s, 0)
    }
}
