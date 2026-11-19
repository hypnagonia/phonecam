// swift-tools-version:5.9
import PackageDescription

/// Pure logic shared by the iPhone and Mac apps (no camera, no network), so it can be unit-tested with
/// `swift test --package-path Core`.
let package = Package(
    name: "PhoneCamCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "PhoneCamCore", targets: ["PhoneCamCore"])],
    targets: [
        .target(name: "PhoneCamCore"),
        .testTarget(name: "PhoneCamCoreTests", dependencies: ["PhoneCamCore"]),
    ]
)
