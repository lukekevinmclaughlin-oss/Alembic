# Alembic for Windows — local release candidate

Alembic prepares local datasets for training and retrieval. This Windows edition lives under `windows/` in the existing Alembic repository; the original macOS application and engine remain unchanged. The candidate is fully unlocked for a one-time purchase and contains no subscription, StoreKit or activation-code dependency.

The installer and portable package are unsigned local candidates, not yet published for sale. Supported target: Windows 10/11 x64.

## Included workflows

- Five workspace screens: Pipeline, Preview & diff, Report, Export and Settings, with Abyss, Daylight and system appearance.
- CSV/TSV, lossless JSON/JSONL, plain text, Markdown, HTML and SQLite table/view imports. Folder imports combine supported documents with a source-file column. Strict decoding, malformed-line quarantine and import assumptions are reported.
- 21 operation types: column selection/removal/renaming/computation, row expressions, normalization, null unification, type inference/conversion, exact and approximate near-duplicate removal, PII patterns, quality/language filters, evaluation-text overlap, token/language/quality enrichment, RAG chunking, seeded partitions and optional augmentation.
- Editable ordered steps, enable/disable, duplicate, reorder, Undo/Redo, four presets and Mac-shaped recipe import/export. Editing the pipeline makes prior full results stale until rerun.
- Typed, searchable and sortable 40-row pages; sampled cell changes, added columns, removed row inspection, full cell values, column profiles, full-run provenance, token histograms and heuristic language summaries.
- Eight export schemas: Alpaca, OpenAI messages, Anthropic turns, ChatML, DPO, completion, corpus and RAG chunks. Mapping validation and separate quarantines retain invalid rows and reasons. Raw JSON/JSONL preserve exact numbers; CSV optionally protects spreadsheet formulas. Partition exports, dataset cards and complete workspace backups are included.
- Five optional augmentation workflows: Q&A, quality judging, rewriting, classification and rejected-response generation. Offline demonstrations are explicitly labelled. Hosted providers and local Ollama/LM Studio require session enablement and per-step approval of uncached requests. Completed responses are checkpointed serially and reused; failed network requests are not automatically retried. No provider charges or models are included.

## Storage and limits

Desktop workspace snapshots use Brotli + AES-256-GCM with a random key protected by Windows DPAPI. Provider keys use separate Windows-protected storage. A previous snapshot is retained for recovery. Readable exported JSON backups contain datasets and generated responses, but never API keys. Keep the Windows profile and its protected key; encrypted files alone cannot be decrypted under another Windows account.

Text input is limited to 32 MiB, 50,000 rows, 200 columns, five million cells and one million UTF-16 characters per cell. The pipeline accepts 100 steps. Folder imports allow 2,000 supported files / 32 MiB combined input and 32 nested levels. SQLite database/WAL files are each limited to 256 MiB, copied to a stable private snapshot and read in a separate process with a 35-second deadline; snapshots are removed after completion or cancellation. Links, junctions and network paths are refused. Workspaces are limited to 256 MiB before compression.

The real bundled cl100k tokenizer runs offline. Its token IDs are checked against 269 deterministic fixtures from the official OpenAI tokenizer, including Unicode, whitespace and long-token cases. Special-token-looking strings are treated as ordinary text. No model files or Git LFS downloads are required.

Near-duplicate candidate recall is approximate. PII patterns are not complete anonymization; hashes are stable unsalted pseudonyms. Language and quality scores are heuristics, not probabilities or factual verification. Shared scripts can return `und`. Generated examples need human review. Windows seeded partition assignments may differ from Swift while remaining repeatable in this engine.

## Build and verification

Use the pinned lockfile with Node.js, pnpm and cached Electron 39.8.10. `pnpm install --offline`, `pnpm test`, `pnpm run package:win` and `scripts/build-installer.ps1` build locally with publishing disabled. The installer is per-user and removes only packaged files; unrelated files and saved workspaces remain.

Native verification scripts run in Electron: `scripts/verify-sqlite.cjs`, `scripts/verify-windows-encryption.cjs`, `scripts/verify-native-engine.cjs` and `scripts/verify-packaged.cjs`. Launch with a waiting process wrapper on Windows. Do not use `ELECTRON_RUN_AS_NODE` for scripts that need `app`, `safeStorage` or `utilityProcess`. Reports and installer hashes accompany the candidate.

Completed checks cover the processing engine, byte-BPE reference fixtures, guarded native commands, actual Windows encryption/recovery, actual isolated SQLite, interruption/checkpoint recovery, ASAR contents and browser interaction with the shared interface. Tests use synthetic data and mock provider responses; no live AI requests were made. Native application windows, Windows file dialogs, the provider approval dialog, live providers, clean-machine installation and code signing remain release gates. Browser preview storage is IndexedDB and is explicitly labelled; it does not provide desktop encryption.

GitHub Actions must be disabled and verified disabled before any source push. Build and distribution must stay local / Railway. Do not use GitHub Actions, LFS transfers or Releases uploads for this rollout.

## Third-party components

Electron and its Chromium/Node dependencies retain their bundled license notices. OpenAI tiktoken vocabulary attribution and its MIT license are in `resources/notices/TIKTOKEN-LICENSE.txt`; provenance is in `content/tokenizer-provenance.json`. Unicode language profiles and normalization behavior derive from the original Alembic source, with SHA-256 provenance for the untouched macOS files in `content/provenance.json`.

Utility processes follow the [Electron utilityProcess API](https://www.electronjs.org/docs/latest/api/utility-process). Optional provider adapters expose configurable supported endpoints; current provider model access and billing are determined by the user's own account.
