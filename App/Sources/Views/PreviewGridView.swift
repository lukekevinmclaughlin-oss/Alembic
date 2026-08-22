import SwiftUI
import AlembicEngine

/// Sampled before/after data grid. Amber = modified cell, teal = added row,
/// red strip = dropped rows (toggle to inspect them). Tap a modified cell to
/// see its before/after diff.
struct PreviewGridView: View {
    @Environment(AppModel.self) private var model
    @State private var showDropped = false
    @State private var inspection: CellInspection?
    @State private var filterText = ""
    @State private var sort: SortState?
    @State private var profileTarget: ProfileTarget?

    let cellWidth: CGFloat = 170
    let maxPreviewRows = 200

    struct CellInspection: Identifiable {
        let id = UUID()
        let column: String
        let before: String?
        let after: String
        var isChanged: Bool { before != nil && before != after }
    }

    struct SortState: Equatable {
        var column: String
        var ascending: Bool
    }

    struct ProfileTarget: Identifiable {
        let id = UUID()
        let column: String
    }

    var body: some View {
        VStack(spacing: 0) {
            legend
            if let after = model.processedSample {
                grid(after: after)
            } else {
                ProgressView("Distilling preview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Preview")
        .sheet(item: $inspection) { item in
            cellDetail(item)
        }
        .sheet(item: $profileTarget) { target in
            ColumnProfileSheet(column: target.column)
        }
        .onChange(of: model.debugProfileColumn) { _, col in
            if let col { profileTarget = ProfileTarget(column: col); model.debugProfileColumn = nil }
        }
        .onAppear {
            if let col = model.debugProfileColumn {
                profileTarget = ProfileTarget(column: col); model.debugProfileColumn = nil
            }
        }
    }

    var legend: some View {
        HStack(spacing: 14) {
            legendSwatch(Theme.cellModified, "Modified")
            legendSwatch(Theme.rowAdded, "Added row")
            legendSwatch(Theme.rowDropped, "Dropped")
            if let diff = model.diff {
                Text("\(diff.droppedIDs.count) dropped · \(diff.addedColumns.count) new cols")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Filter rows…", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(width: 140)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(Theme.glassEdge, lineWidth: 0.8))
            Toggle("Dropped", isOn: $showDropped)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .accessibilityLabel("Show dropped rows")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 14, height: 14)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.2)))
            Text(label).font(.caption2)
        }
    }

    func matchesFilter(_ record: Record) -> Bool {
        guard !filterText.isEmpty else { return true }
        let needle = filterText.lowercased()
        return record.values.contains { $0.display.lowercased().contains(needle) }
    }

    func grid(after: Dataset) -> some View {
        let diff = model.diff
        let filtered = after.records.filter(self.matchesFilter)
        let sorted = applySort(filtered, in: after)
        let visible = Array(sorted.prefix(maxPreviewRows))
        let droppedRecords: [Record] = showDropped && diff != nil && model.sample != nil
            ? model.sample!.records.filter { diff!.droppedIDs.contains($0.id) && matchesFilter($0) }
            : []

        return GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                gridContent(after: after, visible: visible, diff: diff, droppedRecords: droppedRecords)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
            }
        }
    }

    func applySort(_ records: [Record], in dataset: Dataset) -> [Record] {
        guard let sort, let idx = dataset.columnIndex(of: sort.column) else { return records }
        return records.sorted { a, b in
            let av = idx < a.values.count ? a.values[idx] : .null
            let bv = idx < b.values.count ? b.values[idx] : .null
            return sort.ascending ? (av < bv) : (bv < av)
        }
    }

    /// Cycle a column's sort: none → ascending → descending → none.
    func cycleSort(_ column: String) {
        withAnimation(.easeOut(duration: 0.2)) {
            if sort?.column != column {
                sort = SortState(column: column, ascending: true)
            } else if sort?.ascending == true {
                sort = SortState(column: column, ascending: false)
            } else {
                sort = nil
            }
        }
    }

    func gridContent(after: Dataset, visible: [Record], diff: DatasetDiff.Result?, droppedRecords: [Record]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(visible) { record in
                        rowView(record: record, columns: after.columns, diff: diff, dropped: false)
                    }
                    if !droppedRecords.isEmpty {
                        Text("Dropped rows")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.danger)
                            .padding(6)
                        ForEach(droppedRecords.prefix(50)) { record in
                            rowView(record: record, columns: model.sample?.columns ?? [], diff: nil, dropped: true)
                        }
                    }
                } header: {
                    headerRow(columns: after.columns, diff: diff)
                }
        }
    }

    func headerRow(columns: [String], diff: DatasetDiff.Result?) -> some View {
        HStack(spacing: 1) {
            ForEach(columns, id: \.self) { col in
                HStack(spacing: 4) {
                    Button {
                        cycleSort(col)
                    } label: {
                        HStack(spacing: 3) {
                            Text(col)
                                .font(.caption.weight(.bold))
                                .lineLimit(1)
                            if sort?.column == col {
                                Image(systemName: sort!.ascending ? "arrow.up" : "arrow.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.holo)
                            }
                            if diff?.addedColumns.contains(col) == true {
                                Image(systemName: "plus.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.distilledTeal)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Sort by \(col)")
                    Spacer(minLength: 0)
                    Button {
                        profileTarget = ProfileTarget(column: col)
                    } label: {
                        Image(systemName: "chart.bar.doc.horizontal")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Profile \(col)")
                    .accessibilityLabel("Profile column \(col)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(width: cellWidth, alignment: .leading)
                .background(Theme.abyss.opacity(0.7))
            }
        }
        .background(.thinMaterial)
    }

    func rowView(record: Record, columns: [String], diff: DatasetDiff.Result?, dropped: Bool) -> some View {
        let change = diff?.rowChanges[record.id]
        let rowTint: Color? = dropped ? Theme.rowDropped : {
            if case .added = change { return Theme.rowAdded }
            return nil
        }()

        return HStack(spacing: 1) {
            ForEach(Array(columns.enumerated()), id: \.offset) { idx, col in
                let value = idx < record.values.count ? record.values[idx] : .null
                let isModified: Bool = {
                    if case .modified(let cols) = change { return cols.contains(col) }
                    return false
                }()
                Text(cellText(value))
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(value.isNull ? Color.secondary.opacity(0.5) : (dropped ? .secondary : .primary))
                    .strikethrough(dropped)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(width: cellWidth, alignment: .leading)
                    .background(isModified ? Theme.cellModified : (rowTint ?? Color.white.opacity(0.02)))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        inspect(record: record, column: col, value: value, isModified: isModified)
                    }
            }
        }
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.white.opacity(0.06)), alignment: .bottom)
    }

    func inspect(record: Record, column: String, value: Value, isModified: Bool) {
        var before: String?
        if isModified, let sample = model.sample,
           let bIdx = sample.columnIndex(of: column),
           let old = sample.records.first(where: { $0.id == record.id }),
           bIdx < old.values.count {
            before = old.values[bIdx].display
        }
        let after = value.display
        // Only open for content worth inspecting
        guard isModified || after.count > 20 else { return }
        inspection = CellInspection(column: column, before: before, after: after)
    }

    func cellText(_ v: Value) -> String {
        if v.isNull { return "∅" }
        let d = v.display
        return d.count > 80 ? String(d.prefix(80)) + "…" : d
    }

    func cellDetail(_ item: CellInspection) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let before = item.before, item.isChanged {
                        VStack(alignment: .leading, spacing: 6) {
                            Pill(text: "BEFORE", color: Theme.amber)
                            Text(before)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.amber.opacity(0.08)))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.amber.opacity(0.3)))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Pill(text: "AFTER", color: Theme.holo)
                            Text(item.after)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.holo.opacity(0.08)))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.holo.opacity(0.3)))
                        }
                    } else {
                        Text(item.after)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle(item.column)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { inspection = nil }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 340)
        .preferredColorScheme(.dark)
    }
}

/// Deep single-column profile, computed on the preview sample.
struct ColumnProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let column: String

    var profile: ColumnProfile? {
        guard let ds = model.processedSample ?? model.sample else { return nil }
        return ColumnProfiler.profile(ds, column: column)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let p = profile {
                    VStack(alignment: .leading, spacing: 14) {
                        statsGrid(p)
                        if p.isNumeric { numericCard(p) }
                        if p.isText { tokenCard(p) }
                        if !p.topValues.isEmpty { topValuesCard(p) }
                    }
                    .padding(16)
                } else {
                    ContentUnavailableView("No data", systemImage: "tablecells",
                                           description: Text("This column has nothing to profile."))
                        .padding(.top, 40)
                }
            }
            .navigationTitle(column)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 380)
        .preferredColorScheme(.dark)
    }

    func statsGrid(_ p: ColumnProfile) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(icon: "info.circle", title: "Overview",
                           subtitle: "sampled from \(p.sampleCount) rows")
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow { stat("Type"); Pill(text: p.dominantType, color: p.dominantType == "string" ? Theme.amber : Theme.holo) }
                    GridRow { stat("Nulls"); Text(String(format: "%.1f%%", p.nullFraction * 100)).font(.callout.monospacedDigit()) }
                    GridRow { stat("Unique"); Text("\(p.uniqueCount)\(p.uniqueCapped ? "+" : "")").font(.callout.monospacedDigit()) }
                    GridRow { stat("Non-null"); Text("\(p.nonNullCount)").font(.callout.monospacedDigit()) }
                }
                if p.typeMix.count > 1 {
                    Text("Mixed types: " + p.typeMix.map { "\($0.type)×\($0.count)" }.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(Theme.amber)
                }
            }
        }
    }

    func numericCard(_ p: ColumnProfile) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(icon: "function", title: "Numeric summary")
                HStack(spacing: 20) {
                    metric("min", fmt(p.numericMin))
                    metric("mean", fmt(p.numericMean))
                    metric("max", fmt(p.numericMax))
                }
            }
        }
    }

    func tokenCard(_ p: ColumnProfile) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(icon: "number", title: "Token summary", subtitle: "cl100k")
                HStack(spacing: 20) {
                    metric("min", "\(p.tokenMin ?? 0)")
                    metric("mean", String(format: "%.0f", p.tokenMean ?? 0))
                    metric("max", "\(p.tokenMax ?? 0)")
                    metric("total", abbrev(p.tokenTotal ?? 0))
                }
            }
        }
    }

    func topValuesCard(_ p: ColumnProfile) -> some View {
        let maxCount = p.topValues.map(\.count).max() ?? 1
        return GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(icon: "list.number", title: "Most frequent values")
                ForEach(Array(p.topValues.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 8) {
                        Text(entry.value.isEmpty ? "∅" : entry.value)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .frame(width: 150, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.06))
                                Capsule().fill(Theme.accentGradient)
                                    .frame(width: max(4, geo.size.width * CGFloat(entry.count) / CGFloat(maxCount)))
                            }
                        }
                        .frame(height: 10)
                        Text("\(entry.count)").font(.caption2.monospacedDigit()).frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
    }

    func stat(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.accentGradient)
        }
    }

    func fmt(_ d: Double?) -> String {
        guard let d else { return "—" }
        if d == d.rounded() && abs(d) < 1e12 { return String(Int64(d)) }
        return String(format: "%.3g", d)
    }

    func abbrev(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fk", Double(n) / 1_000)
        default: return String(n)
        }
    }
}
