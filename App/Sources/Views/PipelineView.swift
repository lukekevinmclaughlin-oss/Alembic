import SwiftUI
import AlembicEngine
import UniformTypeIdentifiers

struct PipelineView: View {
    @Environment(AppModel.self) private var model
    @State private var showCatalog = false
    @State private var editingStepID: UUID?
    @State private var showRecipeExporter = false
    @State private var showRecipeImporter = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if model.steps.isEmpty {
                emptyState
            } else {
                stepList
            }
        }
        .navigationTitle("Pipeline")
        .sheet(isPresented: $showCatalog) {
            OpCatalogSheet { op in
                let id = model.addOp(op)
                showCatalog = false
                editingStepID = id
            }
        }
        .sheet(item: $editingStepID) { id in
            if let step = model.step(id: id) {
                OpEditorSheet(op: step.op) { newOp in
                    model.replaceOp(id: id, with: newOp)
                }
            }
        }
        .fileExporter(isPresented: $showRecipeExporter,
                      document: RecipeDocument(data: (try? model.recipeData()) ?? Data()),
                      contentType: .json,
                      defaultFilename: "\(model.sourceName.isEmpty ? "alembic" : model.sourceName)-recipe") { _ in }
        .fileImporter(isPresented: $showRecipeImporter, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    model.loadRecipe(from: data)
                }
            }
        }
    }

    var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                showCatalog = true
            } label: {
                Label("Add Step", systemImage: "plus")
            }
            .buttonStyle(DistillButtonStyle())
            .keyboardShortcut("t", modifiers: .command)

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(DistillButtonStyle(prominent: false))
                .disabled(!model.canUndo)
                .help("Undo pipeline edit")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(DistillButtonStyle(prominent: false))
                .disabled(!model.canRedo)
                .help("Redo pipeline edit")

            Spacer()

            Menu {
                Section("Presets") {
                    ForEach(RecipePreset.allCases) { preset in
                        Button {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                                model.applyPreset(preset)
                            }
                        } label: {
                            Text(preset.title)
                            Text(preset.subtitle)
                        }
                    }
                }
                Divider()
                Button("Save Recipe…") { showRecipeExporter = true }
                Button("Load Recipe…") { showRecipeImporter = true }
            } label: {
                Label("Recipe", systemImage: "doc.badge.gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Recipe presets, save and load")
        }
        .padding(14)
        .background(.ultraThinMaterial)
    }

    var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No steps yet")
                .font(.title3.weight(.semibold))
            Text("Add distillation steps — each one shows its effect instantly on a sampled preview.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { showCatalog = true } label: {
                Label("Add First Step", systemImage: "plus")
            }
            .buttonStyle(DistillButtonStyle())
            Menu("Or start from a preset") {
                ForEach(RecipePreset.allCases) { preset in
                    Button(preset.title) {
                        withAnimation { model.applyPreset(preset) }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .padding(.top, 2)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    @ViewBuilder
    var costBanner: some View {
        if let est = model.augmentCostEstimate() {
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .foregroundStyle(Theme.distilledTeal)
                Text("This pipeline calls an LLM \(est.calls.formatted()) times")
                    .font(.caption)
                Spacer()
                Text("≈ $\(String(format: "%.2f", est.cost))")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(Theme.amber)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.glassEdge, lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    var stepList: some View {
        VStack(spacing: 0) {
            costBanner
            List {
                ForEach(Array(model.steps.enumerated()), id: \.element.id) { index, step in
                    OpRow(step: step,
                          number: index + 1,
                          metrics: model.stepMetrics[step.id],
                          isBroken: model.brokenStepID == step.id,
                          brokenMessage: model.brokenStepID == step.id ? model.previewError : nil,
                          showConnector: index < model.steps.count - 1)
                        .contentShape(Rectangle())
                        .onTapGesture { editingStepID = step.id }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .leading) {
                            Button {
                                model.toggleStep(id: step.id)
                            } label: {
                                Label(step.enabled ? "Disable" : "Enable",
                                      systemImage: step.enabled ? "pause" : "play")
                            }
                            .tint(step.enabled ? .orange : Theme.distilledTeal)
                        }
                        .contextMenu {
                            Button {
                                model.toggleStep(id: step.id)
                            } label: {
                                Label(step.enabled ? "Disable step" : "Enable step",
                                      systemImage: step.enabled ? "pause.circle" : "play.circle")
                            }
                            Button {
                                model.duplicateStep(id: step.id)
                            } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                            Button { editingStepID = step.id } label: {
                                Label("Edit…", systemImage: "slider.horizontal.3")
                            }
                            Divider()
                            Button(role: .destructive) {
                                model.removeStep(id: step.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .scale(scale: 0.92).combined(with: .opacity)))
                }
                .onDelete { model.removeSteps(at: $0) }
                .onMove { model.moveSteps(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.steps.map(\.id))
        }
    }
}

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

struct OpRow: View {
    let step: PipelineStep
    var number: Int = 1
    let metrics: OpMetrics?
    var isBroken = false
    var brokenMessage: String?
    var showConnector = false

    private var op: Op { step.op }

    var body: some View {
        VStack(spacing: 0) {
            card
            if showConnector {
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.holo.opacity(step.enabled ? 0.4 : 0.15))
                    .padding(.vertical, 1)
            }
        }
        .padding(.vertical, 2)
        .opacity(step.enabled ? 1 : 0.55)
    }

    var card: some View {
        GlassCard(padding: 12, glow: isBroken) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.holo.opacity(0.10))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.callout)
                        .foregroundStyle(op.isAugmentation ? AnyShapeStyle(Theme.distillGradient) : AnyShapeStyle(Theme.accentGradient))
                }
                .overlay(alignment: .topLeading) {
                    Text("\(number)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.abyss)
                        .padding(3)
                        .background(Circle().fill(step.enabled ? Theme.holo : Color.secondary))
                        .offset(x: -4, y: -4)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(op.displayName)
                            .font(.headline)
                            .strikethrough(!step.enabled)
                        if op.isAugmentation {
                            Pill(text: "LLM", color: Theme.distilledTeal)
                        }
                        if !step.enabled {
                            Pill(text: "bypassed", color: .secondary)
                        }
                    }
                    if isBroken, let msg = brokenMessage {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                            .lineLimit(1)
                    } else {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                trailingStatus
                // Quick enable/disable toggle
                Button {
                    model_toggle()
                } label: {
                    Image(systemName: step.enabled ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(step.enabled ? Theme.holo : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(step.enabled ? "Disable step" : "Enable step")
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isBroken ? Theme.danger.opacity(0.6) : .clear, lineWidth: 1.5)
        )
    }

    // The toggle needs the model; inject via environment.
    @Environment(AppModel.self) private var model
    private func model_toggle() { model.toggleStep(id: step.id) }

    @ViewBuilder
    var trailingStatus: some View {
        if op.isAugmentation {
            Pill(text: "full run only", color: .secondary)
        } else if !step.enabled {
            EmptyView()
        } else if isBroken {
            EmptyView()
        } else if let m = metrics {
            VStack(alignment: .trailing, spacing: 2) {
                if m.rowsDropped > 0 {
                    Text("−\(m.rowsDropped) rows")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.danger)
                        .contentTransition(.numericText())
                } else if m.rowsOut > m.rowsIn {
                    Text("+\(m.rowsOut - m.rowsIn) rows")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.distilledTeal)
                        .contentTransition(.numericText())
                }
                if m.cellsChanged > 0 {
                    Text("\(m.cellsChanged) cells")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.amber)
                        .contentTransition(.numericText())
                }
                if m.rowsDropped == 0 && m.rowsOut <= m.rowsIn && m.cellsChanged == 0 {
                    Text("no change")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var icon: String {
        switch op {
        case .selectColumns, .dropColumns, .renameColumn: return "tablecells.badge.ellipsis"
        case .addColumn: return "function"
        case .filterRows: return "line.3.horizontal.decrease.circle"
        case .normalizeText: return "wand.and.stars"
        case .unifyNulls: return "circle.dashed"
        case .autoType, .coerceType: return "arrow.triangle.2.circlepath"
        case .dedupeExact, .dedupeFuzzy: return "doc.on.doc"
        case .redactPII: return "eye.slash"
        case .qualityFilter: return "checkmark.seal"
        case .languageFilter: return "globe"
        case .decontaminate: return "checkmark.shield"
        case .addTokenCount, .addLanguage, .addQualityScore: return "number"
        case .chunkText: return "scissors"
        case .split: return "chart.pie"
        case .augment: return "brain"
        }
    }

    var summary: String {
        switch op {
        case .selectColumns(let c): return "Keep: \(c.joined(separator: ", "))"
        case .dropColumns(let c): return "Drop: \(c.joined(separator: ", "))"
        case .renameColumn(let f, let t): return "\(f) → \(t)"
        case .addColumn(let n, let e): return "\(n) = \(e)"
        case .filterRows(let e): return "keep where \(e)"
        case .normalizeText(let c, _): return c.isEmpty ? "all text columns" : c.joined(separator: ", ")
        case .unifyNulls(let c): return c.isEmpty ? "all columns — NA, N/A, -, null → ∅" : c.joined(separator: ", ")
        case .autoType: return "infer int / double / bool / date per column"
        case .coerceType(let c, let t): return "\(c) → \(t.rawValue)"
        case .dedupeExact(let c): return c.isEmpty ? "across all columns" : "on \(c.joined(separator: ", "))"
        case .dedupeFuzzy(let c, let t): return "\(c), Jaccard ≥ \(String(format: "%.2f", t))"
        case .redactPII(let c, let k, let m):
            let kinds = k.isEmpty ? "all kinds" : k.map(\.rawValue).joined(separator: ", ")
            return "\(kinds) → \(m.rawValue) · \(c.isEmpty ? "all text" : c.joined(separator: ", "))"
        case .qualityFilter(let c, _): return "heuristic junk filters on \(c)"
        case .languageFilter(let c, let langs, _): return "\(c): keep \(langs.joined(separator: ", "))"
        case .decontaminate(let c, let evals, let n): return "\(c) vs \(evals.count) eval doc(s), \(n)-gram"
        case .addTokenCount(let c): return "cl100k tokens of \(c)"
        case .addLanguage(let c): return "detect language of \(c)"
        case .addQualityScore(let c): return "0–1 heuristic score of \(c)"
        case .chunkText(let c, let cfg): return "\(c): ~\(cfg.targetTokens) tokens, \(cfg.overlapTokens) overlap"
        case .split(let tr, let v, let te, let seed, _):
            return "\(Int(tr * 100))/\(Int(v * 100))/\(Int(te * 100)) · seed \(seed)"
        case .augment(let cfg): return "\(cfg.column) · \(cfg.kind.outputColumns.joined(separator: ", "))"
        }
    }
}

/// FileDocument wrapper for recipe export.
struct RecipeDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
