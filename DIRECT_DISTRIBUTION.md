# Alembic Direct edition

The App Store and website editions share the data-processing engine but have separate commercial builds.

- `Release` retains StoreKit subscriptions and the sandboxed Mac App Store entitlement configuration.
- `Direct` defines `DIRECT_DISTRIBUTION`, uses bundle ID `com.lukemclaughlin.alembic.direct`, compiles out StoreKit and subscription purchase UI, and permanently unlocks every deterministic and LLM-assisted workflow.
- `scripts/build-direct.sh` produces a universal Developer ID-signed DMG, notarizes it with Apple, staples the ticket, checks Gatekeeper, and records its SHA-256 checksum.

Never publish a website installer unless every gate in the script passes.
