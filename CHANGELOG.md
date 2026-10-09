# Changelog

## 0.3.1-preview.1

- Accepts configurations containing only a pinned key set. The existing non-optional `pinnedPublicKey` property contains its first member; manifests signed by any member remain trusted.
- Codable encoding preserves the supplied single-pin field's presence, preventing a compatibility fallback from inflating set-only JSON past its byte limit. Explicit non-first single pins and the entire trust set survive round trips.
- Rejects explicit nulls in known configuration fields, `keyId` without an explicit single pin, and `keyIds` whose values, count, or order differ from the derived IDs. Duplicate pins, empty or oversized sets, invalid Ed25519 SPKI PEM, pins over 256 UTF-8 bytes, and JSON over 4096 bytes remain rejected. Unknown fields count toward the JSON byte limit.
- Runs the generated shared public-configuration corpus, including signature checks for the second trusted key and an untrusted key.

Validation: on October 9, 2026, `swift test` passed 52 tests across 5 suites on macOS (the optional hosted test skips without a configuration), including 43 shared public-configuration cases, 39 associated signature expectations, and the 100 existing signed manifest cases. All 4 code-generation tests and `swift build -c release` passed. No iOS simulator or device run is claimed.

## 0.3.0-preview.1

- Accepts a `staging` environment in the public configuration with the environment-scoped manifest path; verification keeps exact equality with the signed payload.
- Validates the additive `variantSchemaVersion: 1` extension: declared appearance and arm values, no duplicate coordinates, cell images checked like slot images, cell states ignored. Unknown keys remain ignored.
- Resolves appearance and arm cells in the fixed order arm plus appearance, arm only, appearance only, then the legacy cell, never borrowing across arms; `ResolvedAsset` reports `appearance`, `arm`, and `armSource`; cache entries key on the selected cell.
- Adds an optional `decide` callback for the arm, evaluated outside the client gate with a bounded wait; invalid results resolve control and say why; the client re-resolves against current durable state afterwards.
- Derives the storage namespace from origin, org, app, and environment only, with a one-time verified migration from the previous formula, so the replay floor and cache survive the legacy to environment URL switch and pinned key-set changes. Accepts a pinned key set.
- `AssetImageStore` carries an appearance and per-reference arm overrides.
- Includes the localized descriptions released as `0.2.1-preview.1`, which was tagged from a separate branch.

Validation: 48 Swift tests in 5 suites on macOS against the shared corpus of 100 signed manifest cases and 18 resolution entries.

## 0.2.1-preview.1

- Adds optional localized descriptions to verified asset results, paired with the actual remote or cached release. Historical fallback never borrows descriptions from a newer image.
- Adds `AssetAccessibility` locale selection and optional `bundledAccessibility` in offline catalogs.
- Adds native `AssetArtwork` snapshots and generated helpers while retaining native `Image` properties and app-owned labels/decoration. Informative usages can keep the bundle when a remote image has no description.
- Adds compiled decorative/informative examples, deterministic generator validation and safe string escaping.

Validation: 82 signed-manifest cases, focused cache/localization/fallback tests, four code-generation tests, and a Swift release build. Manual iOS VoiceOver acceptance is not established by these checks. This scoped release excludes unrelated animation fixture work. The tag sits on a branch that is not an ancestor of `main`; `0.3.0-preview.1` carries the same changes.

## 0.2.0-preview.1

- Supports signed `renditionSchemaVersion: 1` metadata alongside the required legacy WebP slot. Existing 0.1.0-preview.2 clients continue using that slot; no signing key or release-sequence reset is required.
- Selects PNG/WebP rasters from explicit physical pixel targets. Without a target, logical placement dimensions remain the default. Every candidate is verified against its signed length/hash, actual native image type, and exact declared dimensions before use.
- Returns actual MIME, pixel size, asset ID, hash, and rendered release in `ResolvedAsset`. `AssetImageStore.refresh` accepts targets while generated accessors continue returning ordinary SwiftUI `Image` values.
- Validates known SVG metadata but skips SVG at runtime. This release uses server-generated raster fallbacks and does not implement native vector rendering.
- Advances through invalid/unavailable renditions and the legacy fallback before trying older verified cache entries. Historical releases remain cache-only. Existing `.webp` caches are readable; new entries use format-neutral filenames.
- Preserves signed state verification, exact-byte equivocation protection, durable storage locking, bounded transfers, and bundled fallbacks.

Validation: 17 executed Swift tests passed on macOS, plus one optional hosted test disabled by default; 65 shared signed-manifest cases and four shared target selections run within that suite. Native ImageIO PNG/WebP decoding, exact dimensions, cache migration, offline restart, candidate failure, and SwiftUI store target propagation are covered. Two code-generation tests and a release build passed. The iOS demo compiled against a local SDK override for generic iOS and iOS Simulator. This is compilation and macOS runtime evidence; it does not establish native iPhone UI execution or hosted PNG publication.
