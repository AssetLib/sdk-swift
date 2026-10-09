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
<unknown>:0: error: error opening '/Users/tylerzhao/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/tylerzhao/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx14.0'
```

The successful build and test invocation used:

```sh
export CLANG_MODULE_CACHE_PATH=/tmp/assetlib-h1-module-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/assetlib-h1-module-cache
swift build --disable-sandbox --cache-path /tmp/assetlib-h1-swiftpm-cache --config-path /tmp/assetlib-h1-swiftpm-config --security-path /tmp/assetlib-h1-swiftpm-security && swift test --disable-sandbox --cache-path /tmp/assetlib-h1-swiftpm-cache --config-path /tmp/assetlib-h1-swiftpm-config --security-path /tmp/assetlib-h1-swiftpm-security
```

Final output summary (exit 0):

```text
Build complete! (0.18 sec)
Build complete! (2.92 sec)
➜ Test readOnlyHostedSignatureWebPAndOfflineRestart() skipped.
✔ Test run with 29 tests in 4 suites passed after 0.277 seconds.
```

The full, unedited command/output transcript, including the earlier test compilation failure, was retained at `/tmp/assetlib-h1-verification.log` for the workstream report.

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
