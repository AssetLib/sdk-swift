# AGENTS.md

Assetlib for Swift: the public, MIT-licensed SwiftPM package (product `AssetLib`) that verifies signed artwork releases, keeps a verified local cache, and returns ordinary SwiftUI `Image` values with the app's bundled fallbacks. iOS 17+ / macOS 14+, Swift 6 language mode, no third-party runtime dependencies. Apps pin it by exact git tag; manifests are signed by the hosted console (https://console.assetlib.dev). Developer preview; latest release `0.4.0-preview.1` (October 10, 2026). The Kotlin SDK (AssetLib/sdk-android) and the JavaScript SDK (AssetLib/sdk-js) implement the same contract.

## Commands

CI (`.github/workflows/ci.yml`, `macos-15`, every push and pull request) runs exactly these three. All must pass before work is called done:

```sh
swift test                        # all suites; HostedAcceptance is skipped without a config file
python3 scripts/test_codegen.py   # generator tests, including "Examples/Artwork.generated.swift is current"
swift build -c release            # also compiles Examples/ through the AssetLibExample target
```

- Focused run: `swift test --filter VariantTests`. Suites: `ProtocolTests`, `RenditionTests`, `VariantTests`, `RenderingTests`, `StorageIdentityTests`, `HostedAcceptance`.
- Optional read-only hosted check: `ASSETLIB_PUBLIC_CONFIG_FILE=/absolute/path/to/public-config.json swift test --filter HostedAcceptance`. Keep that file outside the repo; never commit or print it.
- After changing the generator or `Examples/catalog.json`: `python3 scripts/generate-catalog.py Examples/catalog.json Examples/Artwork.generated.swift`.
- If a sandbox blocks the default Clang module cache, `swift build` fails before compiling. VERIFICATION.md records the workaround (writable `CLANG_MODULE_CACHE_PATH` and `SWIFTPM_MODULECACHE_OVERRIDE`, plus `--disable-sandbox`). Do not edit `Package.swift` to get around it.
- CI is macOS only. Nothing in this repo builds for iOS, a simulator, or a device; iOS compilation and UI are checked through the separate AssetLib/demo-ios app.

## Layout

- `Sources/AssetLib/AssetClient.swift`: actor with `initialize`, `refresh`, `resolve`, the operation gate, and the `decide` callback.
- `Sources/AssetLib/Verification.swift`: Ed25519 and scope checks, durable-state verification, rendition candidate order, native ImageIO decode checks.
- `Sources/AssetLib/Models.swift`: `AssetConfiguration` (validation, `storageNamespace`, legacy namespaces), `AssetLimits`, manifest and variant models, `ResolvedAsset`.
- `Sources/AssetLib/Storage.swift`: `FileAssetStorage` (OS file lock, atomic commit, one-time namespace migration, bounded cache).
- `Sources/AssetLib/Transport.swift`: HTTPS GET with no redirects, cookies, or credential storage, and a streamed byte limit.
- `Sources/AssetLib/AssetImageStore.swift`: `@MainActor @Observable` store behind the generated accessors.
- `Sources/AssetLib/PrivacyInfo.xcprivacy`: declares file-timestamp access (C617.1). Update it if required-reason API use changes.
- `scripts/generate-catalog.py`: offline generator apps copy; apps commit its output.
- `Tests/AssetLibTests/Fixtures/`: shared contract corpus (next section).

## Shared contract corpus

- `Tests/AssetLibTests/Fixtures/` is a byte-for-byte copy of the signed interoperability corpus that the Kotlin SDK vendors at `sdk/src/test/resources/fixtures/` and that is also run against the JavaScript SDK where the corpus is generated: 115 signed manifest cases (`cases.json` is the index, each case names its `production` or `staging` config), 18 variant resolution entries, 6 stateful cases, 2 byte-failure cases, 4 rendition selections (`renditions.json`), and 10 rendering resolution cases (`rendering.json`). `README.txt` is the only local file.
- The corpus is generated outside this repo. Never hand-edit, re-sign, or reformat a fixture: signatures cover exact payload bytes, and outer JSON whitespace differs from the signed payload on purpose. A contract change lands in the corpus first; then replace the whole directory (keep `README.txt`) here and in sdk-android in the same pass.
- No CI step checks the copy against its source. A `diff -r` against the Kotlin repo's fixture directory should show only `README.txt`.
- `keys/TEST_ONLY_*` is deliberately public test material. Never trust it outside tests.
- Behavior must match the Kotlin and JavaScript SDKs. A semantic change here needs the matching change and corpus cases in the other SDKs.

## Invariants

- **Bundled fallback always wins on failure.** Invalid config, storage, signature, scope, download, hash, decode, dimensions, cancellation, or decision state returns `source == .bundle` with no bytes, and the app renders its bundled image. Never render unverified bytes. Never remove or weaken a fallback path.
- **Signatures.** Verify Ed25519 over the exact UTF-8 bytes of the `payload` string before reading it. Trust comes only from `pinnedPublicKey` / `pinnedPublicKeys` in the public config; an envelope cannot supply a key. The key ID is the first 16 hex characters of SHA-256 of the exact PEM text. Payload `orgId`, `appId`, and `environment` must equal the config exactly.
- **Delivery.** HTTPS, same origin, exact scoped paths: `/api/delivery/{orgId}/{appId}/environments/{environment}/manifest`, plus the legacy `/api/delivery/{orgId}/{appId}/manifest` for production only. No redirects, cookies, or credentials. Byte limits are enforced while streaming; default deadline 8 seconds.
- **Replay and rollback.** Sequences never decrease. Equal sequence with different payload bytes is rejected using `Data(payload.utf8)`, never Swift `String ==` (that uses Unicode equivalence). Rollback is a new, higher sequence.
- **Durable state.** Commit a verified higher release before exposing it. State is re-read and re-verified per operation and after each manifest download. Unverifiable state fails closed to the bundle and blocks refresh; never delete it automatically. `disconnect()` keeps replay history.
- **Storage namespace** is SHA-256 of origin, org, app, and environment (`AssetConfiguration.storageNamespace`). Staging and production stay isolated. Changing the formula strands replay floors and caches; it requires a verified one-time migration like `legacyStorageNamespaces` plus the `namespace-v2` marker, with `StorageIdentityTests` extended.
- **Cache and offline restart.** Cached bytes are re-verified on read. Only the latest accepted release may download; older retained releases are cache-only fallbacks.
- **Renditions.** Smallest raster meeting the target, else largest; ties by byte length, then hash; the legacy WebP slot is always the last candidate. `supportedFormats` must include `.webP`. SVG metadata is validated, never fetched.
- **Rendering.** A reference's rendering must equal the selected descriptor's (absent means original). A mismatched or unknown descriptor is skipped like a size mismatch, on every retained release: no cache read or download from it. Malformed values reject the manifest; well-formed unknown values affect only their placement.
- **Variants.** Resolution order: (arm, appearance), (arm, any), (control, appearance), legacy slot. Never borrow another arm's artwork. Native clients ignore `states`.
- **Decision callback.** Runs only when no explicit `arm` is passed and the current slot declares arms, and always outside the operation gate (never hold `acquire()` across it). Default wait 1,500 ms, allowed 100...10,000. Timeout, throw, nil, or an undeclared arm resolves control with `.invalidDecision` and a reason in `message`. Afterwards the client reloads durable state and re-checks the arm against the current release. `VariantTests` covers reentry, stalls, cancellation, and races.
- **Limits** in `AssetLimits` and README "Delivery and failure behavior" are contract values. Change them only together with the corpus.
- Getters never start requests. No background polling, analytics, user identifiers, or exposure logging in the SDK.

## Public API and compatibility

- Public surface: `AssetClient`, `AssetConfiguration`, `AssetImageStore`, `AssetArtwork`, `AssetReference`, `AssetRendering`, `AssetPixelSize`, `AssetFormat`, `AssetAppearance`, `AssetArmSource`, `AssetAccessibility`, `ResolvedAsset`, `RefreshResult`, `AssetSource`, `AssetLimits`, `AssetLibError`, the `AssetStorage` and `AssetTransport` protocols, `FileAssetStorage`, `HTTPSAssetTransport`, `hashBytes`.
- Apps commit generated code that calls `AssetReference(key:width:height:)`, `AssetImageStore.image(for:fallback:)`, `AssetImageStore.artwork(for:fallback:bundledAccessibility:locale:requireDescription:)`, and `AssetAccessibility(defaultLocale:descriptions:)`. Keep these source-compatible. The `AssetLibExample` target and `test_codegen.py` catch breaks.
- Add parameters with defaults; do not remove or reorder existing ones. A new requirement on `AssetStorage` or `AssetTransport` breaks custom implementations; call it out in CHANGELOG.md.
- Keep Swift 6 strict concurrency clean (`Sendable`, actor isolation, `@MainActor` store).

## Release and versioning

- No version in `Package.swift`; SwiftPM resolves the git tag. Version strings to change together: README "Install" (the Xcode exact version and the `.package(..., exact:)` line) and a new CHANGELOG.md heading whose `Validation:` line states only what was actually run.
- Tags are bare semver with no `v` prefix (`0.3.0-preview.1`), annotated, with a matching GitHub prerelease. Never move or delete a published tag; apps pin `exact:`.
- `0.2.1-preview.1` was tagged from a side branch and is not an ancestor of `main`. `phase-4-native-parity` is fully contained in `main`. Work from `main`.
- Do not tag, push, or publish unless the maintainer asks.

## Verified vs not verified

- Established for `0.3.0-preview.1` and `0.3.1-preview.1`: `swift test` on macOS against the full corpus, the codegen tests, a release build, and green CI on `main` and on the tag.
- Simulator: on October 9, 2026 the demo-ios app (SDK `0.3.0-preview.1`) ran on an iOS 27 simulator and verified and rendered a hosted signed release; see AssetLib/demo-ios VERIFICATION.md.
- Not established: running on iPhone or iPad hardware; VoiceOver; hosted acceptance of staging, variants, or PNG renditions; App Store submission. A macOS test pass is not an iOS pass.
- Do not claim device, simulator, or hosted acceptance you did not run. When you do run a check, add a dated VERIFICATION.md entry with the exact command and output, and no local absolute paths or configuration contents.

## Don'ts

- Don't weaken verification, limits, or fallbacks to make a test pass, and don't edit fixtures to fit the code.
- Don't add third-party dependencies.
- Don't hand-edit `Examples/Artwork.generated.swift`; regenerate it.
- Don't commit public configurations, real keys, hosted URLs, `.build/`, or `.swiftpm/`. Fixtures use `.example` hosts only.
- Don't make placements console-first; they come from the app's checked-in catalog.
- When you find a confirmed defect, fix it, test it, and note it in CHANGELOG.md in the same change. If a fix is unsafe now, say why and when it will happen.
- In prose the product is "Assetlib". `AssetLib` is only the module, product, and GitHub org name. Label planned features as planned.
