import Foundation

/// Offline language identification: Unicode-script detection for script-distinct
/// languages, stopword-profile scoring for Latin-script languages.
/// Deterministic, dependency-free, tuned for "good enough to filter a corpus".
public enum LanguageID {

    public struct Detection: Sendable, Equatable {
        public let code: String        // ISO 639-1 ("en", "de", …) or "und"
        public let confidence: Double  // 0...1
    }

    static let stopwords: [String: Set<String>] = [
        "en": ["the", "and", "is", "of", "to", "in", "that", "it", "was", "for", "on", "are", "with", "as", "this", "be", "at", "have", "not", "you", "from", "they", "his", "her", "which", "will", "would", "there", "their", "what"],
        "de": ["der", "die", "das", "und", "ist", "von", "zu", "den", "mit", "nicht", "auf", "für", "ein", "eine", "im", "sich", "des", "dem", "auch", "werden", "aus", "bei", "wird", "sind", "einer", "über", "nach", "als", "wie", "oder"],
        "fr": ["le", "la", "les", "et", "est", "de", "des", "un", "une", "que", "qui", "dans", "pour", "sur", "pas", "avec", "au", "ce", "il", "elle", "sont", "mais", "nous", "vous", "par", "plus", "ou", "son", "aux", "être"],
        "es": ["el", "la", "los", "las", "y", "es", "de", "que", "en", "un", "una", "por", "con", "para", "del", "se", "no", "su", "al", "lo", "como", "más", "pero", "sus", "le", "ya", "o", "este", "ha", "son"],
        "it": ["il", "la", "le", "e", "è", "di", "che", "in", "un", "una", "per", "con", "del", "non", "si", "sono", "da", "come", "anche", "più", "ma", "nel", "alla", "gli", "dei", "questo", "essere", "della", "hanno", "al"],
        "pt": ["o", "a", "os", "as", "e", "é", "de", "que", "em", "um", "uma", "por", "com", "para", "do", "da", "não", "se", "no", "na", "mais", "como", "mas", "foi", "ao", "ele", "das", "dos", "sua", "seu"],
        "nl": ["de", "het", "een", "en", "is", "van", "in", "op", "dat", "die", "met", "voor", "niet", "aan", "er", "om", "ook", "als", "maar", "bij", "of", "uit", "naar", "dan", "worden", "wordt", "door", "over", "zijn", "deze"],
        "sv": ["och", "det", "att", "i", "en", "är", "som", "för", "på", "med", "av", "den", "till", "inte", "har", "de", "om", "ett", "man", "var", "vid", "kan", "från", "eller", "efter", "men", "sig", "så", "vi", "under"],
        "pl": ["i", "w", "z", "na", "do", "to", "że", "się", "nie", "jest", "o", "jak", "po", "co", "tak", "za", "od", "przez", "przy", "ale", "czy", "dla", "być", "był", "tym", "jego", "które", "który", "już", "tylko"],
        "tr": ["ve", "bir", "bu", "da", "de", "için", "ile", "olarak", "çok", "daha", "en", "gibi", "kadar", "sonra", "ama", "ancak", "olan", "olduğu", "her", "ne", "ise", "veya", "diğer", "bin", "yıl", "göre", "iki", "kendi", "aynı", "onun"]
    ]

    public static func detect(_ text: String) -> Detection {
        let sample = String(text.prefix(4000))
        guard !sample.isEmpty else { return Detection(code: "und", confidence: 0) }

        // 1. Script counting
        var han = 0, hiraganaKatakana = 0, hangul = 0, cyrillic = 0, arabic = 0
        var devanagari = 0, thai = 0, greek = 0, hebrew = 0, latin = 0, letters = 0
        for scalar in sample.unicodeScalars {
            guard scalar.properties.isAlphabetic else { continue }
            letters += 1
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
            case 0x3040...0x30FF: hiraganaKatakana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF: hangul += 1
            case 0x0400...0x04FF: cyrillic += 1
            case 0x0600...0x06FF, 0x0750...0x077F: arabic += 1
            case 0x0900...0x097F: devanagari += 1
            case 0x0E00...0x0E7F: thai += 1
            case 0x0370...0x03FF: greek += 1
            case 0x0590...0x05FF: hebrew += 1
            case 0x0041...0x024F: latin += 1
            default: break
            }
        }
        guard letters > 0 else { return Detection(code: "und", confidence: 0) }
        let l = Double(letters)

        func frac(_ n: Int) -> Double { Double(n) / l }
        if frac(hiraganaKatakana) > 0.1 { return Detection(code: "ja", confidence: min(1, frac(hiraganaKatakana + han) + 0.3)) }
        if frac(han) > 0.5 { return Detection(code: "zh", confidence: frac(han)) }
        if frac(hangul) > 0.5 { return Detection(code: "ko", confidence: frac(hangul)) }
        if frac(cyrillic) > 0.5 { return Detection(code: "ru", confidence: frac(cyrillic)) }
        if frac(arabic) > 0.5 { return Detection(code: "ar", confidence: frac(arabic)) }
        if frac(devanagari) > 0.5 { return Detection(code: "hi", confidence: frac(devanagari)) }
        if frac(thai) > 0.5 { return Detection(code: "th", confidence: frac(thai)) }
        if frac(greek) > 0.5 { return Detection(code: "el", confidence: frac(greek)) }
        if frac(hebrew) > 0.5 { return Detection(code: "he", confidence: frac(hebrew)) }

        // 2. Latin-script: stopword profile scoring
        guard frac(latin) > 0.5 else { return Detection(code: "und", confidence: 0.2) }
        let words = sample.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard words.count >= 3 else { return Detection(code: "und", confidence: 0.1) }

        var best = "und"
        var bestScore = 0.0
        var secondScore = 0.0
        for (lang, stops) in stopwords {
            let hits = words.reduce(0) { $1.count <= 12 && stops.contains($1) ? $0 + 1 : $0 }
            let score = Double(hits) / Double(words.count)
            if score > bestScore {
                secondScore = bestScore
                bestScore = score
                best = lang
            } else if score > secondScore {
                secondScore = score
            }
        }
        guard bestScore > 0.03 else { return Detection(code: "und", confidence: 0.1) }
        let margin = bestScore - secondScore
        let confidence = min(1.0, bestScore * 3 + margin * 2)
        return Detection(code: best, confidence: confidence)
    }
}
