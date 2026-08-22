import SwiftUI

struct PaywallView: View {
    @EnvironmentObject private var purchase: PurchaseManager

    var body: some View {
        ZStack {
            AuroraBackground(animated: true)
            ScrollView {
                VStack(spacing: 22) {
                    HoloHUDView(size: 180, animated: true)
                    Text("Alembic Pro")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    Text("Turn messy source data into dependable training and retrieval datasets—privately, repeatably, and on device.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 620)
                    VStack(alignment: .leading, spacing: 13) {
                        benefit("wand.and.stars", "Deterministic cleaning and normalization")
                        benefit("doc.on.doc", "Exact and near-duplicate detection")
                        benefit("eye.slash", "PII, secret, and contamination screening")
                        benefit("brain", "Training and RAG pipeline recipes")
                        benefit("lock.shield", "Local processing with optional BYO providers")
                    }
                    .padding(22)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
                    // Wording comes from StoreKit, so what is described here is always
                    // the offer the user is actually charged for. "Free" appears only
                    // when the introductory offer really is a free trial.
                    Text(purchase.offerSummary ?? "Loading the current App Store offer…")
                        .font(.headline)
                    Button { Task { await purchase.purchase() } } label: {
                        Text(purchase.purchaseButtonTitle)
                            .font(.headline)
                            .frame(maxWidth: 420)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.holo)
                    .disabled(purchase.price == nil)
                    Button("Restore Purchases") { Task { await purchase.restore() } }
                        .buttonStyle(.plain)
                    if let error = purchase.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    // Guideline 3.1.2(c): show the subscription title, length, price,
                    // and FUNCTIONAL links to the Terms of Use (EULA) and Privacy Policy.
                    VStack(spacing: 6) {
                        Text(purchase.termsSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 8) {
                            Link("Terms of Use (EULA)",
                                 destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                            Text("·").foregroundStyle(.secondary)
                            Link("Privacy Policy",
                                 destination: URL(string: "https://www.lukekevinmclaughlin.com/privacy")!)
                        }
                        .font(.caption.weight(.medium))
                    }
                    .frame(maxWidth: 620)
                }
                .padding(32)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func benefit(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.body.weight(.medium))
    }
}
