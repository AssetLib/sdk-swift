# Assetlib for Swift

An open-source preview SDK for verified, remotely managed app artwork. **iOS 17+, macOS 14+, Swift 6.** No third-party runtime dependencies.

Your app owns its UI. Assetlib returns normal SwiftUI `Image` values and handles signed release manifests, bounded downloads, verified local caching, and bundled fallbacks. A generated accessor can look like this:

```swift
artwork.travel.coast
    .resizable()
    .scaledToFill()
    .frame(height: 240)
    .clipped()
```

`artwork` is a generated `AppArtwork` value backed by an observable `AssetImageStore`. The getter returns a native `Image` immediately; it does not start a network request. Read it in a SwiftUI body so Observation can re-evaluate that body after a download. A previously retained `Image` is a snapshot, not a network subscription.

## Install

Add the package in Xcode using `https://github.com/AssetLib/sdk-swift.git`, exact version `0.2.1-preview.1`, and choose the **AssetLib** product. Or use SwiftPM:

```swift
.package(url: "https://github.com/AssetLib/sdk-swift.git", exact: "0.2.1-preview.1")
```

The runnable [SwiftUI travel demo](https://github.com/AssetLib/demo-ios) includes bundled illustrations, generated accessors, and a connection sheet. It works before you create an account.

## Connect a workspace

Create a workspace at the [Assetlib console](https://assetlib-console.vercel.app), then copy its **public SDK configuration**. It contains a public verification key and delivery URL, not an editor credential.

```swift
let configuration = try AssetConfiguration.parse(publicConfigurationData)
let client = try AssetClient(
    configuration: configuration,
    storage: FileAssetStorage(configuration: configuration)
)
```

Keep UI state on the main actor:

```swift
struct WelcomeView: View {
    @State private var images = AssetImageStore()
    let client: AssetClient
    private var artwork: AppArtwork { AppArtwork(store: images) }

    var body: some View {
        artwork.travel.coast
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true) // Decorative welcome artwork.
            .task {
                images.connect(client)
                await images.refresh(AssetCatalog.all)
            }
    }
}
```

Call `refresh` at explicit lifecycle points such as foregrounding, a refresh gesture, or a user action. There is no background polling. The store loads verified cached artwork first, then checks for a release. A generation token prevents old connection tasks from replacing a new connection's images. `disconnect()` immediately restores caller-provided fallbacks; it preserves durable release history to prevent accidental downgrade when reconnecting.

## Appearance, arms, and staging

Feed SwiftUI's color scheme into the store and refresh when it changes. Generated `AppArtwork` accessors stay the same:

```swift
struct AdaptiveWelcomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var images = AssetImageStore()
    let client: AssetClient
    private var artwork: AppArtwork { AppArtwork(store: images) }

    var body: some View {
        artwork.travel.coast
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
            .task(id: colorScheme) {
                if !images.connected { images.connect(client) }
                images.appearance = colorScheme == .dark ? .dark : .light
                await images.refresh(AssetCatalog.all)
            }
    }
}
```

Set `images.arm[AssetCatalog.Travel.coast] = "b"` for an explicit override, or `"control"` to force control. Remove the map entry to use the client's decision callback. Changing `appearance` or `arm` clears old displayed results and invalidates in-flight store updates; call `refresh` to load the new selection. Direct callers use `client.resolve(reference, appearance: .dark, arm: "b")`.

The client initializer accepts `decide: (@Sendable (String, [String]) async -> String?)?`, receiving the placement key and declared arms. Without an override it runs once per resolution when the current placement declares arms. A nil or undeclared result (including `"control"`) uses control with `.invalidDecision`; absent callbacks use `.control`. Keep this callback for assignment only, avoid calling delivery operations on the same client from it, and log exposure with the app's experiment tool after rendering. The store may resolve once for cached artwork and again after refreshing the manifest.

Resolution tries `(arm, appearance)`, `(arm, any)`, `(control, appearance)`, then the legacy slot image. Omitted axes skip the corresponding steps; artwork is never borrowed from another arm. `ResolvedAsset.appearance` and `.arm` describe the selected cell (nil means any/control), and `.armSource` records `.explicit`, `.decision`, `.control`, or `.invalidDecision`. Cache and historical fallback verify the selected cell's image and rendition hashes, with its own accessibility metadata. Native clients ignore slot and cell state sets.

Public configuration accepts `staging` or `production` and requires the signed payload to match exactly. Use the console's environment-specific configuration: `/api/delivery/{orgId}/{appId}/environments/{environment}/manifest`. The legacy `/api/delivery/{orgId}/{appId}/manifest` path is production-only. Staging and production configurations use separate durable storage namespaces.

## Accessibility

SDK `0.2.1-preview.1` adds optional localized artwork descriptions. Images stay native: the app chooses whether a placement is decorative, informative, or part of a control. Generated raw images do not announce filenames or automatically attach content descriptions.

For informative artwork, put `bundledAccessibility` on the placement in your offline catalog, describing the bundled image:

```json
"bundledAccessibility": {
  "defaultLocale": "en",
  "descriptions": { "en": "A coastal landscape with blue water and cliffs" }
}
```

Regenerate the catalog. Read the generated artwork snapshot inside the view body; its image and description belong together:

```swift
@Environment(\.locale) private var locale

// Inside body, using the same store and refresh lifecycle as WelcomeView:
let coast = artwork.travel.coastArtwork(locale: locale, requireDescription: true)
if let description = coast.accessibilityDescription {
    coast.image
        .resizable()
        .scaledToFit()
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(Text(verbatim: description))
} else {
    Text("Explore coastal trips") // App-owned content if no described fallback exists.
}
```

`requireDescription: true` keeps the bundled fallback when downloaded or cached artwork has no description. It controls display selection; it does not prevent downloading. Without that option, an undescribed remote image returns a nil description, never the bundled image's description. Supply a bundled description for informative placements. `locale:` matches exact tags case-insensitively, then progressively less specific tags, then the metadata's explicit default locale. Read the SwiftUI locale environment so in-app language changes update the displayed label without another download.

The console stores optional descriptions with each asset and snapshots them in signed releases. The client returns `resolved.accessibility` from the release that actually supplied its bytes, including retained cache fallback. A description edit requires publishing a new release; an offline device continues using its signed cached description. Rollback restores the earlier image and description together. The store snapshot also handles decoding failures, eviction, disconnect, and missing metadata without mixing remote and bundled descriptions.

Use `.accessibilityHidden(true)` for decorative images. The informative example explicitly creates an accessibility element before applying its label. Keep action labels on their containing control, for example `Button("Explore coastal trips", action: openTrips)` with decorative artwork. You can always apply your own `.accessibilityLabel(...)` to the native image when app context supplies the right meaning. No automatic announcement is posted during refresh, and text alternatives are not a substitute for accessible surrounding controls or layout. Verify the finished screen with VoiceOver using Apple's [accessibility guidance](https://developer.apple.com/documentation/swiftui/accessibility-fundamentals).

## Choose a raster rendition

The signed rendition extension supports still **PNG and WebP** output. New clients also validate SVG rendition metadata, but skip SVG: iOS uses a server-prepared raster fallback. This SDK does not import or render runtime SVG vectors.

Supply a physical pixel target when your app knows its layout and display scale. A 320×240 point image on a 3× display requests 960×720 pixels:

```swift
await images.refresh(AssetCatalog.all, targetPixels: [
    AssetCatalog.Travel.coast: AssetPixelSize(width: 960, height: 720)
])

// For apps using the delivery client without the SwiftUI store:
let resolved = await client.resolve(
    AssetCatalog.Travel.coast,
    targetPixels: AssetPixelSize(width: 960, height: 720)
)
// resolved.mime, resolved.pixelSize, resolved.sha256, resolved.assetID,
// and resolved.sequence describe the actual downloaded/cached artwork.
```

Omitting a target uses the generated reference's logical width and height. Targets must be positive integers no greater than 8192 per axis. They do not change the placement's logical layout contract. Native Image modifiers never initiate requests or infer dimensions for the SDK. One store retains one current image per reference; use the largest required target when a placement appears at several sizes in that store.

The client first tries the smallest supported raster meeting both requested dimensions. If none is large enough, it tries the largest available raster. Equal areas sort by byte length, then hash; each failure advances to the next candidate. The original WebP slot is always the final compatibility candidate. The optional `supportedFormats:` client setting defaults to `[.webP, .png]`; `.webP` remains required, and duplicates are rejected.

Existing WebP-only manifests and old `.webp` cache files still work. The new format-neutral cache verifies every entry before use. SDK **0.1.0-preview.2** continues to consume the legacy WebP slot from extended manifests; it cannot select PNG or size variants. A published source SVG is not evidence that native images remain vector-based.

## Generate typed references offline

Copy `scripts/generate-catalog.py` and adapt [Examples/catalog.json](Examples/catalog.json) to your app. Each placement has a stable key, two-part Swift symbol, logical dimensions, and the name of a bundled fallback image in your asset catalog.

```sh
python3 scripts/generate-catalog.py catalog.json Sources/Artwork.generated.swift
```

Commit the catalog and generated source. Generation uses no network or credentials, and is not a build phase. The resulting `AssetCatalog.Travel.coast` is a typed reference; `AppArtwork(store: images).travel.coast` resolves it to a normal image. Use `bundle:` when your fallback assets live outside `.main`.

An existing placement can receive new compatible artwork without rebuilding the app. Adding a Swift symbol or changing its layout contract requires a new build. Logical placement dimensions must match the signed manifest, while decoded pixels may differ at the same aspect ratio.

## Delivery and failure behavior

- Only pinned Ed25519 manifests for the configured organization, app, and environment (staging or production) are accepted. Signatures cover exact UTF-8 payload bytes; key IDs cover exact PEM bytes.
- Delivery uses HTTPS, exact scoped paths, the same origin, no cookies or credential storage, no redirects, bounded streaming, and an 8-second request deadline by default.
- Release sequences cannot decrease. Equal-sequence payload changes are rejected using byte equality, including Unicode-equivalent strings. Rollback is a new higher sequence pointing to earlier artwork.
- State is re-read and signatures reverified per operation and after manifest downloads. Atomic disk commits use an OS lock and reject another client's newer state. Invalid durable state fails closed to bundled artwork.
- Image length, SHA-256, PNG/WebP container, native decode, and dimensions are validated. Renditions must exactly match their declared physical dimensions; legacy WebP retains its logical aspect-ratio rule. A current download failure can use verified cached artwork from a retained older release; older releases are never fetched as fallback.
- Limits: 256 KiB manifest, 8 MiB image, 100 slots, eight retained manifests, 3 MiB state, 50 MiB/100 disk cache entries. Native decoding additionally limits dimensions to 8,192 per axis and 16 megapixels; the image store keeps at most 32 images/64 MiB of decoded pixel buffers. Images retained by app views are outside that store budget.

This preview handles still PNG/WebP artwork through signed rendition extension v1 and WebP legacy fallback. It does not implement Figma import, built-in experiment assignment or tracking, usage analytics, automatic screen discovery, native Background Assets, push updates, or key rotation. A plain image cannot report whether it was visible, and layout modifiers do not tell the downloader a desired rendition.

## Test

```sh
swift test
python3 scripts/test_codegen.py
swift build -c release
```

The committed test-only corpus contains signed interoperability cases shared with the JavaScript and Kotlin clients. Tests cover signatures, scope, malformed payloads, exact-byte equivocation, all 100 shared signed cases, 18 shared cell resolution scenarios, four shared rendition selection scenarios, real ImageIO PNG/WebP decoding, exact rendition dimensions, target-size ranking, candidate failure, cache migration, mismatched layouts, rollback, corrupted bytes, offline restart, concurrent storage clients, and corrupt durable state. Variant tests cover staging isolation, strict axes and cell validation, decisions, cell-specific cache and historical fallback, and store selection changes. Accessibility cases cover locale selection, malformed metadata, UTF-16 limits, paired historical descriptions, offline restart, missing remote descriptions, and native image snapshots with described bundled fallback.

An optional read-only hosted test takes a path to your public configuration outside the repository:

```sh
ASSETLIB_PUBLIC_CONFIG_FILE=/absolute/path/to/public-config.json swift test --filter HostedAcceptance
```

It checks a real signed release, downloads all three starter assets, decodes them natively, and verifies a restarted offline client uses the cache. It never publishes a release or prints the configuration. A live legacy WebP acceptance pass does not establish hosted PNG publication. A macOS test pass does not establish execution on an iPhone; use the demo on a simulator or device for native UI validation.

## Privacy and security

No analytics events, user identifiers, or editor credentials are sent by this SDK. Network infrastructure can still observe ordinary requests and maintain access logs; the SDK privacy manifest does not replace your app's or service's disclosures. The package includes a privacy resource describing file timestamp access for app-container cache management. See [SECURITY.md](SECURITY.md).

MIT licensed. Original test illustrations are included under the same license.
