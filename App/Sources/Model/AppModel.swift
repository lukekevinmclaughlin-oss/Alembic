import Foundation
import SwiftUI
import AlembicEngine

enum ProjectMode: String, Codable, CaseIterable, Identifiable {
    case curate     // training-data curation leads
    case retrieve   // RAG/inference prep leads
    var id: String { rawValue }

    var title: String {
        switch self {
        case .curate: return "Curate"
        case .retrieve: return "Retrieve"
        }
    }
    var subtitle: String {
        switch self {
        case .curate: return "Distill messy data into training-grade datasets — dedupe, filter, decontaminate, shape into SFT/DPO schemas."
        case .retrieve: return "Prepare documents for RAG — clean, chunk to token budgets, attach metadata, export embedding-ready JSONL."
        }
    }
    var icon: String {
        switch self {
        case .curate: return "flask.fill"
        case .retrieve: return "square.grid.3x1.folder.badge.plus"
        }
    }
}

enum AppScreen: String, CaseIterable, Identifiable {
    case pipeline, preview, report, export, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pipeline: return "Pipeline"
        case .preview: return "Preview"
        case .report: return "Report"
        case .export: return "Export"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .pipeline: return "slider.horizontal.3"
        case .preview: return "tablecells"
        case .report: return "chart.bar.doc.horizontal"
        case .export: return "square.and.arrow.up"
        case .settings: return "gearshape"
        }
    }
}

/// A pipeline step is an op plus authoring state (stable identity + enabled flag).
/// The engine only ever sees the enabled ops; enabled/disabled is an app-side
/// convenience so a step can be muted without being deleted.
struct PipelineStep: Identifiable, Equatable {
    let id: UUID
    var op: Op
    var enabled: Bool

    init(id: UUID = UUID(), op: Op, enabled: Bool = true) {
        self.id = id
        self.op = op
        self.enabled = enabled
    }
}

/// One-tap starter pipelines, surfaced in the Pipeline toolbar.
enum RecipePreset: String, CaseIterable, Identifiable {
    case trainingStarter, ragStarter, privacyScrub, aggressiveDedupe

    var id: String { rawValue }
    var title: String {
        switch self {
        case .trainingStarter: return "Training-data starter"
        case .ragStarter: return "RAG starter"
        case .privacyScrub: return "Privacy scrub"
        case .aggressiveDedupe: return "Aggressive dedupe"
        }
    }
    var subtitle: String {
        switch self {
        case .trainingStarter: return "Clean → types → dedupe → quality → split"
        case .ragStarter: return "Clean → chunk → tokens → language"
        case .privacyScrub: return "Redact every PII kind, hash mode"
        case .aggressiveDedupe: return "Exact + near-dup at 0.75"
        }
    }

    func ops(textColumn: String) -> [Op] {
        switch self {
        case .trainingStarter:
            return [
                .normalizeText(columns: [], options: .standard),
                .unifyNulls(columns: []),
                .autoType,
                .dedupeExact(columns: []),
                .dedupeFuzzy(column: textColumn, threshold: 0.85),
                .qualityFilter(column: textColumn, rules: .standard),
                .split(train: 0.9, validation: 0.05, test: 0.05, seed: 42, stratifyBy: nil)
            ]
        case .ragStarter:
            return [
                .normalizeText(columns: [], options: .standard),
                .chunkText(column: textColumn, config: ChunkerConfig()),
                .addTokenCount(column: textColumn),
                .addLanguage(column: textColumn)
            ]
        case .privacyScrub:
            return [
                .normalizeText(columns: [], options: .standard),
                .redactPII(columns: [], kinds: [], mode: .hash)
            ]
        case .aggressiveDedupe:
            return [
                .normalizeText(columns: [], options: .standard),
                .dedupeExact(columns: []),
                .dedupeFuzzy(column: textColumn, threshold: 0.75)
            ]
        }
    }
}

@Observable
final class AppModel {
    // Project
    var mode: ProjectMode = .curate
    var hasProject = false
    var screen: AppScreen = .pipeline
    var sourceName = ""
    var importDetails: [String: String] = [:]

    // Data
    var original: Dataset?
    var sample: Dataset?                 // sampled original, preview input
    var processedSample: Dataset?        // sample after deterministic ops
    var stepMetrics: [UUID: OpMetrics] = [:]   // per-step preview metrics
    var brokenStepID: UUID?                     // step whose preview threw
    var diff: DatasetDiff.Result?
    var previewError: String?

    // Pipeline (steps carry identity + enabled state; the engine sees `ops`)
    var steps: [PipelineStep] = [] { didSet { schedulePreview() } }
    private var undoStack: [[PipelineStep]] = []
    private var redoStack: [[PipelineStep]] = []

    /// Enabled ops in order — what the engine actually runs.
    var ops: [Op] { steps.filter(\.enabled).map(\.op) }

    // Full run
    var isRunningFull = false
    var fullProgress = ""
    var runFraction: Double = 0        // 0…1 determinate progress
    var fullResult: ExecutionResult?
    var fullError: String?
    var card: DatasetCard?
    private var runTask: Task<Void, Never>?

    // Preferences
    var reduceMotionOverride: Bool = UserDefaults.standard.bool(forKey: "reduceMotion") {
        didSet { UserDefaults.standard.set(reduceMotionOverride, forKey: "reduceMotion") }
    }

    // Debug/verification hook: a column the preview should auto-profile on appear.
    var debugProfileColumn: String?

    // SQLite multi-table import
    struct PendingSQLite: Identifiable {
        let id = UUID()
        let url: URL
        let tables: [String]
    }
    var pendingSQLite: PendingSQLite?

    // Recent imports (security-scoped bookmarks)
    struct RecentImport: Codable, Identifiable, Equatable {
        var id: String { name + String(bookmark.hashValue) }
        let name: String
        let bookmark: Data
    }
    var recents: [RecentImport] = []

    // Provider (BYO key — key lives in Keychain only)
    var providerConfig: ProviderConfig {
        didSet { persistProviderConfig() }
    }
    var apiKey: String {
        didSet { KeychainStore.save(apiKey, for: "provider-api-key") }
    }
    var priceInputPerMTok: Double = 3.0
    var priceOutputPerMTok: Double = 15.0

    private var previewTask: Task<Void, Never>?
    private var previewGeneration = 0

    init() {
        if let data = UserDefaults.standard.data(forKey: "providerConfig"),
           let cfg = try? JSONDecoder().decode(ProviderConfig.self, from: data) {
            providerConfig = cfg
        } else {
            providerConfig = ProviderConfig()
        }
        apiKey = KeychainStore.load(for: "provider-api-key") ?? ""
        if let data = UserDefaults.standard.data(forKey: "recentImports"),
           let list = try? JSONDecoder().decode([RecentImport].self, from: data) {
            recents = list
        }
    }

    private func persistProviderConfig() {
        if let data = try? JSONEncoder().encode(providerConfig) {
            UserDefaults.standard.set(data, forKey: "providerConfig")
        }
    }

    var columns: [String] {
        processedSample?.columns ?? sample?.columns ?? []
    }

    var hasAugmentOps: Bool { ops.contains { $0.isAugmentation } }

    /// "8 rows → 7 · 4 cols" summary chip for the workspace header.
    var flowSummary: String? {
        guard let sample else { return nil }
        let inRows = importDetails["rows"] ?? String(sample.rowCount)
        guard let out = processedSample else { return "\(inRows) rows" }
        let scale: String
        if let total = Int(inRows), sample.rowCount > 0, total > sample.rowCount {
            // Preview is sampled — extrapolate the output count for honesty
            let ratio = Double(out.rowCount) / Double(sample.rowCount)
            scale = "≈\(Int(ratio * Double(total)))"
        } else {
            scale = String(out.rowCount)
        }
        return "\(inRows) → \(scale) rows · \(out.columnCount) cols"
    }

    /// Rows in the full dataset (from import metadata; falls back to sample size).
    private var fullRowCount: Int {
        Int(importDetails["rows"] ?? "") ?? sample?.rowCount ?? 0
    }

    /// Estimate one augment step's cost against the 200-row sample, then
    /// extrapolate to the full dataset — cheap enough to call every render.
    func augmentEstimate(_ cfg: AugmentConfig) -> (calls: Int, input: Int, output: Int)? {
        guard let sample, sample.rowCount > 0 else { return nil }
        let e = Augmentor.estimate(cfg, dataset: sample)
        let ratio = Double(fullRowCount) / Double(sample.rowCount)
        return (Int(Double(e.calls) * ratio),
                Int(Double(e.estimatedInputTokens) * ratio),
                Int(Double(e.estimatedOutputTokens) * ratio))
    }

    /// Whole-pipeline LLM cost estimate (approximate, sample-extrapolated).
    func augmentCostEstimate() -> (calls: Int, cost: Double)? {
        guard hasAugmentOps else { return nil }
        var calls = 0, input = 0, output = 0
        for step in steps where step.enabled {
            if case .augment(let cfg) = step.op, let e = augmentEstimate(cfg) {
                calls += e.calls; input += e.input; output += e.output
            }
        }
        guard calls > 0 else { return nil }
        let cost = Double(input) / 1e6 * priceInputPerMTok + Double(output) / 1e6 * priceOutputPerMTok
        return (calls, cost)
    }

    // MARK: - Import

    func importFile(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // SQLite with multiple tables → let the user pick
        if Importer.detectFormat(url: url) == .sqlite {
            if let tables = try? SQLiteReader.tableNames(url: url), tables.count > 1 {
                pendingSQLite = PendingSQLite(url: url, tables: tables)
                rememberRecent(url: url)
                return
            }
        }
        performImport(url: url, sqliteTable: nil)
    }

    func importSQLite(url: URL, table: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        pendingSQLite = nil
        performImport(url: url, sqliteTable: table)
    }

    private func performImport(url: URL, sqliteTable: String?) {
        do {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let outcome = isDir
                ? try Importer.importFolder(url: url)
                : try Importer.importFile(url: url, sqliteTable: sqliteTable)
            original = outcome.dataset
            sample = outcome.dataset.sample(head: 100, spread: 100)
            sourceName = url.lastPathComponent
            importDetails = outcome.details
            importDetails["format"] = outcome.format.rawValue
            importDetails["rows"] = String(outcome.dataset.rowCount)
            hasProject = true
            screen = .pipeline
            fullResult = nil
            card = nil
            previewError = nil
            rememberRecent(url: url)
            if steps.isEmpty {
                steps = defaultOps(for: mode, dataset: outcome.dataset).map { PipelineStep(op: $0) }
            } else {
                schedulePreview()
            }
        } catch {
            previewError = error.localizedDescription
        }
    }

    func rememberRecent(url: URL) {
        #if os(macOS)
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope) else { return }
        #else
        guard let bookmark = try? url.bookmarkData() else { return }
        #endif
        let entry = RecentImport(name: url.lastPathComponent, bookmark: bookmark)
        recents.removeAll { $0.name == entry.name }
        recents.insert(entry, at: 0)
        if recents.count > 6 { recents = Array(recents.prefix(6)) }
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: "recentImports")
        }
    }

    func openRecent(_ recent: RecentImport) {
        var stale = false
        #if os(macOS)
        guard let url = try? URL(resolvingBookmarkData: recent.bookmark,
                                 options: .withSecurityScope,
                                 bookmarkDataIsStale: &stale) else {
            recents.removeAll { $0 == recent }
            return
        }
        #else
        guard let url = try? URL(resolvingBookmarkData: recent.bookmark,
                                 bookmarkDataIsStale: &stale) else {
            recents.removeAll { $0 == recent }
            return
        }
        #endif
        importFile(url: url)
    }

    /// Starter pipeline per mode — immediately useful, fully editable.
    func defaultOps(for mode: ProjectMode, dataset: Dataset) -> [Op] {
        let textCol = guessTextColumn(dataset) ?? dataset.columns.first ?? "text"
        switch mode {
        case .curate:
            return [
                .normalizeText(columns: [], options: .standard),
                .unifyNulls(columns: []),
                .autoType,
                .dedupeExact(columns: [])
            ]
        case .retrieve:
            return [
                .normalizeText(columns: [], options: .standard),
                .chunkText(column: textCol, config: ChunkerConfig()),
                .addTokenCount(column: textCol)
            ]
        }
    }

    func applyPreset(_ preset: RecipePreset) {
        let ds = processedSample ?? sample ?? Dataset(columns: [])
        let textCol = guessTextColumn(ds) ?? ds.columns.first ?? "text"
        pushUndo()
        steps = preset.ops(textColumn: textCol).map { PipelineStep(op: $0) }
    }

    func guessTextColumn(_ dataset: Dataset) -> String? {
        // Longest average string column wins
        var best: (String, Int)?
        for (idx, name) in dataset.columns.enumerated() {
            var len = 0
            for r in dataset.records.prefix(50) where idx < r.values.count {
                if case .string(let s) = r.values[idx] { len += s.count }
            }
            if len > (best?.1 ?? 0) { best = (name, len) }
        }
        return best?.0
    }

    // MARK: - Pipeline editing

    /// Append an op and return the new step's id (so the UI can open its editor).
    @discardableResult
    func addOp(_ op: Op) -> UUID {
        pushUndo()
        let step = PipelineStep(op: op)
        steps.append(step)
        return step.id
    }

    func removeSteps(at offsets: IndexSet) {
        pushUndo()
        steps.remove(atOffsets: offsets)
    }

    func removeStep(id: UUID) {
        guard let idx = steps.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        steps.remove(at: idx)
    }

    func moveSteps(from source: IndexSet, to destination: Int) {
        pushUndo()
        steps.move(fromOffsets: source, toOffset: destination)
    }

    func replaceOp(id: UUID, with op: Op) {
        guard let idx = steps.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        steps[idx].op = op
    }

    func toggleStep(id: UUID) {
        guard let idx = steps.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        steps[idx].enabled.toggle()
    }

    func duplicateStep(id: UUID) {
        guard let idx = steps.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        steps.insert(PipelineStep(op: steps[idx].op, enabled: steps[idx].enabled), at: idx + 1)
    }

    func step(id: UUID) -> PipelineStep? { steps.first { $0.id == id } }

    private func pushUndo() {
        undoStack.append(steps)
        redoStack.removeAll()
        if undoStack.count > 100 { undoStack.removeFirst() }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(steps)
        steps = prev
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(steps)
        steps = next
    }

    // MARK: - Live sampled preview (deterministic ops only; LLM steps are full-run)
    //
    // Applied step-by-step so a failure is attributed to the exact step, and its
    // per-step metrics can be shown on each card.

    func schedulePreview() {
        guard let sample else { return }
        previewGeneration += 1
        let gen = previewGeneration
        let snapshot = steps
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)   // debounce
            guard !Task.isCancelled else { return }

            var current = sample
            var metrics: [UUID: OpMetrics] = [:]
            var broken: UUID?
            var errorMessage: String?

            for step in snapshot where step.enabled {
                if Task.isCancelled { return }
                if step.op.isAugmentation { continue }   // LLM steps run at full-run only
                do {
                    let (next, m) = try await PipelineExecutor.apply(step.op, to: current)
                    current = next
                    metrics[step.id] = m
                } catch {
                    broken = step.id
                    errorMessage = error.localizedDescription
                    break
                }
            }
            let finalDataset = current
            guard !Task.isCancelled, let self, self.previewGeneration == gen else { return }
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    self.processedSample = finalDataset
                    self.stepMetrics = metrics
                    self.brokenStepID = broken
                    self.previewError = errorMessage
                    self.diff = DatasetDiff.diff(before: sample, after: finalDataset)
                }
            }
        }
    }

    // MARK: - Full run

    func runFull() {
        guard let original, !isRunningFull, !ops.isEmpty else { return }
        isRunningFull = true
        fullError = nil
        fullProgress = "Starting…"
        runFraction = 0
        let opsCopy = ops
        let needsClient = hasAugmentOps
        let client: (any LLMClient)? = needsClient
            ? LLMClientFactory.make(config: providerConfig, apiKey: apiKey)
            : nil

        runTask = Task {
            do {
                let result = try await PipelineExecutor.run(
                    original, ops: opsCopy, augmentClient: client,
                    progress: { i, name in
                        Task { @MainActor [weak self] in
                            self?.fullProgress = "Step \(i + 1)/\(opsCopy.count): \(name)"
                            self?.runFraction = Double(i) / Double(max(1, opsCopy.count))
                        }
                    },
                    augmentProgress: { done, total in
                        Task { @MainActor [weak self] in
                            self?.fullProgress = "LLM augmentation: \(done)/\(total) rows"
                        }
                    })
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isRunningFull = false
                        self.fullProgress = ""
                        self.fullError = "Run cancelled"
                    }
                    return
                }
                let computedCard = DatasetCard.compute(dataset: result.dataset, metrics: result.metrics)
                await MainActor.run {
                    self.fullResult = result
                    self.card = computedCard
                    self.isRunningFull = false
                    self.fullProgress = ""
                    self.screen = .report
                }
            } catch {
                await MainActor.run {
                    self.fullError = error.localizedDescription
                    self.isRunningFull = false
                    self.fullProgress = ""
                }
            }
        }
    }

    func cancelFull() {
        runTask?.cancel()
    }

    /// Dataset to export: full result if run, else processed sample.
    var exportDataset: Dataset? { fullResult?.dataset ?? processedSample }
    var exportIsSampleOnly: Bool { fullResult == nil }

    // MARK: - Recipe I/O

    func recipeData() throws -> Data {
        try Recipe(name: sourceName.isEmpty ? "Alembic Recipe" : "\(sourceName) recipe", ops: ops).encoded()
    }

    func loadRecipe(from data: Data) {
        do {
            let recipe = try Recipe.decode(data)
            pushUndo()
            steps = recipe.ops.map { PipelineStep(op: $0) }
        } catch {
            previewError = error.localizedDescription
        }
    }

    // MARK: - Sample data (first-run quick start)

    /// A deliberately messy support-ticket CSV: duplicates, mojibake-ish text,
    /// a PII leak, a non-English row, junk, ragged types — exercises the pipeline.
    static let sampleCSV = """
    ticket_id,customer,message,status,created
    1001,Alice,"  The export keeps failing when I click download.  Please help. Contact me at alice@example.com ",OPEN,2024-01-15
    1002,Bob,"The export keeps failing when I click download. Please help.",OPEN,15.01.2024
    1003,Chen,"导出功能一直失败，点击下载按钮没有任何反应，请尽快帮我解决这个问题。",open,2024-02-03
    1004,Dana,"!!!!! URGENT URGENT URGENT FIX NOW !!!!!",N/A,2024-02-11
    1005,Erik,"Love the product. One small bug: the CSV has a trailing comma on the last row which breaks my parser.",CLOSED,Feb 20 2024
    1006,Farah,"My API key sk-ant-abc123def456ghi789jkl012mno345pqr leaked in the logs — please rotate it.",OPEN,2024-03-01
    1007,Greg,"asdf asdf asdf $$$ ### @@@",-,2024-03-05
    1008,Hana,"Could you add a dark mode? Would really help for late-night work sessions with the dashboard.",OPEN,2024-03-09
    1009,Alice,"The export keeps failing when I click download. Please help.",open,2024-01-15
    1010,Ivan,"Feature request: bulk edit for tickets, and a keyboard shortcut to jump between them quickly.",CLOSED,2024-03-14
    """

    func loadSampleData() {
        guard let result = try? CSVReader.read(text: Self.sampleCSV) else { return }
        original = result.dataset
        sample = result.dataset.sample(head: 100, spread: 100)
        sourceName = "sample_support_tickets.csv"
        importDetails = ["format": "csv", "rows": String(result.dataset.rowCount),
                         "header": "detected", "encoding": "utf-8"]
        hasProject = true
        screen = .pipeline
        fullResult = nil
        card = nil
        previewError = nil
        steps = defaultOps(for: mode, dataset: result.dataset).map { PipelineStep(op: $0) }
    }

    func reset() {
        hasProject = false
        original = nil
        sample = nil
        processedSample = nil
        stepMetrics = [:]
        brokenStepID = nil
        diff = nil
        steps = []
        undoStack = []
        redoStack = []
        fullResult = nil
        card = nil
        fullError = nil
        previewError = nil
        sourceName = ""
        importDetails = [:]
        pendingSQLite = nil
        runFraction = 0
    }
}
