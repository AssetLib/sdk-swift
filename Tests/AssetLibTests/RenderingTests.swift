import Foundation
import CoreGraphics
import Testing
import SwiftUI
@testable import AssetLib

private func renderingFixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name))
}
private func renderingConfig() throws -> AssetConfiguration { try .parse(renderingFixture("config.json")) }
private func renderingRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
private let iconTemplate = AssetReference(key: "icons.coast", width: 40, height: 30, rendering: .template)
private let iconOriginal = AssetReference(key: "icons.coast", width: 40, height: 30)
private let travelCoast = AssetReference(key: "travel.coast", width: 1200, height: 900)

private actor RenderingTransport: AssetTransport {
    private var manifest: Data
    private let objects: [String: Data]
    private var online = true
    private(set) var bodyRequests: [String] = []
    init(_ manifest: String, configuration: AssetConfiguration) throws {
        self.manifest = try renderingFixture(manifest)
        let base = "/api/delivery/\(configuration.orgId)/\(configuration.appId)/assets/"
        objects = [base + "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa": try renderingFixture("assets/coast.webp"),
                   base + "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb": try renderingFixture("assets/ridge.webp")]
    }
    func set(manifest name: String) throws { manifest = try renderingFixture(name) }
    func goOffline() { online = false }
    func resetRequests() { bodyRequests = [] }
    func get(_ url: URL, maximumBytes: Int, accept: String) throws -> Data {
        guard online else { throw AssetLibError.invalid("Offline") }
        if url.path.hasSuffix("/manifest") { return manifest }
        bodyRequests.append(url.path)
        guard let data = objects[url.path], data.count <= maximumBytes else { throw AssetLibError.invalid("Fixture unavailable") }
        return data
    }
}

/// Renders an image at a fixed size with an opaque red foreground style and returns its center pixel.
@MainActor private func centerPixel(_ image: Image) throws -> [UInt8] {
    let renderer = ImageRenderer(content: image.resizable().frame(width: 8, height: 6)
        .foregroundStyle(Color(red: 1, green: 0, blue: 0)))
    renderer.scale = 1
    let rendered = try #require(renderer.cgImage)
    var pixels = [UInt8](repeating: 0, count: rendered.width * rendered.height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: rendered.width, height: rendered.height, bitsPerComponent: 8,
            bytesPerRow: rendered.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
        return true
    }
    try #require(drawn)
    let offset = ((rendered.height / 2) * rendered.width + rendered.width / 2) * 4
    return Array(pixels[offset..<offset + 4])
}
private func isTintRed(_ pixel: [UInt8]) -> Bool { pixel[0] > 200 && pixel[1] < 40 && pixel[2] < 40 && pixel[3] > 200 }

private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Image {
    let context = try #require(CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 16,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
    return Image(decorative: try #require(context.makeImage()), scale: 1)
}

@Suite struct RenderingTests {
    @Test func sharedRenderingResolutionCases() async throws {
        struct Matrix: Decodable {
            struct Case: Decodable {
                struct Ref: Decodable { let key: String; let width: Int; let height: Int; let rendering: String? }
                struct Request: Decodable { let appearance: AssetAppearance? }
                let manifest: String
                let ref: Ref
                let request: Request
                let expect: String
                let assetId: String?
            }
            let cases: [Case]
        }
        let matrix = try JSONDecoder().decode(Matrix.self, from: renderingFixture("rendering.json"))
        #expect(matrix.cases.count == 10)
        let configuration = try renderingConfig()
        for (index, entry) in matrix.cases.enumerated() {
            let root = renderingRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let rendering = try #require(entry.ref.rendering.map(AssetRendering.init(rawValue:)) ?? .original, "Case \(index)")
            let reference = AssetReference(key: entry.ref.key, width: entry.ref.width, height: entry.ref.height, rendering: rendering)
            let transport = try RenderingTransport(entry.manifest, configuration: configuration)
            let client = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: transport)
            #expect(await client.refresh().error == nil, "Case \(index)")
            let result = await client.resolve(reference, appearance: entry.request.appearance)
            switch entry.expect {
            case "remote":
                #expect(result.source == .remote && result.assetID == entry.assetId, "Case \(index): \(result.message)")
                #expect(await transport.bodyRequests.count == 1, "Case \(index)")
            case "bundled":
                #expect(result.source == .bundle && result.bytes == nil, "Case \(index): \(result.message)")
                #expect(await transport.bodyRequests.isEmpty, "Case \(index) must not download a body")
            default:
                Issue.record("Unhandled shared rendering expectation: \(entry.expect)")
            }
        }
    }

    @Test func renderingFieldIsValidatedAndUnknownValuesAreKept() throws {
        struct Cases: Decodable {
            struct Manifest: Decodable { let file: String; let verification: String }
            let manifests: [Manifest]
        }
        let configuration = try renderingConfig()
        let entries = try JSONDecoder().decode(Cases.self, from: renderingFixture("cases.json")).manifests.filter { $0.file.contains("rendering") }
        #expect(entries.filter { $0.verification == "accept" }.count == 5)
        #expect(entries.filter { $0.verification == "reject" }.count == 10)
        for entry in entries {
            let envelope = try JSONDecoder().decode(SignedManifest.self, from: renderingFixture(entry.file))
            if entry.verification == "accept" {
                #expect(throws: Never.self, "\(entry.file)") { _ = try ManifestVerifier.verify(envelope, config: configuration) }
            } else {
                #expect(throws: AssetLibError.self, "\(entry.file)") { _ = try ManifestVerifier.verify(envelope, config: configuration) }
            }
        }
        let unknown = try ManifestVerifier.verify(JSONDecoder().decode(SignedManifest.self,
            from: renderingFixture("manifests/valid-rendering-unknown-value-seq9.json")), config: configuration)
        #expect(unknown.slots.map(\.rendering) == [nil, "palette"])
        let cells = try ManifestVerifier.verify(JSONDecoder().decode(SignedManifest.self,
            from: renderingFixture("manifests/valid-rendering-cell-mismatch-seq10.json")), config: configuration)
        let slot = try #require(cells.slots.last), cell = try #require(slot.cells?.first)
        // A selected cell carries its own rendering and never inherits the placement's.
        #expect(slot.rendering == "template" && slot.selecting(cell).rendering == nil)
    }

    @Test func historicalDescriptorsFollowTheSameRuleAcrossOfflineRestart() async throws {
        let root = renderingRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try renderingConfig()
        let transport = try RenderingTransport("manifests/valid-rendering-template-seq9.json", configuration: configuration)
        let client = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: transport)
        #expect(await client.refresh().sequence == 9)
        #expect(await client.resolve(iconTemplate).source == .remote)
        // The coast bytes are now cached, but an original reference never reads them through a template descriptor.
        await transport.resetRequests()
        #expect(await client.resolve(iconOriginal).source == .bundle)
        // Release 10 makes the dark cell original. A template reference skips it and uses release 9's cached template bytes.
        try await transport.set(manifest: "manifests/valid-rendering-cell-mismatch-seq10.json")
        #expect(await client.refresh().sequence == 10)
        let historical = await client.resolve(iconTemplate, appearance: .dark)
        #expect(historical.source == .cache && historical.sequence == 9 && historical.assetID == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        #expect(await client.resolve(iconOriginal, appearance: .light).source == .bundle)
        #expect(await transport.bodyRequests.isEmpty)
        await transport.goOffline()
        let restarted = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: transport)
        #expect(await restarted.refresh().sequence == 10)
        let light = await restarted.resolve(iconTemplate, appearance: .light)
        #expect(light.source == .cache && light.sequence == 10)
        #expect(await restarted.resolve(iconTemplate, appearance: .dark).sequence == 9)
        #expect(await restarted.resolve(iconOriginal, appearance: .light).source == .bundle)
    }

    @Test func referenceRenderingDefaultsAndCodableStayCompatible() throws {
        let reference = AssetReference(key: "travel.coast", width: 1200, height: 900)
        #expect(reference.rendering == .original && reference != AssetReference(key: "travel.coast", width: 1200, height: 900, rendering: .template))
        let older = Data(#"{"key":"travel.coast","width":1200,"height":900}"#.utf8)
        #expect(try JSONDecoder().decode(AssetReference.self, from: older) == reference)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(reference) == Data(#"{"height":900,"key":"travel.coast","width":1200}"#.utf8))
        #expect(try JSONDecoder().decode(AssetReference.self, from: encoder.encode(iconTemplate)) == iconTemplate)
    }

    @MainActor @Test func templateReferencesTintRemoteAndBundledImages() async throws {
        let root = renderingRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try renderingConfig()
        let fallback = try solidImage(red: 0, green: 0.8, blue: 0)
        let store = AssetImageStore()
        // Bundled: the template reference takes the foreground style; the original reference keeps its pixels.
        #expect(isTintRed(try centerPixel(store.image(for: iconTemplate, fallback: fallback))))
        #expect(isTintRed(try centerPixel(store.artwork(for: iconTemplate, fallback: fallback).image)))
        let bundled = try centerPixel(store.image(for: iconOriginal, fallback: fallback))
        #expect(!isTintRed(bundled) && bundled[1] > 150)
        #expect(!isTintRed(try centerPixel(store.artwork(for: iconOriginal, fallback: fallback).image)))
        // Remote: the same rule applies to downloaded artwork.
        let transport = try RenderingTransport("manifests/valid-rendering-template-seq9.json", configuration: configuration)
        store.connect(try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: transport))
        await store.refresh([iconTemplate, travelCoast])
        #expect(store.results[iconTemplate]?.source == .remote && store.results[travelCoast]?.source == .remote)
        #expect(isTintRed(try centerPixel(store.image(for: iconTemplate, fallback: fallback))))
        let artwork = store.artwork(for: iconTemplate, fallback: fallback)
        #expect(artwork.source == .remote)
        #expect(isTintRed(try centerPixel(artwork.image)))
        let photo = try centerPixel(store.image(for: travelCoast, fallback: fallback))
        #expect(!isTintRed(photo) && photo != bundled)
    }
}
