# Accessibility verification — October 8, 2026 (ET)

Release candidate: `0.2.1-preview.1`, isolated from the public `0.2.0-preview.1` revision. No hosted changes.

- `swift test` passes, including all 82 shared signed-manifest cases and focused locale, historical-cache, offline-restart, missing-description, and bundled/remote snapshot tests. The optional hosted test is skipped.
- `python3 scripts/test_codegen.py`: four tests pass, including literal escaping, generated-name collision rejection, metadata validation, and deterministic output.
- `swift build -c release` passes, including generated native image accessors and compiled decorative/informative `WelcomeView.swift` examples.
- Independent review found and fixed generated type shadowing for `Locale` and `AssetAccessibility`; related dependency names are reserved and regression-tested.
- The isolated candidate built against the Elsewhere demo for generic iOS and iOS Simulator through XcodeBuildMCP. No usable iOS Simulator runtime is installed.
- A real macOS SwiftUI probe exposed the informative image role and matching bundle, signed/cache, English and Thai descriptions in the native accessibility tree. Restarting with an offline transport retained the signed description; disconnect restored the bundle description. Decorative artwork was absent and the containing action retained its button label. The example explicitly applies the image trait.
- These checks do not establish a VoiceOver listening session or iPhone UI acceptance. Earlier public SDK tags remain unchanged.

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
