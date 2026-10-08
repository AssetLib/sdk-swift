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

Add the package in Xcode using `https://github.com/AssetLib/sdk-swift.git`, exact version `0.1.0-preview.2`, and choose the **AssetLib** product. Or use SwiftPM:

```swift
.package(url: "https://github.com/AssetLib/sdk-swift.git", exact: "0.1.0-preview.2")
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
            .accessibilityLabel("An illustrated coastal escape")
            .task {
                images.connect(client)
                await images.refresh(AssetCatalog.all)
            }
    }
}
```

Call `refresh` at explicit lifecycle points such as foregrounding, a refresh gesture, or a user action. There is no background polling. The store loads verified cached artwork first, then checks for a release. A generation token prevents old connection tasks from replacing a new connection's images. `disconnect()` immediately restores caller-provided fallbacks; it preserves durable release history to prevent accidental downgrade when reconnecting.

## Generate typed references offline

Copy `scripts/generate-catalog.py` and adapt [Examples/catalog.json](Examples/catalog.json) to your app. Each placement has a stable key, two-part Swift symbol, logical dimensions, and the name of a bundled fallback image in your asset catalog.

```sh
python3 scripts/generate-catalog.py catalog.json Sources/Artwork.generated.swift
```

Commit the catalog and generated source. Generation uses no network or credentials, and is not a build phase. The resulting `AssetCatalog.Travel.coast` is a typed reference; `AppArtwork(store: images).travel.coast` resolves it to a normal image. Use `bundle:` when your fallback assets live outside `.main`.

An existing placement can receive new compatible artwork without rebuilding the app. Adding a Swift symbol or changing its layout contract requires a new build. Logical placement dimensions must match the signed manifest, while decoded pixels may differ at the same aspect ratio.

## Delivery and failure behavior

- Only pinned Ed25519 manifests for the configured organization, app, and production environment are accepted. Signatures cover exact UTF-8 payload bytes; key IDs cover exact PEM bytes.
- Delivery uses HTTPS, exact scoped paths, the same origin, no cookies or credential storage, no redirects, bounded streaming, and an 8-second request deadline by default.
- Release sequences cannot decrease. Equal-sequence payload changes are rejected using byte equality, including Unicode-equivalent strings. Rollback is a new higher sequence pointing to earlier artwork.
- State is re-read and signatures reverified per operation and after manifest downloads. Atomic disk commits use an OS lock and reject another client's newer state. Invalid durable state fails closed to bundled artwork.
- Image length, SHA-256, WebP container, decode, and aspect ratio are validated. A current download failure can use verified cached artwork from a retained older release; older releases are never fetched as fallback.
- Limits: 256 KiB manifest, 8 MiB image, 100 slots, eight retained manifests, 3 MiB state, 50 MiB/100 disk cache entries. Native decoding additionally limits dimensions to 8,192 per axis and 16 megapixels; the image store keeps at most 32 images/64 MiB of decoded pixel buffers. Images retained by app views are outside that store budget.

This preview handles still WebP artwork. It does not implement Figma import, experiments, usage analytics, automatic screen discovery, native Background Assets, push updates, or key rotation. A plain image cannot report whether it was visible, and layout modifiers do not tell the downloader a desired rendition.

## Test

```sh
swift test
python3 scripts/test_codegen.py
swift build -c release
```

The committed test-only corpus contains signed interoperability cases shared with the JavaScript and Kotlin clients. Tests cover signatures, scope, malformed payloads, exact-byte equivocation, real ImageIO WebP decoding, mismatched layouts, rollback, corrupted bytes, offline restart, concurrent storage clients, and corrupt durable state.

An optional read-only hosted test takes a path to your public configuration outside the repository:

```sh
ASSETLIB_PUBLIC_CONFIG_FILE=/absolute/path/to/public-config.json swift test --filter HostedAcceptance
```

It checks a real signed release, downloads all three starter assets, decodes them natively, and verifies a restarted offline client uses the cache. It never publishes a release or prints the configuration. A macOS test pass does not establish execution on an iPhone; use the demo on a simulator or device for native UI validation.

## Privacy and security

No analytics events, user identifiers, or editor credentials are sent by this SDK. Network infrastructure can still observe ordinary requests and maintain access logs; the SDK privacy manifest does not replace your app's or service's disclosures. The package includes a privacy resource describing file timestamp access for app-container cache management. See [SECURITY.md](SECURITY.md).

MIT licensed. Original test illustrations are included under the same license.
