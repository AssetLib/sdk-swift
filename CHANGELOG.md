# Changelog

## 0.2.0-preview.1

- Supports signed `renditionSchemaVersion: 1` metadata alongside the required legacy WebP slot. Existing 0.1.0-preview.2 clients continue using that slot; no signing key or release-sequence reset is required.
- Selects PNG/WebP rasters from explicit physical pixel targets. Without a target, logical placement dimensions remain the default. Every candidate is verified against its signed length/hash, actual native image type, and exact declared dimensions before use.
- Returns actual MIME, pixel size, asset ID, hash, and rendered release in `ResolvedAsset`. `AssetImageStore.refresh` accepts targets while generated accessors continue returning ordinary SwiftUI `Image` values.
- Validates known SVG metadata but skips SVG at runtime. This release uses server-generated raster fallbacks and does not implement native vector rendering.
- Advances through invalid/unavailable renditions and the legacy fallback before trying older verified cache entries. Historical releases remain cache-only. Existing `.webp` caches are readable; new entries use format-neutral filenames.
- Preserves signed state verification, exact-byte equivocation protection, durable storage locking, bounded transfers, and bundled fallbacks.

Validation: 17 executed Swift tests passed on macOS, plus one optional hosted test disabled by default; 65 shared signed-manifest cases and four shared target selections run within that suite. Native ImageIO PNG/WebP decoding, exact dimensions, cache migration, offline restart, candidate failure, and SwiftUI store target propagation are covered. Two code-generation tests and a release build passed. The iOS demo compiled against a local SDK override for generic iOS and iOS Simulator. This is compilation and macOS runtime evidence; it does not establish native iPhone UI execution or hosted PNG publication.
