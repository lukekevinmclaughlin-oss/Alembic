import SwiftUI
import AlembicEngine
import UniformTypeIdentifiers

/// Parameter editor for a single pipeline step. One @State blob covering every
/// op kind, initialized from the op, rebuilt on save — simple and exhaustive.
struct OpEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let op: Op
    let onSave: (Op) -> Void

    // Shared
    @State private var columnsSel: Set<String> = []
    @State private var column = ""
    @State private var text1 = ""
    @State private var text2 = ""
    // Normalize
    @State private var norm = NormalizeOptions.standard
    // Dedupe
    @State private var threshold = 0.85
    // Type
    @State private var coerceTo = TypeInference.ColumnType.string
    // PII
    @State private var piiKinds: Set<PIIKind> = Set(PIIKind.allCases)
    @State private var piiMode = RedactionMode.tag
    // Quality
    @State private var rules = QualityRules.standard
    // Language
    @State private var langs: Set<String> = ["en"]
    @State private var minConfidence = 0.3
    // Decontaminate
    @State private var evalTexts: [String] = []
    @State private var nGramSize = 8
    @State private var showEvalImporter = false
    // Chunker
    @State private var chunkCfg = ChunkerConfig()
    // Split
    @State private var trainFrac = 0.9
    @State private var valFrac = 0.05
    @State private var testFrac = 0.05
    @State private var seed: UInt64 = 42
    @State private var stratify = ""
    // Augment
    @State private var augKind = AugmentKind.generateQA
    @State private var augInstruction = ""
    @State private var augLabels = ""
    @State private var augConcurrency = 4
    @State private var augMaxTokens = 1024
    // Expression validation
    @State private var exprError: String?

    // "und" = undetermined (keeps rows the detector can't classify, e.g. code)
    let commonLangs = ["en", "de", "fr", "es", "it", "pt", "nl", "sv", "pl", "tr", "zh", "ja", "ko", "ru", "ar", "hi", "und"]

    var body: some View {
        NavigationStack {
            Form {
                editorBody
            }
            .formStyle(.grouped)
            .navigationTitle(op.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let newOp = buildOp() {
                            onSave(newOp)
                            dismiss()
                        }
                    }
                    .disabled(exprError != nil)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .preferredColorScheme(.dark)
        .onAppear { load() }
        .fileImporter(isPresented: $showEvalImporter,
                      allowedContentTypes: [.plainText, .json, .data]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    let decoded = EncodingDetector.decode(data).text
                    evalTexts.append(decoded)
                }
            }
        }
    }

    // MARK: - Per-kind forms

    @ViewBuilder
    var editorBody: some View {
        switch op {
        case .selectColumns, .dropColumns:
            Section("Columns") { columnToggles }

        case .renameColumn:
            Section {
                Picker("Column", selection: $column) { columnOptions }
                TextField("New name", text: $text1)
            }

        case .addColumn:
            Section {
                TextField("Column name", text: $text1)
                expressionField
            } footer: { expressionHelp }

        case .filterRows:
            Section {
                expressionField
            } footer: { expressionHelp }

        case .normalizeText:
            Section("Apply to") { columnToggles }
            Section("Unicode") {
                Picker("Normalization form", selection: $norm.unicodeForm) {
                    Text("None").tag(NormalizeOptions.UnicodeForm.none)
                    Text("NFC (canonical)").tag(NormalizeOptions.UnicodeForm.nfc)
                    Text("NFKC (compatibility)").tag(NormalizeOptions.UnicodeForm.nfkc)
                }
            }
            Section("Cleanup") {
                Toggle("Trim whitespace", isOn: $norm.trimWhitespace)
                Toggle("Collapse inner whitespace", isOn: $norm.collapseInnerWhitespace)
                Toggle("Strip control characters", isOn: $norm.stripControlCharacters)
                Toggle("Strip zero-width characters", isOn: $norm.stripZeroWidth)
                Toggle("Normalize newlines", isOn: $norm.normalizeNewlines)
                Toggle("Straighten smart quotes", isOn: $norm.canonicalizeQuotes)
                Toggle("Canonicalize dashes", isOn: $norm.canonicalizeDashes)
                Toggle("Collapse repeated punctuation", isOn: $norm.collapseRepeatedPunctuation)
                Toggle("Lowercase", isOn: $norm.lowercase)
            }
            Section("HTML") {
                Toggle("Strip HTML tags", isOn: $norm.stripHTMLTags)
                Toggle("Decode HTML entities", isOn: $norm.decodeHTMLEntities)
            }

        case .unifyNulls:
            Section("Apply to") { columnToggles }
            Section {
                Text("Treats \(Array(TypeInference.nullSentinels.sorted().prefix(9)).joined(separator: ", "))… as null")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .autoType:
            Section {
                Text("Each column whose values are ≥95% consistently parseable becomes int, double, bool, or date. No configuration needed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .coerceType:
            Section {
                Picker("Column", selection: $column) { columnOptions }
                Picker("Type", selection: $coerceTo) {
                    ForEach(TypeInference.ColumnType.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
            }

        case .dedupeExact:
            Section("Key columns (none = all)") { columnToggles }

        case .dedupeFuzzy:
            Section {
                Picker("Text column", selection: $column) { columnOptions }
                VStack(alignment: .leading) {
                    Text("Similarity threshold: \(String(format: "%.2f", threshold))")
                    Slider(value: $threshold, in: 0.5...0.99, step: 0.01)
                }
            } footer: {
                Text("Rows with word-shingle Jaccard similarity above the threshold are clustered; the first of each cluster is kept.")
            }

        case .redactPII:
            Section("Apply to") { columnToggles }
            Section("Detect") {
                ForEach(PIIKind.allCases, id: \.self) { kind in
                    Toggle(kind.rawValue, isOn: Binding(
                        get: { piiKinds.contains(kind) },
                        set: { on in if on { piiKinds.insert(kind) } else { piiKinds.remove(kind) } }))
                }
            }
            Section("Redaction") {
                Picker("Mode", selection: $piiMode) {
                    Text("Tag — [EMAIL]").tag(RedactionMode.tag)
                    Text("Hash — [EMAIL:a1b2c3d4]").tag(RedactionMode.hash)
                    Text("Remove entirely").tag(RedactionMode.remove)
                }
            }

        case .qualityFilter:
            Section {
                Picker("Text column", selection: $column) { columnOptions }
            }
            Section("Length") {
                Stepper("Min words: \(rules.minWords)", value: $rules.minWords, in: 0...100)
                HStack {
                    Text("Max words")
                    Spacer()
                    TextField("", value: $rules.maxWords, format: .number)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                }
            }
            Section("Ratios") {
                ratioSlider("Max symbol ratio", $rules.maxSymbolRatio)
                ratioSlider("Max digit ratio", $rules.maxDigitRatio)
                ratioSlider("Max uppercase ratio", $rules.maxUppercaseRatio)
                ratioSlider("Min alphabetic ratio", $rules.minAlphaRatio)
            }
            Section("Repetition") {
                ratioSlider("Max duplicate-line ratio", $rules.maxDuplicateLineRatio)
                ratioSlider("Max top-bigram share", $rules.maxTopBigramRatio)
            }
            Section("Endings") {
                Toggle("Require terminal punctuation", isOn: $rules.requireTerminalPunctuation)
                Toggle("Drop truncated endings", isOn: $rules.flagTruncated)
            }

        case .languageFilter:
            Section {
                Picker("Text column", selection: $column) { columnOptions }
                VStack(alignment: .leading) {
                    Text("Min confidence: \(String(format: "%.2f", minConfidence))")
                    Slider(value: $minConfidence, in: 0...1, step: 0.05)
                }
            }
            Section("Keep languages") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 6) {
                    ForEach(commonLangs, id: \.self) { code in
                        Button {
                            if langs.contains(code) { langs.remove(code) } else { langs.insert(code) }
                        } label: {
                            Text(code)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(langs.contains(code) ? Theme.deepTeal : Color.gray.opacity(0.2)))
                                .foregroundStyle(langs.contains(code) ? .white : .secondary)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

        case .decontaminate:
            Section {
                Picker("Text column", selection: $column) { columnOptions }
                Stepper("N-gram size: \(nGramSize) words", value: $nGramSize, in: 4...20)
            }
            Section {
                Button {
                    showEvalImporter = true
                } label: {
                    Label("Add eval file…", systemImage: "plus.circle")
                }
                ForEach(Array(evalTexts.enumerated()), id: \.offset) { i, t in
                    HStack {
                        Text(String(t.prefix(60)) + (t.count > 60 ? "…" : ""))
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Button(role: .destructive) {
                            evalTexts.remove(at: i)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Eval / benchmark documents (\(evalTexts.count))")
            } footer: {
                Text("Training rows sharing any \(nGramSize)-word span with these documents are dropped — prevents benchmark leakage.")
            }

        case .addTokenCount, .addLanguage, .addQualityScore:
            Section {
                Picker("Text column", selection: $column) { columnOptions }
            }

        case .chunkText:
            Section {
                Picker("Text column", selection: $column) { columnOptions }
            }
            Section("Budget") {
                Stepper("Target: \(chunkCfg.targetTokens) tokens", value: $chunkCfg.targetTokens, in: 64...8192, step: 64)
                Stepper("Overlap: \(chunkCfg.overlapTokens) tokens", value: $chunkCfg.overlapTokens, in: 0...512, step: 8)
                Stepper("Min chunk: \(chunkCfg.minChunkTokens) tokens", value: $chunkCfg.minChunkTokens, in: 0...256, step: 8)
            }
            Section("Structure") {
                Toggle("Respect Markdown headings", isOn: $chunkCfg.respectMarkdown)
                Toggle("Prefix heading breadcrumb", isOn: $chunkCfg.includeHeadingContext)
            }

        case .split:
            Section("Fractions") {
                fracStepper("Train", $trainFrac)
                fracStepper("Validation", $valFrac)
                fracStepper("Test", $testFrac)
                if abs(trainFrac + valFrac + testFrac - 1.0) > 0.001 {
                    Label("Fractions sum to \(String(format: "%.2f", trainFrac + valFrac + testFrac)) — should be 1.00",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                }
            }
            Section {
                HStack {
                    Text("Seed")
                    Spacer()
                    TextField("", value: $seed, format: .number)
                        .frame(width: 120)
                        .multilineTextAlignment(.trailing)
                }
                Picker("Stratify by", selection: $stratify) {
                    Text("None").tag("")
                    ForEach(model.columns, id: \.self) { Text($0).tag($0) }
                }
            }

        case .augment(let cfg):
            Section {
                Picker("Kind", selection: $augKind) {
                    ForEach(AugmentKind.allCases) { k in
                        Text(k.displayName).tag(k)
                    }
                }
                Picker("Source column", selection: $column) { columnOptions }
            }
            Section("Guidance (optional)") {
                TextField("Extra instructions folded into the prompt", text: $augInstruction, axis: .vertical)
                    .lineLimit(2...4)
                if augKind == .classify {
                    TextField("Labels (comma-separated)", text: $augLabels)
                }
            }
            Section("Execution") {
                Stepper("Concurrency: \(augConcurrency)", value: $augConcurrency, in: 1...16)
                Stepper("Max output tokens: \(augMaxTokens)", value: $augMaxTokens, in: 128...8192, step: 128)
            }
            Section {
                costEstimate(cfg)
            } header: {
                Text("Cost estimate")
            } footer: {
                Text("LLM steps are skipped in the live preview and run only on the full pipeline run. Configure your provider and key in Settings. Interrupted runs resume — rows already augmented are skipped.")
            }
        }
    }

    // MARK: - Shared controls

    var columnToggles: some View {
        ForEach(model.columns, id: \.self) { col in
            Toggle(col, isOn: Binding(
                get: { columnsSel.contains(col) },
                set: { on in if on { columnsSel.insert(col) } else { columnsSel.remove(col) } }))
        }
    }

    @ViewBuilder
    var columnOptions: some View {
        ForEach(model.columns, id: \.self) { Text($0).tag($0) }
        if !model.columns.contains(column) && !column.isEmpty {
            Text(column).tag(column)
        }
    }

    var expressionField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Expression", text: $text2, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...3)
                .onChange(of: text2) { _, new in
                    do {
                        _ = try ExpressionParser.parse(new)
                        exprError = nil
                    } catch {
                        exprError = error.localizedDescription
                    }
                }
            if let exprError {
                Text(exprError)
                    .font(.caption2)
                    .foregroundStyle(Theme.danger)
            }
        }
    }

    var expressionHelp: some View {
        Text("Columns by name; functions: len, lower, upper, trim, contains, replace, substr, tokens, words, lang, coalesce, if, col(\"name with spaces\"). Operators: + - * / % == != < > and or not.")
    }

    func ratioSlider(_ label: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            Text("\(label): \(String(format: "%.2f", value.wrappedValue))")
            Slider(value: value, in: 0...1, step: 0.05)
        }
    }

    func fracStepper(_ label: String, _ value: Binding<Double>) -> some View {
        Stepper("\(label): \(Int(value.wrappedValue * 100))%",
                value: value, in: 0...1, step: 0.05)
    }

    @ViewBuilder
    func costEstimate(_ cfg: AugmentConfig) -> some View {
        if let est = model.augmentEstimate(AugmentConfig(kind: augKind, column: column, maxTokens: augMaxTokens)) {
            let cost = Double(est.input) / 1e6 * model.priceInputPerMTok
                + Double(est.output) / 1e6 * model.priceOutputPerMTok
            VStack(alignment: .leading, spacing: 4) {
                Text("~\(est.calls.formatted()) calls · ~\(est.input.formatted()) tokens in · ~\(est.output.formatted()) max out")
                    .font(.caption)
                Text("≈ $\(String(format: "%.2f", cost)) at your configured prices")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.amber)
            }
        } else {
            Text("Import data to estimate").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Load & build

    func load() {
        switch op {
        case .selectColumns(let c), .dropColumns(let c), .dedupeExact(let c):
            columnsSel = Set(c)
        case .renameColumn(let f, let t):
            column = f; text1 = t
        case .addColumn(let n, let e):
            text1 = n; text2 = e
        case .filterRows(let e):
            text2 = e
        case .normalizeText(let c, let o):
            columnsSel = Set(c); norm = o
        case .unifyNulls(let c):
            columnsSel = Set(c)
        case .autoType:
            break
        case .coerceType(let c, let t):
            column = c; coerceTo = t
        case .dedupeFuzzy(let c, let t):
            column = c; threshold = t
        case .redactPII(let c, let k, let m):
            columnsSel = Set(c)
            piiKinds = k.isEmpty ? Set(PIIKind.allCases) : Set(k)
            piiMode = m
        case .qualityFilter(let c, let r):
            column = c; rules = r
        case .languageFilter(let c, let l, let conf):
            column = c; langs = Set(l); minConfidence = conf
        case .decontaminate(let c, let e, let n):
            column = c; evalTexts = e; nGramSize = n
        case .addTokenCount(let c), .addLanguage(let c), .addQualityScore(let c):
            column = c
        case .chunkText(let c, let cfg):
            column = c; chunkCfg = cfg
        case .split(let tr, let v, let te, let s, let strat):
            trainFrac = tr; valFrac = v; testFrac = te; seed = s; stratify = strat ?? ""
        case .augment(let cfg):
            augKind = cfg.kind
            column = cfg.column
            augInstruction = cfg.instruction
            augLabels = cfg.labels.joined(separator: ", ")
            augConcurrency = cfg.concurrency
            augMaxTokens = cfg.maxTokens
        }
    }

    func buildOp() -> Op? {
        switch op {
        case .selectColumns: return .selectColumns(columns: orderedSelection())
        case .dropColumns: return .dropColumns(columns: orderedSelection())
        case .renameColumn: return .renameColumn(from: column, to: text1)
        case .addColumn: return .addColumn(name: text1.isEmpty ? "computed" : text1, expression: text2)
        case .filterRows: return .filterRows(expression: text2)
        case .normalizeText: return .normalizeText(columns: orderedSelection(), options: norm)
        case .unifyNulls: return .unifyNulls(columns: orderedSelection())
        case .autoType: return .autoType
        case .coerceType: return .coerceType(column: column, type: coerceTo)
        case .dedupeExact: return .dedupeExact(columns: orderedSelection())
        case .dedupeFuzzy: return .dedupeFuzzy(column: column, threshold: threshold)
        case .redactPII:
            let kinds = piiKinds.count == PIIKind.allCases.count ? [] : PIIKind.allCases.filter { piiKinds.contains($0) }
            return .redactPII(columns: orderedSelection(), kinds: kinds, mode: piiMode)
        case .qualityFilter: return .qualityFilter(column: column, rules: rules)
        case .languageFilter: return .languageFilter(column: column, allowed: commonLangs.filter { langs.contains($0) }, minConfidence: minConfidence)
        case .decontaminate: return .decontaminate(column: column, evalTexts: evalTexts, nGramSize: nGramSize)
        case .addTokenCount: return .addTokenCount(column: column)
        case .addLanguage: return .addLanguage(column: column)
        case .addQualityScore: return .addQualityScore(column: column)
        case .chunkText: return .chunkText(column: column, config: chunkCfg)
        case .split: return .split(train: trainFrac, validation: valFrac, test: testFrac,
                                   seed: seed, stratifyBy: stratify.isEmpty ? nil : stratify)
        case .augment:
            let labels = augLabels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return .augment(config: AugmentConfig(kind: augKind, column: column,
                                                  instruction: augInstruction, labels: labels,
                                                  concurrency: augConcurrency, maxTokens: augMaxTokens))
        }
    }

    /// Preserve dataset column order in multi-select ops.
    func orderedSelection() -> [String] {
        model.columns.filter { columnsSel.contains($0) }
    }
}
