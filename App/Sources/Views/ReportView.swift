import SwiftUI
import AlembicEngine
import UniformTypeIdentifiers

/// The dataset card: token histograms, column stats, language mix, provenance.
struct ReportView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var purchase: PurchaseManager
    @State private var showCardExporter = false
    @State private var barsGrown = false
    @State private var showPaywall = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let err = model.fullError {
                    GlassCard {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger)
                    }
                }
                if let card = model.card {
                    cardContent(card)
                } else if model.isRunningFull {
                    GlassCard {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text(model.fullProgress).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    GlassCard {
                        VStack(spacing: 12) {
                            Image(systemName: "chart.bar.doc.horizontal")
                                .font(.system(size: 38))
                                .foregroundStyle(.secondary)
                            Text("Run the full pipeline to generate the dataset card")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button {
                                if model.hasAugmentOps && !purchase.hasAccess {
                                    showPaywall = true
                                } else {
                                    model.runFull()
                                }
                            } label: {
                                Label("Run Full Pipeline", systemImage: "play.fill")
                            }
                            .buttonStyle(DistillButtonStyle())
                            .disabled(model.ops.isEmpty || model.original == nil)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Report")
        .toolbar {
            if model.card != nil {
                Button {
                    showCardExporter = true
                } label: {
                    Label("Export Card", systemImage: "square.and.arrow.up")
                }
            }
        }
        .fileExporter(isPresented: $showCardExporter,
                      document: RecipeDocument(data: Data((model.card?.markdown() ?? "").utf8)),
                      contentType: .plainText,
                      defaultFilename: "dataset-card") { _ in }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(purchase)
        }
    }

    @ViewBuilder
    func cardContent(_ card: DatasetCard) -> some View {
        // Headline numbers
        HStack(spacing: 12) {
            statTile("Rows", card.rowCount.formatted(), "tablecells")
            statTile("Columns", String(card.columnCount), "rectangle.split.3x1")
            if let tokens = card.columns.compactMap(\.tokenStats).first {
                statTile("Total tokens", "≈\(abbrev(tokens.total))", "number")
                statTile("Median tokens/row", String(tokens.p50), "chart.bar.fill")
            }
        }

        // Cleaning-impact tiles (derived from pipeline provenance)
        let impact = cleaningImpact(card)
        if impact.hasAny {
            HStack(spacing: 12) {
                if let removed = impact.rowsRemoved {
                    statTile("Rows removed", removed.formatted(), "trash")
                }
                if let dropped = impact.dedupDropped {
                    statTile("Duplicates cut", dropped.formatted(), "doc.on.doc")
                }
                if let pii = impact.piiRedacted {
                    statTile("PII redacted", pii.formatted(), "eye.slash")
                }
                if let contam = impact.contaminated {
                    statTile("Contaminated", contam.formatted(), "checkmark.shield")
                }
            }
        }

        // Token histogram
        if let tokens = card.columns.compactMap(\.tokenStats).first, !tokens.histogram.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(icon: "chart.bar.fill", title: "Token distribution",
                               subtitle: "mean \(Int(tokens.mean)) · p95 \(tokens.p95) · max \(tokens.max) · tokenizer \(card.tokenizerName)")
                    histogramView(tokens.histogram)
                }
            }
        }

        // Language mix
        if !card.languageMix.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(icon: "globe", title: "Language mix", subtitle: "sampled")
                    ForEach(card.languageMix, id: \.code) { entry in
                        HStack {
                            Text(entry.code).font(.caption.weight(.bold)).frame(width: 36, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.08))
                                    Capsule().fill(Theme.distillGradient)
                                        .frame(width: max(4, geo.size.width * entry.fraction))
                                }
                            }
                            .frame(height: 10)
                            Text(String(format: "%.1f%%", entry.fraction * 100))
                                .font(.caption.monospacedDigit())
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
            }
        }

        // Column stats
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(icon: "tablecells", title: "Columns")
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Name").font(.caption.weight(.bold))
                        Text("Type").font(.caption.weight(.bold))
                        Text("Nulls").font(.caption.weight(.bold))
                        Text("Unique").font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.secondary)
                    ForEach(card.columns) { col in
                        GridRow {
                            Text(col.name).font(.caption.monospaced())
                            Pill(text: col.typeName, color: col.typeName == "string" ? Theme.amber : Theme.distilledTeal)
                            Text(String(format: "%.1f%%", col.nullFraction * 100)).font(.caption.monospacedDigit())
                            Text(col.uniqueCount >= 10_000 ? "10k+" : String(col.uniqueCount)).font(.caption.monospacedDigit())
                        }
                    }
                }
            }
        }

        // Pipeline provenance
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(icon: "arrow.triangle.branch", title: "Pipeline provenance",
                           subtitle: "every step, every effect — this is the recipe's audit trail")
                ForEach(Array(card.pipelineSummary.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(i + 1)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Theme.copper.opacity(0.3)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.op).font(.caption.weight(.semibold))
                            HStack(spacing: 8) {
                                Text("\(step.rowsIn) → \(step.rowsOut) rows")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(step.rowsOut < step.rowsIn ? Theme.danger : .secondary)
                                if step.cellsChanged > 0 {
                                    Text("\(step.cellsChanged) cells changed")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(Theme.amber)
                                }
                                if !step.notes.isEmpty {
                                    Text(step.notes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " · "))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    func statTile(_ label: String, _ value: String, _ icon: String) -> some View {
        GlassCard(padding: 12, glow: true) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(Theme.holo)
                    Text(label.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.title2.weight(.bold).monospacedDigit())
                    .foregroundStyle(Theme.accentGradient)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func histogramView(_ histogram: [(bucket: String, count: Int)]) -> some View {
        let maxCount = histogram.map(\.count).max() ?? 1
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(histogram.enumerated()), id: \.element.bucket) { i, entry in
                VStack(spacing: 4) {
                    Text(String(entry.count))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.accentGradient)
                        .frame(height: max(6, 120 * CGFloat(entry.count) / CGFloat(maxCount)))
                        .shadow(color: Theme.holo.opacity(0.35), radius: 8)
                        .scaleEffect(y: barsGrown ? 1 : 0.05, anchor: .bottom)
                        .animation(.spring(response: 0.55, dampingFraction: 0.75)
                            .delay(Double(i) * 0.05), value: barsGrown)
                    Text(entry.bucket)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 170)
        .onAppear { barsGrown = true }
        .onDisappear { barsGrown = false }
    }

    func abbrev(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fk", Double(n) / 1_000)
        default: return String(n)
        }
    }

    struct CleaningImpact {
        var rowsRemoved: Int?
        var dedupDropped: Int?
        var piiRedacted: Int?
        var contaminated: Int?
        var hasAny: Bool { rowsRemoved != nil || dedupDropped != nil || piiRedacted != nil || contaminated != nil }
    }

    /// Aggregate what the pipeline actually removed/redacted from provenance notes.
    func cleaningImpact(_ card: DatasetCard) -> CleaningImpact {
        var impact = CleaningImpact()
        guard let firstIn = card.pipelineSummary.first?.rowsIn,
              let lastOut = card.pipelineSummary.last?.rowsOut else { return impact }
        let net = firstIn - lastOut
        if net > 0 { impact.rowsRemoved = net }

        var dedup = 0, pii = 0, contam = 0
        for step in card.pipelineSummary {
            if step.op.hasPrefix("Dedupe") { dedup += max(0, step.rowsIn - step.rowsOut) }
            if step.op.hasPrefix("Redact") {
                for (_, v) in step.notes { pii += Int(v) ?? 0 }
            }
            if step.op.hasPrefix("Decontaminate") { contam += Int(step.notes["contaminated"] ?? "0") ?? 0 }
        }
        if dedup > 0 { impact.dedupDropped = dedup }
        if pii > 0 { impact.piiRedacted = pii }
        if contam > 0 { impact.contaminated = contam }
        return impact
    }
}
