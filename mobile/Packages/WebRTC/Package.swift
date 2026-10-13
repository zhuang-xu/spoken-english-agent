// swift-tools-version:6.2
import PackageDescription

// Local manifest wrapper for the unmodified WebRTC-SDK 150.7871.01 release.
// Upstream declares tools 5.9 but uses visionOS.v26, which requires 6.2.
let package = Package(
    name: "WebRTC",
    platforms: [.iOS(.v13), .macOS(.v10_15), .macCatalyst(.v14), .tvOS(.v17), .visionOS(.v26)],
    products: [.library(name: "WebRTC", targets: ["WebRTC"])],
    targets: [.binaryTarget(
        name: "WebRTC",
        url: "https://github.com/webrtc-sdk/Specs/releases/download/150.7871.01/WebRTC.xcframework.zip",
        checksum: "03815cdf2f6a0ed328c94d74cce8fd1b8d2b6e95e2b37eab66795012fcecfdfa"
    )]
)
