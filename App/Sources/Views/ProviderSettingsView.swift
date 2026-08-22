import SwiftUI
import AlembicEngine
#if !DIRECT_DISTRIBUTION
import StoreKit
#endif

/// BYO-key provider settings. Any provider, user's own key, stored in Keychain.
/// The deterministic pipeline never needs any of this.
struct ProviderSettingsView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var purchase: PurchaseManager
    @State private var testResult: String?
    @State private var testing = false
    @State private var showPaywall = false
    #if !DIRECT_DISTRIBUTION
    @State private var showManageSubscriptions = false
    #endif

    var body: some View {
        @Bindable var model = model
        return ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        #if DIRECT_DISTRIBUTION
                        CardHeader(icon: "checkmark.seal.fill",
                                   title: "Alembic Direct edition",
                                   subtitle: "Every deterministic and LLM-assisted workflow is permanently unlocked with no subscription.")
                        Text("One-time website purchase. No account, in-app purchase, renewal, or restore step.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        #else
                        CardHeader(icon: purchase.hasAccess ? "checkmark.seal.fill" : "sparkles",
                                   title: purchase.hasAccess ? "Alembic Pro active" : "Alembic Free",
                                   subtitle: purchase.hasAccess ? "LLM-assisted enrichment is unlocked on this Apple Account." : "The deterministic pipeline is free. Upgrade only when you want LLM-assisted enrichment.")
                        HStack {
                            if !purchase.hasAccess {
                                Button("Try Premium") { showPaywall = true }
                                    .buttonStyle(DistillButtonStyle())
                            }
                            Button("Restore Purchases") { Task { await purchase.restore() } }
                                .buttonStyle(DistillButtonStyle(prominent: false))
                            #if os(iOS)
                            Button("Manage Subscription") { showManageSubscriptions = true }
                                .buttonStyle(DistillButtonStyle(prominent: false))
                            #else
                            Link("Manage Subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                                .buttonStyle(DistillButtonStyle(prominent: false))
                            #endif
                        }
                        if let expiration = purchase.entitlementExpirationDate, purchase.hasAccess {
                            Text("Current entitlement through \(expiration.formatted(date: .abbreviated, time: .omitted)). Renewal and cancellation are managed by Apple.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        #endif
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader(icon: "brain", title: "LLM provider (optional)",
                                   subtitle: "Only used by LLM augmentation steps. Demo mode runs them on device with no key; or bring your own key for any provider. The core pipeline is fully offline either way.")
                        Picker("Provider", selection: $model.providerConfig.kind) {
                            ForEach(ProviderConfig.Kind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        if model.providerConfig.kind == .demo {
                            Text("Demo mode needs no API key, no account, and no network. Every augmentation step — Q&A generation, LLM-as-judge scoring, rewriting, classification, and DPO pairs — runs on device and produces reproducible output, so you can try the full pipeline before connecting a provider. Switch to a real provider above for production results.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            HStack(spacing: 8) {
                                TextField("Model (e.g. claude-haiku-4-5-20251001, gpt-4o-mini, llama3)",
                                          text: $model.providerConfig.model)
                                    .textFieldStyle(.roundedBorder)
                                Menu {
                                    ForEach(suggestedModels(for: model.providerConfig.kind), id: \.self) { m in
                                        Button(m) { model.providerConfig.model = m }
                                    }
                                } label: {
                                    Image(systemName: "list.bullet")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Common models")
                            }
                            if model.providerConfig.kind == .openaiCompatible {
                                TextField("Base URL (e.g. http://localhost:11434/v1)",
                                          text: $model.providerConfig.baseURL)
                                    .textFieldStyle(.roundedBorder)
                                    #if os(iOS)
                                    .autocapitalization(.none)
                                    #endif
                            }
                            SecureField("API key (stored in Keychain only)", text: $model.apiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading) {
                            Text("Temperature: \(String(format: "%.1f", model.providerConfig.temperature))")
                                .font(.caption)
                            Slider(value: $model.providerConfig.temperature, in: 0...1, step: 0.1)
                        }
                        HStack {
                            Button {
                                testConnection()
                            } label: {
                                if testing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("Test Connection", systemImage: "bolt.fill")
                                }
                            }
                            .buttonStyle(DistillButtonStyle(prominent: false))
                            .disabled(testing)
                            if let testResult {
                                Text(testResult)
                                    .font(.caption)
                                    .foregroundStyle(testResult.hasPrefix("✓") ? Theme.distilledTeal : Theme.danger)
                                    .lineLimit(2)
                            }
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader(icon: "dollarsign.circle", title: "Cost estimation prices",
                                   subtitle: "used for the pre-run cost estimate on LLM steps")
                        HStack {
                            Text("Input $/MTok")
                            Spacer()
                            TextField("", value: $model.priceInputPerMTok, format: .number)
                                .frame(width: 90)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("Output $/MTok")
                            Spacer()
                            TextField("", value: $model.priceOutputPerMTok, format: .number)
                                .frame(width: 90)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeader(icon: "sparkles", title: "Appearance")
                        Toggle(isOn: $model.reduceMotionOverride) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Reduce animations")
                                Text("Stills the aurora background and holographic hero. The system Reduce Motion setting is always honored too.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        CardHeader(icon: "info.circle", title: "About Alembic")
                        Text("Alembic distills messy datasets into LLM-grade training data and RAG corpora. The engine is deterministic and fully offline: cleaning, dedup, real BPE tokenization, chunking, PII redaction, quality filtering, decontamination, and schema shaping never touch the network. Pipelines are recipes — save them, share them, replay them byte-identically.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Tokenizer: \(TokenizerProvider.current.name)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Settings")
        #if !DIRECT_DISTRIBUTION
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(purchase)
        }
        #if os(iOS)
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        #endif
        #endif
    }

    func suggestedModels(for kind: ProviderConfig.Kind) -> [String] {
        switch kind {
        case .demo:
            return []
        case .anthropic:
            return ["claude-haiku-4-5-20251001", "claude-sonnet-5", "claude-opus-4-8"]
        case .openai:
            return ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "o4-mini"]
        case .openaiCompatible:
            return ["llama3.1", "qwen2.5", "mistral", "gemma2", "phi3"]
        }
    }

    func testConnection() {
        testing = true
        testResult = nil
        let client = LLMClientFactory.make(config: model.providerConfig, apiKey: model.apiKey)
        Task {
            do {
                let reply = try await client.complete(system: nil, user: "Reply with the single word: ready", maxTokens: 16)
                await MainActor.run {
                    testResult = "✓ \(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))"
                    testing = false
                }
            } catch {
                await MainActor.run {
                    testResult = error.localizedDescription
                    testing = false
                }
            }
        }
    }
}
