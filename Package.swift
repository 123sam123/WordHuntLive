// swift-tools-version: 6.0
import PackageDescription

// WordHuntCore holds everything that isn't SwiftUI: models, dictionary/trie,
// solver, scoring, tile vision, OCR, tracking, capture and the live pipeline.
// The macOS app target (App/, generated via project.yml) depends on it.
let package = Package(
    name: "WordHuntCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WordHuntCore", targets: ["WordHuntCore"]),
    ],
    targets: [
        .target(
            name: "WordHuntCore",
            resources: [.copy("Resources/Dictionaries")]
        ),
        .testTarget(
            name: "WordHuntCoreTests",
            dependencies: ["WordHuntCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
