import SwiftUI
import AlembicEngine
import StoreKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var purchase: PurchaseManager
    @Environment(\.requestReview) private var requestReview
    @State private var showPaywall = false

    var body: some View {
        Group {
            if model.hasProject {
                workspace
            } else {
                WelcomeView()
            }
        }
        .background(AuroraBackground(animated: !model.reduceMotionOverride))
        .preferredColorScheme(.dark)
        .onAppear { applyDebugLaunchHooks() }
        .onOpenURL { url in
            // "Open With Alembic" / drag onto dock icon
            model.importFile(url: url)
        }
        .sheet(item: sqliteBinding) { pending in
            SQLiteTablePickerSheet(pending: pending)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(purchase)
        }
        .onChange(of: model.completedRunCount) { _, _ in
            guard ReviewPromptPolicy.recordSuccessfulRun() else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { requestReview() }
        }
    }

    var sqliteBinding: Binding<AppModel.PendingSQLite?> {
        Binding(get: { model.pendingSQLite }, set: { model.pendingSQLite = $0 })
    }

    /// Debug/automation hooks — inert unless the env vars are set.
    /// ALEMBIC_OPEN=<path> auto-imports a file; ALEMBIC_SCREEN=<name> jumps to a
    /// screen; ALEMBIC_AUTORUN=1 runs the full pipeline after import.
    private func applyDebugLaunchHooks() {
        let env = ProcessInfo.processInfo.environment
        if env["ALEMBIC_SAMPLE"] == "1", model.original == nil {
            model.loadSampleData()
            if let preset = env["ALEMBIC_PRESET"], let p = presetFromName(preset) {
                model.applyPreset(p)
            }
            if env["ALEMBIC_AUTORUN"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.runFull() }
            }
        }
        if let path = env["ALEMBIC_OPEN"], model.original == nil {
            model.importFile(url: URL(fileURLWithPath: path))
            if env["ALEMBIC_AUTORUN"] == "1" {
                model.runFull()
            }
        }
        if let col = env["ALEMBIC_PROFILE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                model.screen = .preview
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                model.debugProfileColumn = col
            }
        }
        if let name = env["ALEMBIC_SCREEN"], let screen = AppScreen(rawValue: name) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                model.screen = screen
            }
        }
        // ALEMBIC_DISABLE="1,3" bypasses those step positions (1-based) — for verification.
        if let list = env["ALEMBIC_DISABLE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                for token in list.split(separator: ",") {
                    if let pos = Int(token.trimmingCharacters(in: .whitespaces)),
                       model.steps.indices.contains(pos - 1) {
                        model.toggleStep(id: model.steps[pos - 1].id)
                    }
                }
            }
        }
    }

    private func presetFromName(_ name: String) -> RecipePreset? {
        switch name {
        case "training": return .trainingStarter
        case "rag": return .ragStarter
        case "privacy": return .privacyScrub
        case "dedupe": return .aggressiveDedupe
        default: return nil
        }
    }

    @ViewBuilder
    var workspace: some View {
        let screenSelection = Binding<AppScreen?>(
            get: { model.screen },
            set: { if let s = $0 { model.screen = s } }
        )
        NavigationSplitView {
            List(selection: screenSelection) {
                Section {
                    ForEach(AppScreen.allCases) { screen in
                        Label(screen.title, systemImage: screen.icon)
                            .tag(screen)
                    }
                } header: {
                    projectHeader
                }
            }
            .navigationTitle("Alembic")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 195, ideal: 215)
            #endif
            .scrollContentBackground(.hidden)
            .background(.ultraThinMaterial)
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        } detail: {
            detailView
                #if os(iOS)
                .toolbar {
                    // Compact devices lose sight of the sidebar footer — keep Run reachable
                    ToolbarItem(placement: .primaryAction) {
                        if model.isRunningFull {
                            Button {
                                model.cancelFull()
                            } label: {
                                Label("Cancel", systemImage: "stop.circle.fill")
                            }
                            .accessibilityLabel("Cancel pipeline run")
                        } else {
                            Button {
                                runPipeline()
                            } label: {
                                Label("Run", systemImage: "play.fill")
                            }
                            .disabled(model.ops.isEmpty)
                            .accessibilityLabel("Run full pipeline")
                        }
                    }
                }
                #endif
        }
    }

    var projectHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: model.mode.icon)
                    .foregroundStyle(Theme.accentGradient)
                Text(model.mode.title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            Text(model.sourceName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if let flow = model.flowSummary {
                Text(flow)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.holo)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.4), value: flow)
            }
        }
        .padding(.bottom, 8)
    }

    var sidebarFooter: some View {
        VStack(spacing: 8) {
            if model.isRunningFull {
                VStack(spacing: 6) {
                    if model.hasAugmentOps || model.runFraction == 0 {
                        RunPulseView()   // augment steps have sub-step progress; keep it lively
                    } else {
                        ProgressView(value: model.runFraction)
                            .tint(Theme.holo)
                            .animation(.easeOut(duration: 0.25), value: model.runFraction)
                    }
                    Text(model.fullProgress)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .contentTransition(.numericText())
                    Button(role: .cancel) {
                        model.cancelFull()
                    } label: {
                        Label("Cancel", systemImage: "stop.fill")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DistillButtonStyle(prominent: false))
                    .accessibilityLabel("Cancel pipeline run")
                }
                .frame(maxWidth: .infinity)
            } else {
                Button {
                    runPipeline()
                } label: {
                    Label("Run Full Pipeline", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DistillButtonStyle())
                .disabled(model.ops.isEmpty)
                .accessibilityLabel("Run full pipeline")
            }
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    model.reset()
                }
            } label: {
                Label("New Project", systemImage: "plus.square.on.square")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DistillButtonStyle(prominent: false))
            .accessibilityLabel("Start a new project")
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }

    private func runPipeline() {
        if model.hasAugmentOps && !purchase.hasAccess {
            showPaywall = true
        } else {
            model.runFull()
        }
    }

    @ViewBuilder
    var detailView: some View {
        switch model.screen {
        case .pipeline: PipelineView()
        case .preview: PreviewGridView()
        case .report: ReportView()
        case .export: ExportView()
        case .settings: ProviderSettingsView()
        }
    }
}

/// Table chooser shown when a SQLite database has more than one table.
struct SQLiteTablePickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: AppModel.PendingSQLite

    var body: some View {
        NavigationStack {
            List(pending.tables, id: \.self) { table in
                Button {
                    model.importSQLite(url: pending.url, table: table)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "tablecells")
                            .foregroundStyle(Theme.accentGradient)
                        Text(table)
                            .font(.body.monospaced())
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Choose a table")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.pendingSQLite = nil
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 300)
        .preferredColorScheme(.dark)
    }
}
