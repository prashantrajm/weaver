// swift-tools-version: 6.0
import PackageDescription

// Monorepo layout:
//   core/WeaverCore        shared Swift core (macOS today; iOS as it's extracted)
//   apps/macos/WeaverApp   macOS desktop-proxy app (SwiftPM executable)
//   apps/ios               standalone iOS app (Xcode project)
//   apps/android           standalone Android app (future — Kotlin/Compose)
//   tests/WeaverCoreTests  core unit + MITM integration tests
let package = Package(
    name: "Weaver",
    platforms: [
        .macOS(.v14),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "WeaverCore", targets: ["WeaverCore"]),
        .library(name: "InspectorKit", targets: ["InspectorKit"]),
        .library(name: "WeaverIOS", targets: ["WeaverIOS"]),
        .executable(name: "Weaver", targets: ["WeaverApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.34.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.8.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    ],
    targets: [
        .target(
            name: "WeaverCore",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ],
            path: "core/WeaverCore"
        ),
        // Shared MVVM layer (view models + presentation) reused by the macOS
        // and iOS apps. UI-framework-agnostic SwiftUI helpers only — no views.
        .target(
            name: "InspectorKit",
            dependencies: ["WeaverCore"],
            path: "apps/shared/InspectorKit"
        ),
        // iOS app UI (SwiftUI, Liquid Glass, iOS 26+). Sources are wrapped in
        // `#if os(iOS)` so `swift build` on macOS compiles them to nothing;
        // the Xcode app shell in apps/ios consumes this as a library product.
        .target(
            name: "WeaverIOS",
            dependencies: ["WeaverCore", "InspectorKit"],
            path: "apps/ios/WeaverIOS"
        ),
        .executableTarget(
            name: "WeaverApp",
            dependencies: ["WeaverCore", "InspectorKit"],
            path: "apps/macos/WeaverApp"
        ),
        .testTarget(
            name: "WeaverCoreTests",
            dependencies: ["WeaverCore"],
            path: "tests/WeaverCoreTests"
        ),
    ]
)
