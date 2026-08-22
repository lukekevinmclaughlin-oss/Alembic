import SwiftUI
import AlembicEngine
import UniformTypeIdentifiers

/// Schema-shaped export: pick a target, map columns, validate, write JSONL/CSV.
struct ExportView: View {
    @Environment(AppModel.self) private var model
    @State private var schema: TrainingSchema = .alpaca
    @State private var mapping: [String: String] = [:]
    @State private var shapeResult: ShapeResult?
    @State private var showExporter = false
    @State private var showRawExporter = false
    @State private var rawFormat: RawFormat = .jsonl
    @State private var exportData = Data()
    @State private var exportName = "dataset"
    @State private var splitChoice = "all"

    enum RawFormat: String, CaseIterable, Identifiable {
        case jsonl, csv, json
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if model.exportIsSampleOnly {
                    GlassCard {
                        Label("Full pipeline hasn't run — exports below use the preview sample only. Run the full pipeline for the complete dataset.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Theme.amber)
                    }
                }
                schemaCard
                mappingCard
                validationCard
                rawExportCard
            }
            .padding(16)
        }
        .navigationTitle("Export")
        .onAppear { autoMap() }
        .onChange(of: schema) { _, _ in autoMap() }
        .fileExporter(isPresented: $showExporter,
                      document: RecipeDocument(data: exportData),
                      contentType: .json,
                      defaultFilename: exportName) { handleExport($0) }
        .fileExporter(isPresented: $showRawExporter,
                      document: RecipeDocument(data: exportData),
                      contentType: rawFormat == .csv ? .commaSeparatedText : .json,
                      defaultFilename: exportName) { handleExport($0) }
    }

    /// On a successful save, reveal the file in Finder (macOS).
    func handleExport(_ result: Result<URL, Error>) {
        #if os(macOS)
        if case .success(let url) = result {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        #endif
    }

    var schemaCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(icon: "square.stack.3d.up", title: "Target schema",
                           subtitle: "every row is validated; invalid rows are quarantined with reasons, never silently dropped")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                    ForEach(TrainingSchema.allCases) { s in
                        Button {
                            schema = s
                        } label: {
                            HStack {
                                Image(systemName: schema == s ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(schema == s ? Theme.distilledTeal : .secondary)
                                Text(s.displayName)
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(schema == s ? Theme.deepTeal.opacity(0.25) : Color.white.opacity(0.04)))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    var mappingCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(icon: "arrow.left.arrow.right", title: "Field mapping")
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(schema.fields) { field in
                        GridRow {
                            HStack(spacing: 6) {
                                Text(field.name).font(.callout.monospaced())
                                if field.required {
                                    Text("required").font(.caption2).foregroundStyle(Theme.danger)
                                }
                            }
                            .gridColumnAlignment(.leading)
                            Image(systemName: "arrow.left")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("", selection: Binding(
                                get: { mapping[field.name] ?? "" },
                                set: { mapping[field.name] = $0.isEmpty ? nil : $0 })) {
                                Text("—").tag("")
                                ForEach(availableColumns, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 260, alignment: .leading)
                        }
                    }
                }
                HStack {
                    Button("Auto-map") { autoMap() }
                        .buttonStyle(DistillButtonStyle(prominent: false))
                    Spacer()
                    Button {
                        runShapeAndExport()
                    } label: {
                        Label("Validate & Export JSONL", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(DistillButtonStyle())
                    .disabled(missingRequired)
                }
            }
        }
    }

    @ViewBuilder
    var validationCard: some View {
        if let r = shapeResult {
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    CardHeader(icon: r.quarantined.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                               title: "\(r.validCount) valid rows · \(r.quarantined.count) quarantined")
                    if !r.quarantined.isEmpty {
                        ForEach(Array(r.quarantined.prefix(12).enumerated()), id: \.offset) { _, q in
                            Text("row #\(q.recordID): \(q.reason)")
                                .font(.caption.monospaced())
                                .foregroundStyle(Theme.danger)
                        }
                        if r.quarantined.count > 12 {
                            Text("… and \(r.quarantined.count - 12) more")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    var rawExportCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(icon: "tablecells.badge.ellipsis", title: "Raw export",
                           subtitle: "the processed table as-is, no schema shaping")
                HStack {
                    Picker("Format", selection: $rawFormat) {
                        ForEach(RawFormat.allCases) { f in
                            Text(f.rawValue.uppercased()).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                    if hasSplitColumn {
                        Picker("Split", selection: $splitChoice) {
                            Text("All").tag("all")
                            Text("train").tag("train")
                            Text("validation").tag("validation")
                            Text("test").tag("test")
                        }
                        .fixedSize()
                        .accessibilityLabel("Which split to export")
                    }
                    Spacer()
                    Button {
                        runRawExport()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(DistillButtonStyle())
                }
                if hasSplitColumn {
                    Text("Export each split as its own file — pick train/validation/test above, export, repeat.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var availableColumns: [String] {
        model.exportDataset?.columns ?? []
    }

    var hasSplitColumn: Bool {
        availableColumns.contains("split")
    }

    var missingRequired: Bool {
        schema.fields.contains { $0.required && (mapping[$0.name] ?? "").isEmpty }
    }

    func autoMap() {
        let auto = FieldMapping.autoMap(schema: schema, columns: availableColumns)
        mapping = auto.map
        shapeResult = nil
    }

    func runShapeAndExport() {
        guard let ds = model.exportDataset else { return }
        let result = SchemaShaper.shape(ds, schema: schema, mapping: FieldMapping(mapping))
        shapeResult = result
        exportData = Data(result.jsonl.utf8)
        exportName = "\(model.sourceName.isEmpty ? "dataset" : stripExt(model.sourceName))-\(schema.rawValue)"
        showExporter = true
    }

    func runRawExport() {
        guard var ds = model.exportDataset else { return }
        let base = model.sourceName.isEmpty ? "dataset" : stripExt(model.sourceName)
        var suffix = "clean"
        if splitChoice != "all" && hasSplitColumn {
            ds = filterSplit(ds, splitChoice)
            suffix = splitChoice
        }
        switch rawFormat {
        case .jsonl:
            exportData = Data(JSONLWriter.write(ds).utf8)
        case .csv:
            exportData = Data(CSVWriter.write(ds).utf8)
        case .json:
            let jsonl = JSONLWriter.write(ds)
            let objects = jsonl.split(separator: "\n").map(String.init)
            exportData = Data(("[\n" + objects.joined(separator: ",\n") + "\n]").utf8)
        }
        exportName = "\(base)-\(suffix)"
        showRawExporter = true
    }

    func filterSplit(_ ds: Dataset, _ split: String) -> Dataset {
        guard let idx = ds.columnIndex(of: "split") else { return ds }
        var out = ds
        out.records = ds.records.filter { idx < $0.values.count && $0.values[idx].display == split }
        return out
    }

    func stripExt(_ s: String) -> String {
        (s as NSString).deletingPathExtension
    }
}
