# 0.4.0-preview.1 (tintable icons) — October 10, 2026

Released as tag `0.4.0-preview.1` after GitHub Actions passed for the release commit. Checks run on the `feat/tintable-icons` branch before the merge. Plain commands on macOS, no cache workaround:

- `swift test`: `Test run with 57 tests in 6 suites passed` (56 passed, the optional hosted test skipped). The suite loads all 115 signed manifest cases, including 5 accepted and 10 rejected rendering manifests, and the 10 cases in `rendering.json`; every bundled case is asserted to make no asset body request.
- Template rendering is checked by rendering store images with `ImageRenderer` under an opaque red `foregroundStyle`: remote and bundled images for a template reference come out red, and original references keep their pixels.
- With the resolution rule and the template modifier temporarily removed, `swift test --filter RenderingTests` failed 4 of 5 tests with 18 issues; restored afterwards.
- `python3 scripts/test_codegen.py`: `Ran 5 tests`, `OK`. `Examples/catalog.json` is unchanged, so `Examples/Artwork.generated.swift` is unchanged.
- `swift build -c release`: `Build complete!`, including `AssetLibExample`.
- `node check-copy.mjs Tests/AssetLibTests/Fixtures` from the shared corpus: `196/196 files (plus its own README.txt)`.

No simulator, device, or hosted acceptance was run.

# 0.3.1-preview.1 — October 9, 2026

Released as tag `0.3.1-preview.1` on October 9, 2026 after GitHub Actions passed for the release commit. The final gates were rerun with plain `swift test`, `python3 scripts/test_codegen.py` and `swift build -c release` (no cache workaround): 52 tests across 5 suites, 4 codegen tests, and a release build passed. The notes below record the preparation run.

- Before the parser change, both new tests failed with `DecodingError.keyNotFound` for `pinnedPublicKey` in set-only configurations.
- A focused serialization regression reproduced an accepted 4096-byte set-only configuration expanding to 4308 bytes and then failing to parse. The custom encoder fixed it while preserving an explicit non-first single pin; both focused tests then passed.
- After the final changes, 51 test functions passed and 1 optional hosted test was skipped (52 total across 5 suites). Swift Testing summarizes this as `Test run with 52 tests in 5 suites passed`. The shared configuration runner checked all 43 generated cases, compact encode/decode round trips for accepted cases, and 39 envelope verification expectations. The existing 100 signed manifest cases also passed.
- `python3 scripts/test_codegen.py`: `Ran 4 tests`, `OK`.
- `swift build -c release`: `Build complete!`, including `AssetLibExample`.
- All 180 vendored corpus files were compared byte-for-byte with the generated source; every `SHA256SUMS` entry matched. The local fixture `README.txt` was retained.
- `git diff --check` passed.

The initial plain `swift test` attempt stopped before compilation because the default Clang module cache was not writable. The successful gate sequence used the existing documented workaround below. `SWIFT_CHECK_ROOT` represents the local temporary directory used for cache, configuration, and security files; no package settings changed.

```sh
CLANG_MODULE_CACHE_PATH="$SWIFT_CHECK_ROOT/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFT_CHECK_ROOT/module-cache" swift test --disable-sandbox --cache-path "$SWIFT_CHECK_ROOT/cache" --config-path "$SWIFT_CHECK_ROOT/config" --security-path "$SWIFT_CHECK_ROOT/security"
python3 scripts/test_codegen.py
CLANG_MODULE_CACHE_PATH="$SWIFT_CHECK_ROOT/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFT_CHECK_ROOT/module-cache" swift build -c release --disable-sandbox --cache-path "$SWIFT_CHECK_ROOT/cache" --config-path "$SWIFT_CHECK_ROOT/config" --security-path "$SWIFT_CHECK_ROOT/security"
```

These are macOS unit, code-generation, and build checks. No simulator, device, VoiceOver, or hosted acceptance was run.

# 0.3.0-preview.1 — October 9, 2026 (ET)

Release `0.3.0-preview.1` (commit `d9e6c65`). Checked again on main on October 9, 2026 with Apple Swift 6.4 on macOS:

- `swift test`: 48 tests in 5 suites passed. The suite loads the shared corpus of 100 signed manifest cases (production and staging configurations), 18 variant resolution entries, 6 stateful cases, 2 byte-failure cases, and 4 rendition selections. The optional hosted test is skipped without `ASSETLIB_PUBLIC_CONFIG_FILE`.
- `python3 scripts/test_codegen.py`: 4 tests passed.
- `swift build -c release`: passed, including the `AssetLibExample` target.
- GitHub Actions CI passed for the release commit ([run 37888072785](https://github.com/AssetLib/sdk-swift/actions/runs/37888072785)).
- This release also contains the localized descriptions first released as `0.2.1-preview.1` from a separate branch.

Not established: no iOS simulator or device run, no VoiceOver check, and no hosted publish, refresh and rollback run with a native app on this version. iOS compilation is covered by the separate demo-ios app.

# Native environments and variant cells (H1) — October 8, 2026 (ET)

Local source checkout only; no dependency, package version, publication, or hosted changes. Existing uncommitted accessibility work and H0 fixtures were preserved.

- Staging and production configuration paths and signed scope equality are verified, including separate durable storage namespaces.
- The suite loads all 100 signed manifest cases with their configuration, all 18 resolution expectations, all 6 stateful cases, all 2 byte-failure cases, and the existing 4 rendition scenarios.
- Variant tests cover strict axes and coordinates, malformed/null extensions, complete cell image/rendition/accessibility validation, effective arm/appearance/source, callback eligibility and invalid decisions, once-per-resolution historical decisions, selected-cell cache and offline fallback, and store selection changes during an in-flight refresh.
- Unknown variant axes reject as required by the referenced Phase 3 contract; unrelated payload, slot, and cell keys remain ignored. Native state sets remain ignored. Existing content-addressed storage uses the selected cell's candidate hash and retains its signed metadata.
- Final verification succeeded: `✔ Test run with 29 tests in 4 suites passed after 0.277 seconds.` One optional hosted test was skipped because `ASSETLIB_PUBLIC_CONFIG_FILE` was not supplied. No device UI or hosted acceptance was established.
- Verification adjustment: the literal `swift build && swift test` stopped before compilation because the default Clang module cache is outside the writable roots. The successful invocation uses temporary cache/config/security directories and SwiftPM's `--disable-sandbox` option inside the existing execution sandbox. No package or dependency configuration was changed. An intermediate test compile failure from a missing explicit `@Sendable` callback annotation was corrected before the successful rerun.
- H1 implementation is complete. Hosted/device checks and publishing are outside this workstream.

## Verification commands and final output

The unmodified `swift build && swift test` exited 1 with:

```text
<unknown>:0: error: error opening '~/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: ~/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx14.0'
```

The successful build and test invocation used:

```sh
export CLANG_MODULE_CACHE_PATH="$TMPDIR/assetlib-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TMPDIR/assetlib-module-cache"
swift build --disable-sandbox --cache-path "$TMPDIR/assetlib-swiftpm-cache" --config-path "$TMPDIR/assetlib-swiftpm-config" --security-path "$TMPDIR/assetlib-swiftpm-security" && swift test --disable-sandbox --cache-path "$TMPDIR/assetlib-swiftpm-cache" --config-path "$TMPDIR/assetlib-swiftpm-config" --security-path "$TMPDIR/assetlib-swiftpm-security"
```

Final output summary (exit 0):

```text
Build complete! (0.18 sec)
Build complete! (2.92 sec)
➜ Test readOnlyHostedSignatureWebPAndOfflineRestart() skipped.
✔ Test run with 29 tests in 4 suites passed after 0.277 seconds.
```

The full command and output transcript, including the earlier test compilation failure, was kept outside this repository.

# Accessibility verification — October 8, 2026 (ET)

Local source checkout only; no package publication or hosted changes.

- `swift test` passes, including all 83 shared signed-manifest cases and focused locale, historical-cache, offline-restart, missing-description, and bundled/remote snapshot tests. The optional hosted test is skipped.
- `python3 scripts/test_codegen.py`: four tests pass, including literal escaping, generated-name collision rejection, metadata validation, and deterministic output.
- `swift build -c release` passes, including generated native image accessors and compiled decorative/informative `WelcomeView.swift` examples.
- Independent review found and fixed generated type shadowing for `Locale` and `AssetAccessibility`; related dependency names are reserved and regression-tested.
- These checks do not establish VoiceOver behavior or manual device UI acceptance. Existing public SDK tags remain unchanged.

# Earlier rendition extension verification — October 7, 2026 (ET)

Release candidate: **0.2.0-preview.1**. Swift 6 language mode, iOS 17+/macOS 14+.

## Confirmed locally

- `swift test`: 17 executed tests passed; one read-only hosted acceptance test remained disabled because no public configuration was supplied to this run.
- The suite includes all **65 shared signed-manifest cases** and all four `renditions.json` target-selection expectations. Shared fixture copies match the native-contract source corpus.
- ImageIO decoded real PNG and WebP bytes. Tests reject mismatched actual MIME, dimensions, altered/truncated bytes, null/unknown rendition versions, bad scopes/URLs, duplicate hashes, invalid counts/byte limits/pixel bounds/aspect ratios, and unsupported formats.
- Target selection chooses the smallest sufficient raster or largest undersized raster; byte-size/hash ties are deterministic. SVG metadata validates but SVG is never requested by the native SDK.
- Tests cover per-candidate failure, mandatory WebP fallback, historical cache-only fallback, PNG offline restart, old `.webp` cache migration, explicit store target propagation, and retained legacy replay/concurrency/state corruption protections.
- `python3 scripts/test_codegen.py`: two tests passed.
- `swift build -c release`: passed, including the generated SwiftUI example target.
- The demo's ignored local dependency override compiled using XcodeBuildMCP for generic iOS and generic iOS Simulator destinations with signing disabled. No local path was added to the public project.

## Not established by these checks

A macOS test is not an iPhone run. No native iOS runtime UI, VoiceOver, complete live publish/refresh/rollback interaction, or hosted PNG publication was validated in this rendition change. Public package resolution and GitHub CI for this version require the coordinated release tag to exist; check those after publication. No native SVG renderer, PDF import, animation support, or App Store submission is included.
