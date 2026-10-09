# Changelog

## 0.3.0-preview.1

- Accepts a `staging` environment in the public configuration with the environment-scoped manifest path; verification keeps exact equality with the signed payload.
- Validates the additive `variantSchemaVersion: 1` extension: declared appearance and arm values, no duplicate coordinates, cell images checked like slot images, cell states ignored. Unknown keys remain ignored.
- Resolves appearance and arm cells in the fixed order arm plus appearance, arm only, appearance only, then the legacy cell, never borrowing across arms; `ResolvedAsset` reports `appearance`, `arm`, and `armSource`; cache entries key on the selected cell.
- Adds an optional `decide` callback for the arm, evaluated outside the client gate with a bounded wait; invalid results resolve control and say why; the client re-resolves against current durable state afterwards.
- Derives the storage namespace from origin, org, app, and environment only, with a one-time verified migration from the previous formula, so the replay floor and cache survive the legacy to environment URL switch and pinned key-set changes. Accepts a pinned key set.
- `AssetImageStore` carries an appearance and per-reference arm overrides.

Validation: 48 Swift tests in 5 suites on macOS against the shared corpus of 100 signed manifest cases and 18 resolution entries.

## 0.2.0-preview.1

- Supports signed `renditionSchemaVersion: 1` metadata alongside the required legacy WebP slot. Existing 0.1.0-preview.2 clients continue using that slot; no signing key or release-sequence reset is required.
- Selects PNG/WebP rasters from explicit physical pixel targets. Without a target, logical placement dimensions remain the default. Every candidate is verified against its signed length/hash, actual native image type, and exact declared dimensions before use.
- Returns actual MIME, pixel size, asset ID, hash, and rendered release in `ResolvedAsset`. `AssetImageStore.refresh` accepts targets while generated accessors continue returning ordinary SwiftUI `Image` values.
- Validates known SVG metadata but skips SVG at runtime. This release uses server-generated raster fallbacks and does not implement native vector rendering.
- Advances through invalid/unavailable renditions and the legacy fallback before trying older verified cache entries. Historical releases remain cache-only. Existing `.webp` caches are readable; new entries use format-neutral filenames.
- Preserves signed state verification, exact-byte equivocation protection, durable storage locking, bounded transfers, and bundled fallbacks.

Validation: 17 executed Swift tests passed on macOS, plus one optional hosted test disabled by default; 65 shared signed-manifest cases and four shared target selections run within that suite. Native ImageIO PNG/WebP decoding, exact dimensions, cache migration, offline restart, candidate failure, and SwiftUI store target propagation are covered. Two code-generation tests and a release build passed. The iOS demo compiled against a local SDK override for generic iOS and iOS Simulator. This is compilation and macOS runtime evidence; it does not establish native iPhone UI execution or hosted PNG publication.
