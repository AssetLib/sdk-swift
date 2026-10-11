# Changelog

## 0.6.0-preview.1 — October 11, 2026

Implements the shared contract revision of October 11, 2026 (placement membership).

- Fixes images that a console Restore could not take back. When the latest accepted release has no slot with a placement's key, for example after restoring a publication that predates the placement, `resolve` now returns the bundled image (`source == .bundle`, message "Using bundled artwork. The current release does not publish this placement.") without reading the cache, making a request or looking at older releases. Before, it kept serving bytes cached from an older retained release until that release left the eight-release history. An app that updates the SDK may see such a placement switch to its bundled image on the first resolve. Apps on `0.5.0-preview.1` and earlier keep the old behavior until they ship an app release with this version; nothing on the server changes it.
- Only a missing key changes. A key the current release publishes at other dimensions or with another rendering, and a current image that can't be downloaded or verified, still fall back to compatible cached bytes from older retained releases, newest first, then to the bundled image; older releases are never fetched. Cached bytes are not deleted, so publishing the same image again is a cache hit. The arm decision is unchanged: with no slot the callback is not called, and an explicit arm keeps `armSource == .explicit`. `resolveVideo` already returned the poster when the current release has no clip for the placement; that placement's still image is now the bundled image too.
- No public API, wire format or storage change. `AssetStorage` and `AssetTransport` gain no requirements.
- Vendors the shared corpus revision of October 11, 2026: 7 new signed manifests (149 manifest cases) and `history.json` with 10 release-history cases, run by the new `HistoryTests`.

Validation: on October 11, 2026 on macOS, `swift test` passed 76 tests in 9 suites (75 passed, the optional hosted test skipped), including all 149 signed manifest cases and the 10 `history.json` cases, each also checked for its request count, requests only to the latest release, and unchanged durable state and cache. Before the fix, exactly `removed-key-online`, `removed-key-offline` and `video-placement-removed-poster-image-is-bundled` failed; with the check temporarily widened to compare dimensions, the control case `present-other-dimensions-uses-history` failed. All 7 code-generation tests and `swift build -c release` passed, `xcodebuild` built the package for the iOS Simulator SDK, and `check-copy.mjs` found the corpus identical. These are macOS unit tests and builds; no simulator, device or hosted run is claimed.

Validation (release commit): on October 11, 2026 on macOS (Apple Swift 6.4, Xcode 27.0), on a fresh clone of `main` at `fa5e828` with this commit's version strings, `swift test` passed 76 tests in 9 suites (75 passed, the optional hosted test skipped), `python3 scripts/test_codegen.py` ran 7 tests OK, `swift build -c release` completed including `AssetLibExample`, and `check-copy.mjs` found the corpus identical (235/235 files). macOS unit tests and builds only.

## 0.5.0-preview.1 — October 11, 2026

- Fixes the catalog generator rejecting valid `fallbackImageName` values. It now accepts `/` between the folder and image names that Xcode uses for asset-catalog folders with "Provides Namespace" (`illustration/home-hero`, as `Image(_:bundle:)` expects), and single spaces inside a name. Leading or trailing `/` or spaces, empty segments, repeated spaces, quotes, backslashes, control and non-ASCII characters, and names over 120 characters are still rejected. Catalogs that were already valid generate byte-identical output.
- Rejects any `fallbackImageName` segment that starts with `.`, so `../x`, `a/../b`, `./x` and `a/./b` cannot reach `Image(decorative:bundle:)`, whose lookup outside an asset catalog resolves bundle-relative paths. This also tightens the previous rule: a single-segment name starting with `.` (such as `.hidden` or `..`) was accepted before and is now an error. Asset-catalog names never start with `.`.
- Writes placement keys and fallback image names through the same Swift string escaping as descriptions, so the generated literals stay safe even if validation changes. Every valid catalog generates byte-identical output.

Validation: on October 10, 2026, all 7 code-generation tests, `swift test` (57 tests in 6 suites, the optional hosted test skipped) and `swift build -c release` passed on macOS. The checked-in example catalog and an extended catalog with namespaced and spaced names generate the same bytes as the generator before these changes.

- Adds short looping video (LOOPING-VIDEO-CONTRACT.md). Decodes `videoSchemaVersion` and the base slot's `video` descriptor. Rejects the manifest for a version other than 1 (including null), a `video` without the version, a slot with both `animation` and `video`, a `video` on a variant cell, and any descriptor outside the `h264-loop-v1` rules: format, profile, MIME, lowercase hash, 1–4,194,304 bytes, even 16–1280 dimensions of at most 921,600 pixels in the slot's exact aspect ratio, integer 1,000–10,000 ms, finite 1–30 fps, and the exact same-origin `/videos/{sha256}` path. Swift ignored both fields before. Apps that don't call `resolveVideo` are otherwise unaffected.
- Adds `AssetClient.resolveVideo(_:)` returning `AssetVideo` (`fileURL`, `width`, `height`, `duration`, `frameRate`, `source` `.remote`/`.cache`/`.poster`, `sequence`, `message`). Only the current release downloads; if it has no clip the result is the poster; an unusable current clip falls back to verified cached clips from older releases, newest first, then the poster. Clips are verified by length, SHA-256 and a bounded MP4 header walk, and stored as `<hash>.mp4` with `FileAssetStorage`, excluded from backup and inside the existing cache budget; an unreadable cached clip of the current release is downloaded again. `resolve` never downloads a clip.
- Adds the `AssetLoopingVideo` SwiftUI view (muted `AVQueuePlayer` and `AVPlayerLooper` in an `AVPlayerLayer`, no controls). It shows the poster until the first frame, under Reduce Motion, on a player error, off screen, in the background, and when two clips already play.
- `HTTPSAssetTransport(timeout:videoTimeout:)` adds a separate `video/mp4` deadline (default 30 s, at most 30 s) and a 4 MiB cap for `video/mp4` requests; `AssetLimits.videoBytes` is 4 MiB. Every download now appends in 64 KiB chunks instead of byte by byte, with the same byte limit checked per byte. `AssetTransport` and `AssetStorage` gain no requirements.
- Vendors the shared corpus with 27 new signed video manifests (2 accepted, 25 rejected), `video.json` and three MP4 assets.

Validation (short looping video): on October 10, 2026 on macOS, `swift test` passed 73 tests in 8 suites (72 passed, the optional hosted test skipped), including all 142 signed manifest cases and the `video.json` cases; with each new rule temporarily broken (history download, header check, video deadline, Reduce Motion, two-player cap, poster for a release without a clip, older-release skipping, per-byte limit, re-download over an unreadable cached clip), a video test failed. A cached clip loaded with `AVURLAsset` reports 2.0 s and a 320×240 video track. All 7 code-generation tests and `swift build -c release` passed, `xcodebuild` built the package for the iOS Simulator SDK, and `check-copy.mjs` found the corpus identical. No simulator, device or hosted run is claimed; gapless looping is not established.

## 0.4.0-preview.1

- Adds tintable icons. `AssetRendering` (`.original`, `.template`) and `AssetReference(key:width:height:rendering:)`, defaulting to `.original`, so existing references and generated code compile unchanged. `AssetReference` Codable reads values without `rendering` as original and omits it when original.
- Decodes the optional signed `rendering` field on slots and variant cells. Null, non-string, or values not matching `^[a-z][a-z0-9-]{0,31}$` reject the manifest; a well-formed unknown value is kept.
- A reference's rendering must equal the selected descriptor's (absent means original). Like a size mismatch, a mismatched or unknown descriptor is skipped without reading the cache or downloading, on the latest and on retained releases, so the result is matching older cached artwork or the bundled image. Other placements are unaffected.
- For a `.template` reference, `AssetImageStore.image(for:fallback:)` and `artwork(for:…)` apply `.renderingMode(.template)` to both remote and bundled images.
- The catalog generator accepts `"rendering": "original" | "template"` and emits `rendering: .template` only for template placements; other catalogs generate byte-identical output. Any other value is an error.
- Vendors the shared corpus with 15 new signed rendering manifests and 10 rendering resolution cases.

Validation: on October 9, 2026, `swift test` passed 57 tests across 6 suites on macOS (56 passed, the optional hosted test skipped), including all 115 signed manifest cases and the 10 rendering resolution cases, with no download on any mismatch. Template rendering of remote and bundled images was checked with `ImageRenderer`. All 5 code-generation tests and `swift build -c release` passed. No iOS simulator or device run is claimed.

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
