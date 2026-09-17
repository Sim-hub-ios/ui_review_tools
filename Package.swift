// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UIReview",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UIReview", targets: ["UIReview"]),
        .executable(name: "ui-review-mcp", targets: ["UIReviewMCP"]),
        .library(name: "ReviewCore", targets: ["ReviewCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .target(name: "ReviewCore"),
        .target(name: "ReviewMedia", dependencies: ["ReviewCore"]),
        .executableTarget(name: "UIReview", dependencies: ["ReviewCore", "ReviewMedia", "Sparkle"],
                          linkerSettings: [.linkedFramework("Carbon")]),
        .executableTarget(name: "UIReviewMCP", dependencies: ["ReviewCore", "ReviewMedia"]),
        .testTarget(name: "ReviewMediaTests", dependencies: ["ReviewCore", "ReviewMedia"]),
        .testTarget(name: "ReviewCoreTests", dependencies: ["ReviewCore"]),
        .testTarget(name: "UIReviewTests", dependencies: ["UIReview", "ReviewCore"])
    ],
    swiftLanguageModes: [.v5]
)
