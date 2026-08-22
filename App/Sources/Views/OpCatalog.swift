import SwiftUI
import AlembicEngine

/// Categorized "add step" catalog. Templates are pre-filled with sensible
/// defaults; the editor opens immediately after adding for fine-tuning.
struct OpCatalogSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onAdd: (Op) -> Void
    @State private var query = ""

    struct Category: Identifiable {
        let id = UUID()
        let name: String
        let icon: String
        let items: [(String, String, Op)]   // title, detail, template
    }

    /// Categories filtered by the search query (matches title, detail, or category).
    var filteredCategories: [Category] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return categories }
        return categories.compactMap { cat in
            let matches = cat.items.filter {
                $0.0.lowercased().contains(q) || $0.1.lowercased().contains(q) || cat.name.lowercased().contains(q)
            }
            return matches.isEmpty ? nil : Category(name: cat.name, icon: cat.icon, items: matches)
        }
    }

    var categories: [Category] {
        let textCol = model.guessTextColumn(model.processedSample ?? model.sample ?? Dataset(columns: [])) ?? model.columns.first ?? "text"
        return [
            Category(name: "Clean", icon: "wand.and.stars", items: [
                ("Normalize text", "Unicode, whitespace, control chars, quotes, HTML", .normalizeText(columns: [], options: .standard)),
                ("Deep clean", "Aggressive: NFKC + HTML strip + entity decode + punctuation", .normalizeText(columns: [], options: .aggressive)),
                ("Unify nulls", "NA, N/A, -, null, none → real nulls", .unifyNulls(columns: [])),
                ("Auto-detect types", "Strings → int / double / bool / date where consistent", .autoType)
            ]),
            Category(name: "Structure", icon: "tablecells", items: [
                ("Filter rows", "Keep rows matching an expression", .filterRows(expression: "tokens(\(safeIdent(textCol))) > 10")),
                ("Add computed column", "New column from an expression", .addColumn(name: "word_count", expression: "words(\(safeIdent(textCol)))")),
                ("Select columns", "Keep only chosen columns", .selectColumns(columns: model.columns)),
                ("Drop columns", "Remove chosen columns", .dropColumns(columns: [])),
                ("Rename column", "Change a column name", .renameColumn(from: model.columns.first ?? "", to: "renamed")),
                ("Coerce type", "Force a column to a specific type", .coerceType(column: model.columns.first ?? "", type: .string))
            ]),
            Category(name: "Dedupe", icon: "doc.on.doc", items: [
                ("Exact duplicates", "Byte-identical rows (choose key columns)", .dedupeExact(columns: [])),
                ("Near-duplicates", "MinHash + Jaccard fuzzy matching", .dedupeFuzzy(column: textCol, threshold: 0.85))
            ]),
            Category(name: "LLM Quality", icon: "checkmark.seal", items: [
                ("Redact PII & secrets", "Emails, phones, cards, IBANs, API keys", .redactPII(columns: [], kinds: [], mode: .tag)),
                ("Quality filter", "C4/Gopher-style junk heuristics", .qualityFilter(column: textCol, rules: .standard)),
                ("Language filter", "Keep only chosen languages", .languageFilter(column: textCol, allowed: ["en"], minConfidence: 0.3)),
                ("Decontaminate", "Drop rows overlapping your eval/benchmark set", .decontaminate(column: textCol, evalTexts: [], nGramSize: 8))
            ]),
            Category(name: "Enrich", icon: "number", items: [
                ("Token count", "Real cl100k BPE count per row", .addTokenCount(column: textCol)),
                ("Language", "Detected language per row", .addLanguage(column: textCol)),
                ("Quality score", "0–1 heuristic quality per row", .addQualityScore(column: textCol))
            ]),
            Category(name: "RAG", icon: "scissors", items: [
                ("Chunk text", "Sentence-aware, token-budgeted splitting", .chunkText(column: textCol, config: ChunkerConfig()))
            ]),
            Category(name: "Training", icon: "chart.pie", items: [
                ("Train/val/test split", "Seeded, optionally stratified", .split(train: 0.9, validation: 0.05, test: 0.05, seed: 42, stratifyBy: nil))
            ]),
            Category(name: "LLM Augment (BYO key)", icon: "brain", items: [
                ("Generate Q&A pairs", "Synthesize instruction data from documents", .augment(config: .init(kind: .generateQA, column: textCol))),
                ("LLM-as-judge score", "Rate rows 1–10 for training quality", .augment(config: .init(kind: .judgeScore, column: textCol))),
                ("Rewrite / normalize", "Fix grammar & artifacts, preserve meaning", .augment(config: .init(kind: .rewrite, column: textCol))),
                ("Classify / label", "Topic or custom labels per row", .augment(config: .init(kind: .classify, column: textCol, labels: ["technical", "conversational", "other"]))),
                ("Synthesize DPO rejected", "Generate weaker responses for preference pairs", .augment(config: .init(kind: .preferencePair, column: textCol)))
            ])
        ]
    }

    func safeIdent(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && !s.isEmpty && !s.first!.isNumber
            ? s : "col(\"\(s)\")"
    }

    var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search steps — dedupe, tokens, redact…", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.glassEdge, lineWidth: 1))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    searchField
                    if filteredCategories.isEmpty {
                        ContentUnavailableView("No steps match", systemImage: "magnifyingglass",
                                               description: Text("Try a different search term."))
                            .padding(.top, 40)
                    }
                    ForEach(filteredCategories) { cat in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(cat.name, systemImage: cat.icon)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Theme.amber)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
                                ForEach(Array(cat.items.enumerated()), id: \.offset) { _, item in
                                    Button {
                                        onAdd(item.2)
                                    } label: {
                                        GlassCard(padding: 12) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(item.0).font(.callout.weight(.semibold))
                                                Text(item.1)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .multilineTextAlignment(.leading)
                                            }
                                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                                        }
                                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Add Step")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .preferredColorScheme(.dark)
    }
}
