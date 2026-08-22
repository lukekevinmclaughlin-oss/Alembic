import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showImporter = false
    @State private var dropHover = false
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                header
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 18)
                modeChooser
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 22)
                dropZone
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 26)
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        model.loadSampleData()
                    }
                } label: {
                    Label("Try with sample data", systemImage: "sparkles")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.holo)
                .opacity(appeared ? 1 : 0)
                .accessibilityHint("Loads a messy example dataset so you can explore the pipeline")
                if !model.recents.isEmpty {
                    recentsRow
                        .opacity(appeared ? 1 : 0)
                }
                if let err = model.previewError {
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(Theme.danger)
                }
                formats
                    .opacity(appeared ? 1 : 0)
            }
            .padding(30)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.05)) {
                appeared = true
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.data, .folder, .plainText, .json, .commaSeparatedText],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.importFile(url: url)
            }
        }
    }

    var header: some View {
        VStack(spacing: 8) {
            HoloHUDView(size: 210, animated: !model.reduceMotionOverride)
            Text("Alembic")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .shadow(color: Theme.holo.opacity(0.4), radius: 16)
            Text("Messy data in. LLM-grade essence out.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    var modeChooser: some View {
        @Bindable var model = model
        return HStack(spacing: 16) {
            ForEach(ProjectMode.allCases) { mode in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        model.mode = mode
                    }
                } label: {
                    GlassCard(glow: model.mode == mode) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: mode.icon)
                                    .font(.title2)
                                    .foregroundStyle(model.mode == mode ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.secondary))
                                Text(mode.title)
                                    .font(.headline)
                                Spacer()
                                if model.mode == mode {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.holo)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            Text(mode.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(model.mode == mode ? Theme.holo.opacity(0.7) : .clear, lineWidth: 1.5)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(mode.title) mode: \(mode.subtitle)")
            }
        }
    }

    var dropZone: some View {
        Button {
            showImporter = true
        } label: {
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.accentGradient)
                    .symbolEffect(.bounce, value: dropHover)
                Text("Drop a file or folder — or click to browse")
                    .font(.headline)
                Text("CSV · TSV · JSON · JSONL · Markdown · HTML · SQLite · plain text · code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.holo.opacity(dropHover ? 0.08 : 0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                    .foregroundStyle(dropHover ? Theme.holo : Color.white.opacity(0.25))
            )
            .shadow(color: dropHover ? Theme.holo.opacity(0.35) : .clear, radius: 24)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .animation(.easeOut(duration: 0.2), value: dropHover)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Import a data file or folder")
        .onDrop(of: [.fileURL], isTargeted: $dropHover) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    Task { @MainActor in
                        model.importFile(url: url)
                    }
                }
            }
            return true
        }
    }

    var recentsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.recents) { recent in
                        Button {
                            model.openRecent(recent)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.caption)
                                    .foregroundStyle(Theme.holo)
                                Text(recent.name)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(.ultraThinMaterial))
                            .overlay(Capsule().strokeBorder(Theme.glassEdge, lineWidth: 1))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Reopen \(recent.name)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var formats: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(icon: "sparkles", title: "What Alembic does",
                           subtitle: "A deterministic, offline distillation pipeline — every step replayable from a saved recipe.")
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        featureItem("wand.and.stars", "Clean & normalize", "Encodings, mojibake, HTML, unicode, nulls, types, dates")
                        featureItem("doc.on.doc", "Dedupe", "Exact + MinHash near-duplicate clustering")
                    }
                    GridRow {
                        featureItem("number", "Real tokenization", "cl100k BPE — budgets, counts, histograms")
                        featureItem("scissors", "Semantic chunking", "Sentence-aware, token-budgeted, heading paths")
                    }
                    GridRow {
                        featureItem("eye.slash", "PII & secrets", "Validated detection, redact / hash / drop")
                        featureItem("checkmark.shield", "Decontamination", "N-gram screening against your eval sets")
                    }
                    GridRow {
                        featureItem("square.stack.3d.up", "Training schemas", "Alpaca · OpenAI · Anthropic · ChatML · DPO")
                        featureItem("brain", "BYO-key augmentation", "Q&A synthesis, LLM-as-judge, DPO pairs — any provider")
                    }
                }
            }
        }
    }

    func featureItem(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(Theme.holo)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
