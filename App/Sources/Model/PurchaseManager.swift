import Foundation
import StoreKit

@MainActor
final class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()

    static let monthlyID = "com.lukemclaughlin.alembic.pro.monthly"
    static let annualID = "com.lukemclaughlin.alembic.pro.annual"
    static let productIDs = [monthlyID, annualID]

    @Published private(set) var hasAccess = false
    @Published private(set) var products: [Product] = []
    @Published private(set) var introEligibleIDs: Set<String> = []
    @Published private(set) var entitlementExpirationDate: Date?
    @Published private(set) var isLoading = true
    @Published var selectedProductID = annualID
    @Published var lastError: String?

    private var updatesTask: Task<Void, Never>?

    private init() {
        #if DEBUG
        hasAccess = ProcessInfo.processInfo.environment["ALEMBIC_DEMO"] == "1"
        #endif
        #if DIRECT_DISTRIBUTION
        hasAccess = true
        #endif
        updatesTask = listenForTransactions()
        Task { await refresh() }
    }

    deinit { updatesTask?.cancel() }

    var monthlyProduct: Product? { product(id: Self.monthlyID) }
    var annualProduct: Product? { product(id: Self.annualID) }
    var selectedProduct: Product? { product(id: selectedProductID) }

    func product(id: String) -> Product? {
        products.first { $0.id == id }
    }

    func refresh() async {
        isLoading = true
        lastError = nil
        do {
            products = try await Product.products(for: Self.productIDs)
                .sorted { lhs, rhs in
                    if lhs.id == Self.annualID { return true }
                    if rhs.id == Self.annualID { return false }
                    return lhs.price < rhs.price
                }
            var eligible = Set<String>()
            for product in products {
                if let subscription = product.subscription,
                   await subscription.isEligibleForIntroOffer,
                   subscription.introductoryOffer?.paymentMode == .freeTrial {
                    eligible.insert(product.id)
                }
            }
            introEligibleIDs = eligible
            if product(id: selectedProductID) == nil, let first = products.first {
                selectedProductID = first.id
            }
            if products.count != Self.productIDs.count {
                lastError = "Some subscription options are temporarily unavailable. Please try again shortly."
            }
        } catch {
            products = []
            introEligibleIDs = []
            lastError = "Subscriptions could not be loaded. Check your connection and try again."
        }
        await updateEntitlement()
        isLoading = false
    }

    func hasFreeTrial(_ product: Product) -> Bool {
        introEligibleIDs.contains(product.id)
            && product.subscription?.introductoryOffer?.paymentMode == .freeTrial
    }

    func offerSummary(for product: Product) -> String {
        let cadence = product.id == Self.annualID ? "year" : "month"
        guard hasFreeTrial(product),
              let offer = product.subscription?.introductoryOffer else {
            return "\(product.displayPrice) per \(cadence)"
        }
        return "\(Self.describe(offer.period)) free, then \(product.displayPrice) per \(cadence)"
    }

    func termsSummary(for product: Product) -> String {
        let cadence = product.id == Self.annualID ? "annual" : "monthly"
        let period = product.id == Self.annualID ? "year" : "month"
        let renewal = "Renews automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in Apple Account settings."
        if hasFreeTrial(product), let offer = product.subscription?.introductoryOffer {
            return "Alembic Pro is an auto-renewing \(cadence) subscription of \(product.displayPrice) per \(period), beginning after a \(Self.describe(offer.period).lowercased()) free trial. \(renewal)"
        }
        return "Alembic Pro is an auto-renewing \(cadence) subscription of \(product.displayPrice) per \(period). \(renewal)"
    }

    var purchaseButtonTitle: String {
        guard let selectedProduct else { return "Subscribe" }
        return hasFreeTrial(selectedProduct) ? "Start Free Trial" : "Subscribe"
    }

    func purchaseSelected() async {
        guard let product = selectedProduct else {
            lastError = "The selected subscription is temporarily unavailable. Please try again."
            return
        }
        lastError = nil
        do {
            switch try await product.purchase() {
            case .success(let result):
                let transaction = try checkVerified(result)
                await transaction.finish()
                await updateEntitlement()
            case .pending:
                lastError = "Your purchase is pending approval. Premium will unlock automatically after approval."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch StoreError.failedVerification {
            lastError = "The App Store receipt could not be verified. You were not granted Premium access."
        } catch {
            lastError = error.localizedDescription
        }
    }

    func restore() async {
        lastError = nil
        do {
            try await AppStore.sync()
            await updateEntitlement()
            if !hasAccess {
                lastError = "No active Alembic Pro subscription was found for this Apple Account."
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func updateEntitlement() async {
        var active = false
        var latestExpiration: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            let expiration = transaction.expirationDate ?? .distantFuture
            guard expiration > Date() else { continue }
            active = true
            if latestExpiration == nil || expiration > latestExpiration! {
                latestExpiration = transaction.expirationDate
            }
        }
        #if DEBUG
        active = active || ProcessInfo.processInfo.environment["ALEMBIC_DEMO"] == "1"
        #endif
        #if DIRECT_DISTRIBUTION
        active = true
        #endif
        hasAccess = active
        entitlementExpirationDate = latestExpiration
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
                await self?.updateEntitlement()
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified: throw StoreError.failedVerification
        }
    }

    private static func describe(_ period: Product.SubscriptionPeriod) -> String {
        let value = period.value
        let unit: String
        switch period.unit {
        case .day: unit = value == 1 ? "day" : "days"
        case .week: unit = value == 1 ? "week" : "weeks"
        case .month: unit = value == 1 ? "month" : "months"
        case .year: unit = value == 1 ? "year" : "years"
        @unknown default: unit = "period"
        }
        return value == 1 ? "One \(unit)" : "\(value) \(unit)"
    }

    enum StoreError: Error { case failedVerification }
}
