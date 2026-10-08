// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AssetLib",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AssetLib", targets: ["AssetLib"])],
    targets: [
        .target(name: "AssetLib", resources: [.process("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "AssetLibTests", dependencies: ["AssetLib"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)
