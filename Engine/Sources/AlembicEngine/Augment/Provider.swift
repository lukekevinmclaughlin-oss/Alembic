import Foundation

/// Provider-agnostic LLM access for the optional augmentation nodes.
/// The deterministic core NEVER requires this — users bring their own key and
/// provider, and any OpenAI-compatible endpoint (local llama.cpp, Ollama,
/// gateways) works via `openaiCompatible`.
public struct ProviderConfig: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case demo
        case anthropic
        case openai
        case openaiCompatible
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .demo: return "Demo mode (no API key needed)"
            case .anthropic: return "Anthropic"
            case .openai: return "OpenAI"
            case .openaiCompatible: return "OpenAI-compatible (custom endpoint)"
            }
        }

        /// Whether this provider talks to a remote endpoint that needs credentials.
        public var requiresAPIKey: Bool { self != .demo }
    }

    public var kind: Kind
    public var model: String
    public var baseURL: String        // used by openaiCompatible; ignored otherwise
    public var temperature: Double

    /// Fresh installs start on the on-device demo provider so every augmentation
    /// node is runnable before any account or key exists. Saved configurations
    /// are decoded as-is and keep whatever provider the user chose.
    public init(kind: Kind = .demo, model: String = "", baseURL: String = "", temperature: Double = 0.3) {
        self.kind = kind
        self.model = model
        self.baseURL = baseURL
        self.temperature = temperature
    }
}

public protocol LLMClient: Sendable {
    var providerName: String { get }
    func complete(system: String?, user: String, maxTokens: Int) async throws -> String
}

/// Build a client from config + key. The API key lives only in memory / the
/// user's Keychain — it is never serialized into recipes or project files.
public enum LLMClientFactory {
    public static func make(config: ProviderConfig, apiKey: String) -> any LLMClient {
        switch config.kind {
        case .demo:
            return DemoLLMClient()
        case .anthropic:
            return AnthropicClient(apiKey: apiKey, model: config.model, temperature: config.temperature)
        case .openai:
            return OpenAIChatClient(apiKey: apiKey, model: config.model,
                                    baseURL: "https://api.openai.com/v1", temperature: config.temperature)
        case .openaiCompatible:
            let base = config.baseURL.isEmpty ? "http://localhost:11434/v1" : config.baseURL
            return OpenAIChatClient(apiKey: apiKey, model: config.model,
                                    baseURL: base, temperature: config.temperature)
        }
    }
}

// MARK: - Demo (on-device, no key, no network)

/// Fully offline demonstration provider.
///
/// It makes no network calls and needs no credentials. For each augmentation
/// node it synthesizes a deterministic, well-formed response in exactly the
/// shape `Augmentor.parseResponse` expects, so the whole pipeline — including
/// the LLM steps — can be exercised end to end without a provider account.
/// Output is derived from the input text, so it is stable across runs and
/// re-runs reproduce byte-identical results like the rest of the engine.
public struct DemoLLMClient: LLMClient {
    public let providerName = "demo"

    public init() {}

    public func complete(system: String?, user: String, maxTokens: Int) async throws -> String {
        // A small pause so batching, progress reporting, and cancellation
        // behave the same way they do against a real endpoint.
        try? await Task.sleep(nanoseconds: 30_000_000)
        if Task.isCancelled { throw AlembicError.providerError("cancelled") }

        let system = system ?? ""
        let text = user.trimmingCharacters(in: .whitespacesAndNewlines)

        // Match on the response contract each system prompt asks for.
        if system.contains("\"question\"") { return Self.generateQA(text) }
        if system.contains("\"score\"") { return Self.judgeScore(text) }
        if system.contains("\"label\"") { return Self.classify(text, system: system) }
        if system.contains("rewritten text only") { return Self.rewrite(text) }
        if system.contains("worse response only") { return Self.preferencePair(text) }
        // Connection test and anything else.
        return "ready"
    }

    // MARK: Task synthesis

    static func generateQA(_ text: String) -> String {
        let sentences = Self.sentences(text)
        let subject = Self.subject(text)
        let question = sentences.isEmpty
            ? "What does this passage describe?"
            : "What does this passage explain about \(subject)?"
        let answer = sentences.prefix(2).joined(separator: " ")
        return Self.json(["question": question,
                          "answer": answer.isEmpty ? text : answer])
    }

    static func judgeScore(_ text: String) -> String {
        // Deterministic, defensible heuristic rather than an arbitrary constant:
        // reward length, sentence structure, and lexical variety.
        let words = text.split(whereSeparator: { $0.isWhitespace })
        let unique = Set(words.map { $0.lowercased() }).count
        let variety = words.isEmpty ? 0.0 : Double(unique) / Double(words.count)
        let sentenceCount = Self.sentences(text).count

        var score = 4
        if words.count >= 12 { score += 1 }
        if words.count >= 40 { score += 1 }
        if sentenceCount >= 2 { score += 1 }
        if variety >= 0.6 { score += 1 }
        if text.contains(where: { $0.isNumber }) { score += 1 }
        score = min(10, max(1, score))

        let rationale = "\(words.count) words across \(sentenceCount) sentence(s), "
            + "lexical variety \(String(format: "%.2f", variety)) — "
            + (score >= 7 ? "coherent and informative enough for training data."
                          : "usable but thin; consider filtering or enriching.")
        return Self.json(["score": score, "rationale": rationale])
    }

    static func classify(_ text: String, system: String) -> String {
        let labels = Self.labels(inSystemPrompt: system)
        guard !labels.isEmpty else {
            return Self.json(["label": Self.subject(text)])
        }
        // Prefer a label whose word actually occurs in the text; otherwise fall
        // back to a stable hash so the same row always lands on the same label.
        let lower = text.lowercased()
        if let hit = labels.first(where: { lower.contains($0.lowercased()) }) {
            return Self.json(["label": hit])
        }
        let idx = Int(Self.stableHash(text) % UInt64(labels.count))
        return Self.json(["label": labels[idx]])
    }

    static func rewrite(_ text: String) -> String {
        // Genuine, meaning-preserving normalization — the same class of work the
        // instruction asks a model to do.
        var t = text
        let artifacts = ["â€™": "’", "â€œ": "“", "â€\u{9D}": "”", "â€“": "–",
                         "â€”": "—", "Â ": " ", "\u{FEFF}": ""]
        for (bad, good) in artifacts { t = t.replacingOccurrences(of: bad, with: good) }
        t = t.replacingOccurrences(of: "\r\n", with: "\n")
        t = t.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " +([,.;:!?])", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func preferencePair(_ text: String) -> String {
        // A deliberately weaker, vaguer answer — on topic but less useful.
        let first = Self.sentences(text).first ?? String(text.prefix(120))
        let clipped = first.count > 90 ? String(first.prefix(90)) + "…" : first
        return "Basically, \(Self.lowerFirst(clipped)) That's pretty much all there is to it."
    }

    // MARK: Helpers

    static func sentences(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0 + "." }
    }

    /// A short topical phrase pulled from the longest meaningful words.
    static func subject(_ text: String) -> String {
        let stop: Set<String> = ["the", "and", "that", "this", "with", "from", "have",
                                 "which", "there", "their", "about", "would", "these",
                                 "other", "into", "than", "then", "them", "were", "been"]
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count > 3 && !stop.contains($0) }
        guard !words.isEmpty else { return "this topic" }
        var counts: [String: Int] = [:]
        for w in words { counts[w, default: 0] += 1 }
        // Sort by frequency, then alphabetically, so the result is deterministic.
        let top = counts.sorted { a, b in
            a.value != b.value ? a.value > b.value : a.key < b.key
        }.prefix(2).map(\.key)
        return top.joined(separator: " and ")
    }

    static func labels(inSystemPrompt system: String) -> [String] {
        guard let range = system.range(of: "exactly one of: ") else { return [] }
        let tail = system[range.upperBound...]
        let listEnd = tail.range(of: ". Respond") ?? tail.range(of: ".\n")
        let list = listEnd.map { String(tail[..<$0.lowerBound]) } ?? String(tail)
        let parts = list.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // The prompt substitutes prose when the user configured no labels.
        if parts.count == 1 && parts[0].contains(" ") && parts[0].hasSuffix("labels") { return [] }
        return parts
    }

    static func lowerFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return String(f).lowercased() + String(s.dropFirst())
    }

    /// FNV-1a. Swift's `hashValue` is per-process seeded, which would break
    /// reproducibility across runs.
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }
}

// MARK: - Anthropic

public struct AnthropicClient: LLMClient {
    public let providerName = "anthropic"
    let apiKey: String
    let model: String
    let temperature: Double

    public init(apiKey: String, model: String, temperature: Double = 0.3) {
        self.apiKey = apiKey
        self.model = model.isEmpty ? "claude-haiku-4-5-20251001" : model
        self.temperature = temperature
    }

    public func complete(system: String?, user: String, maxTokens: Int) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "messages": [["role": "user", "content": user]]
        ]
        if let system { body["system"] = system }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.checkHTTP(response, data: data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw AlembicError.providerError("Anthropic: unexpected response shape")
        }
        return content.compactMap { $0["text"] as? String }.joined()
    }

    static func checkHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw AlembicError.providerError("HTTP \(http.statusCode): \(body)")
        }
    }
}

// MARK: - OpenAI / OpenAI-compatible

public struct OpenAIChatClient: LLMClient {
    public let providerName = "openai-chat"
    let apiKey: String
    let model: String
    let baseURL: String
    let temperature: Double

    public init(apiKey: String, model: String, baseURL: String, temperature: Double = 0.3) {
        self.apiKey = apiKey
        self.model = model.isEmpty ? "gpt-4o-mini" : model
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.temperature = temperature
    }

    public func complete(system: String?, user: String, maxTokens: Int) async throws -> String {
        var messages: [[String: String]] = []
        if let system { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": user])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "messages": messages
        ]
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw AlembicError.providerError("Invalid base URL: \(baseURL)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: req)
        try AnthropicClient.checkHTTP(response, data: data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AlembicError.providerError("Chat endpoint: unexpected response shape")
        }
        return content
    }
}

// MARK: - Retry wrapper

public struct RetryingClient: LLMClient {
    public let providerName: String
    let inner: any LLMClient
    let maxAttempts: Int

    public init(_ inner: any LLMClient, maxAttempts: Int = 4) {
        self.inner = inner
        self.providerName = inner.providerName
        self.maxAttempts = maxAttempts
    }

    public func complete(system: String?, user: String, maxTokens: Int) async throws -> String {
        var lastError: Error = AlembicError.providerError("no attempts made")
        for attempt in 0..<maxAttempts {
            do {
                return try await inner.complete(system: system, user: user, maxTokens: maxTokens)
            } catch {
                lastError = error
                // Don't retry auth/shape failures — only transient-looking ones
                let msg = "\(error)"
                let transient = msg.contains("429") || msg.contains("500") || msg.contains("502")
                    || msg.contains("503") || msg.contains("529") || msg.contains("timed out")
                    || msg.contains("network connection")
                if !transient { throw error }
                let delay = UInt64(pow(2.0, Double(attempt)) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        throw lastError
    }
}
