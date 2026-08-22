import SwiftUI

#if DIRECT_DISTRIBUTION
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AuroraBackground(animated: true)
            VStack(spacing: 20) {
                HoloHUDView(size: 136, animated: true)
                Text("Alembic Direct edition")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Every deterministic and LLM-assisted workflow is permanently unlocked. There is no subscription, account, or in-app purchase.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 600)
                Button("Continue") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.holo)
            }
            .padding(30)
        }
        .preferredColorScheme(.dark)
    }
}
#else
import StoreKit

struct PaywallView: View {
    @EnvironmentObject private var purchase: PurchaseManager
    @Environment(\.dismiss) private var dismiss
    @State private var showManageSubscriptions = false

    var body: some View {
        ZStack {
            AuroraBackground(animated: true)
            ScrollView {
                VStack(spacing: 18) {
                    HoloHUDView(size: 136, animated: true)
                    Text("Alembic Pro")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                    Text("The complete deterministic pipeline remains free. Pro unlocks LLM-assisted enrichment and advanced workflows.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 620)

                    VStack(alignment: .leading, spacing: 11) {
                        benefit("checkmark.seal", "Free forever: import, clean, dedupe, redact, chunk, preview, report, and export")
                        benefit("brain", "Pro: Q&A generation, scoring, rewriting, classification, and preference pairs")
                        benefit("lock.shield", "Local processing; optional provider credentials stay in Keychain")
                    }
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))

                    if purchase.isLoading {
                        ProgressView("Loading App Store options…")
                    } else if purchase.products.isEmpty {
                        unavailableState
                    } else {
                        planOptions
                        Button {
                            Task { await purchase.purchaseSelected() }
                        } label: {
                            Text(purchase.purchaseButtonTitle)
                                .font(.headline)
                                .frame(maxWidth: 420)
                                .padding(.vertical, 13)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.holo)

                        if let product = purchase.selectedProduct {
                            Text(purchase.termsSummary(for: product))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 620)
                        }
                    }

                    Button("Continue Free") { dismiss() }
                        .font(.headline)
                        .buttonStyle(.bordered)
                        .accessibilityHint("Dismisses this offer and continues with Alembic's free features")

                    HStack(spacing: 12) {
                        Button("Restore Purchases") { Task { await purchase.restore() } }
                        #if os(iOS)
                        Button("Manage Subscription") { showManageSubscriptions = true }
                        #else
                        Link("Manage Subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                        #endif
                    }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.medium))

                    if let error = purchase.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                            .multilineTextAlignment(.center)
                    }

                    HStack(spacing: 8) {
                        Link("Terms of Use (EULA)", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                        Text("·").foregroundStyle(.secondary)
                        Link("Privacy Policy", destination: URL(string: "https://github.com/lukekevinmclaughlin-oss/Alembic/blob/main/PRIVACY.md")!)
                    }
                    .font(.caption.weight(.medium))
                }
                .padding(28)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        #if os(iOS)
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        #endif
        .task { await purchase.refresh() }
        .onChange(of: purchase.hasAccess) { _, hasAccess in
            if hasAccess { dismiss() }
        }
    }

    private var planOptions: some View {
        VStack(spacing: 10) {
            ForEach(purchase.products, id: \.id) { product in
                Button {
                    purchase.selectedProductID = product.id
                } label: {
                    planRow(product)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func planRow(_ product: Product) -> some View {
        let selected = purchase.selectedProductID == product.id
        let annual = product.id == PurchaseManager.annualID
        return HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Theme.holo : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(annual ? "Annual" : "Monthly").font(.headline)
                    if annual {
                        Text("BEST VALUE")
                            .font(.caption2.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.holo.opacity(0.18)))
                    }
                }
                Text(purchase.offerSummary(for: product))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: 520)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? AnyShapeStyle(Theme.holo) : AnyShapeStyle(Theme.glassEdge), lineWidth: 1.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private var unavailableState: some View {
        VStack(spacing: 10) {
            Text("App Store options are temporarily unavailable.")
                .font(.headline)
            Button("Try Again") { Task { await purchase.refresh() } }
                .buttonStyle(.bordered)
        }
    }

    private func benefit(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.body.weight(.medium))
    }
}
#endif
