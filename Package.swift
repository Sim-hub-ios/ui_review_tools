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
    targets: [
        .target(name: "ReviewCore"),
        .executableTarget(name: "UIReview", dependencies: ["ReviewCore"],
                          linkerSettings: [.linkedFramework("Carbon")]),
        .executableTarget(name: "UIReviewMCP", dependencies: ["ReviewCore"]),
        .testTarget(name: "ReviewCoreTests", dependencies: ["ReviewCore"]),
        .testTarget(name: "UIReviewTests", dependencies: ["UIReview", "ReviewCore"])
    ],
    swiftLanguageModes: [.v5]
)
