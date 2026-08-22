# App Review Notes — Alembic 1.1

Alembic requires no account or sign-in. The deterministic data pipeline is free and works locally.

## Fast review path

1. Launch Alembic.
2. Tap **Try with sample data**. If the optional Pro introduction is visible, tap **Continue Free** first.
3. Tap **Run** in the top-right corner.
4. The completed dataset report opens automatically. Preview and Export are available from the sidebar.

## Subscription path

1. On the first screen, tap **Try Premium** in the Alembic Pro card.
2. The paywall displays both **Annual** and **Monthly** products, each loaded directly from StoreKit with the reviewer’s localized price and introductory-offer eligibility.
3. The primary button says **Start Free Trial** only when StoreKit reports that the current Apple Account is eligible for the configured free trial; otherwise it says **Subscribe**.
4. **Continue Free**, **Restore Purchases**, **Manage Subscription**, Terms of Use, and Privacy Policy are visible on the paywall.

The subscription can also be reached after experiencing value: add any **LLM Augment** step to the sample pipeline and tap **Run**. Non-subscribers are shown the same optional paywall and can choose **Continue Free** without losing their project. On iOS, Settings opens Apple’s native subscription-management sheet; on macOS it opens Apple’s subscription-management page.

Products:

- Monthly: `com.lukemclaughlin.alembic.pro.monthly`
- Annual: `com.lukemclaughlin.alembic.pro.annual`

Purchases use StoreKit 2 verification. Current entitlements are rechecked at launch, after purchase/restore, and on every transaction update. Revoked or expired transactions do not unlock Pro. Cancellation leaves access active through the paid expiration date, as expected for an auto-renewable subscription.
