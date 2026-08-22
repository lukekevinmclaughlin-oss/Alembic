import Foundation
import StoreKit

@MainActor
final class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()

    // These must match the product IDs configured in App Store Connect exactly. They
    // previously read "com.lukemclaughlin.alembic.monthly", which does not exist, so
    // Product.products(for:) always came back empty: the paywall fell through to a
    // hardcoded price and a hardcoded "one week free" claim that belonged to no real
    // product, and every purchase failed. That mismatch is what Guideline 3.1.2(c) /
    // 5.6 flagged as marketing a "trial" that isn't what the user actually buys.
    static let monthlyID = "com.lukemclaughlin.alembic.pro.monthly"
    static let annualID = "com.lukemclaughlin.alembic.pro.annual"
    static var productIDs: [String] { [monthlyID, annualID] }

    @Published private(set) var hasAccess = false
    @Published private(set) var product: Product?
    @Published private(set) var annualProduct: Product?
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

    /// Nil until StoreKit answers. The paywall must not invent a price.
    var price: String? { product?.displayPrice }

    /// The monthly product's introductory offer, if the user is eligible for one.
    private var introOffer: Product.SubscriptionOffer? {
        guard let sub = product?.subscription, isEligibleForIntro else { return nil }
        return sub.introductoryOffer
    }

    @Published private(set) var isEligibleForIntro = false

    /// True only when the introductory offer is genuinely free. A discounted — but
    /// still paid — introductory price must never be described as a "trial".
    var hasFreeTrial: Bool { introOffer?.paymentMode == .freeTrial }

    /// Human wording for the offer, derived from StoreKit rather than hardcoded.
    var offerSummary: String? {
        guard let price else { return nil }
        guard let offer = introOffer else { return "\(price) per month" }
        let period = Self.describe(offer.period)
        switch offer.paymentMode {
        case .freeTrial:
            return "\(period) free, then \(price) per month"
        case .payAsYouGo:
            return "\(offer.displayPrice) per month for \(period), then \(price) per month"
        case .payUpFront:
            return "\(offer.displayPrice) for \(period), then \(price) per month"
        default:
            return "\(price) per month"
        }
    }

    /// Label for the purchase button — only says "free trial" when it really is one.
    var purchaseButtonTitle: String {
        hasFreeTrial ? "Start Free Trial" : "Subscribe"
    }

    /// Guideline 3.1.2(c) terms block. Describes the introductory offer honestly:
    /// a discounted-but-paid intro price is never called a trial.
    var termsSummary: String {
        let renewal = "It renews automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in your Apple Account settings."
        guard let price else {
            return "Alembic Pro is an auto-renewing monthly subscription. \(renewal)"
        }
        guard let offer = introOffer else {
            return "Alembic Pro is an auto-renewing monthly subscription of \(price). \(renewal)"
        }
        let period = Self.describe(offer.period).lowercased()
        switch offer.paymentMode {
        case .freeTrial:
            return "Alembic Pro is an auto-renewing monthly subscription of \(price), starting after a \(period) free trial. \(renewal)"
        case .payAsYouGo:
            return "Alembic Pro is an auto-renewing monthly subscription. It starts at an introductory price of \(offer.displayPrice) per month for \(period), then continues at \(price) per month. This introductory period is discounted, not free. \(renewal)"
        case .payUpFront:
            return "Alembic Pro is an auto-renewing monthly subscription. It starts with an introductory payment of \(offer.displayPrice) for \(period), then continues at \(price) per month. This introductory period is discounted, not free. \(renewal)"
        default:
            return "Alembic Pro is an auto-renewing monthly subscription of \(price). \(renewal)"
        }
    }

    private static func describe(_ period: Product.SubscriptionPeriod) -> String {
        let n = period.value
        let unit: String
        switch period.unit {
        case .day:   unit = n == 1 ? "day" : "days"
        case .week:  unit = n == 1 ? "week" : "weeks"
        case .month: unit = n == 1 ? "month" : "months"
        case .year:  unit = n == 1 ? "year" : "years"
        @unknown default: unit = "period"
        }
        return n == 1 ? "One \(unit)" : "\(n) \(unit)"
    }

    func refresh() async {
        do {
            let products = try await Product.products(for: Self.productIDs)
            product = products.first { $0.id == Self.monthlyID }
            annualProduct = products.first { $0.id == Self.annualID }
        } catch {
            product = nil
            annualProduct = nil
        }
        if let sub = product?.subscription {
            isEligibleForIntro = await sub.isEligibleForIntroOffer
        } else {
            isEligibleForIntro = false
        }
        await updateEntitlement()
    }

    func purchase() async {
        guard let product else {
            lastError = "The subscription is temporarily unavailable. Please try again."
            return
        }
        do {
            switch try await product.purchase() {
            case .success(let result):
                let transaction = try checkVerified(result)
                await transaction.finish()
                await updateEntitlement()
            case .pending: lastError = "Your purchase is pending approval."
            case .userCancelled: break
            @unknown default: break
            }
        } catch { lastError = error.localizedDescription }
    }

    func restore() async {
        do { try await AppStore.sync(); await updateEntitlement() }
        catch { lastError = error.localizedDescription }
    }

    private func updateEntitlement() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               Self.productIDs.contains(transaction.productID),
               transaction.revocationDate == nil,
               (transaction.expirationDate ?? .distantFuture) > Date() { active = true }
        }
        #if DEBUG
        active = active || ProcessInfo.processInfo.environment["ALEMBIC_DEMO"] == "1"
        #endif
        #if DIRECT_DISTRIBUTION
        active = true
        #endif
        hasAccess = active
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
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

    enum StoreError: Error { case failedVerification }
}
