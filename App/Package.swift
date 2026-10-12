// swift-tools-version:6.2
// App shell for Pickup. XcodeGen is not installed, so the app is a SwiftPM executable
// that scripts/build-app.sh wraps into Pickup.app (Info.plist, entitlements, signing, strings).
import Foundation
import PackageDescription

// SwiftPM names a path dependency after its directory (lower-cased), not after `name:` in its manifest.
// The repository is checked out as `android-call` (workshop), `pickup-dev` or `pickup` (public repo, CI), so
// the identity is derived from the checkout directory instead of being hard-coded.
let rootPackage = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.lowercased()

let package = Package(
    name: "PickupApp",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "Pickup",
            dependencies: [
                .product(name: "PickupCore", package: rootPackage),
                .product(name: "PickupBluetooth", package: rootPackage),
            ],
            path: "Sources/Pickup",
            // Test hooks (scripted phone, control channel) exist only in debug builds; release builds do not
            // define the flag, so the code is not even compiled (docs/TESTING.md).
            swiftSettings: [.define("PICKUP_TESTING", .when(configuration: .debug))]
        ),
        .testTarget(name: "PickupAppTests", dependencies: ["Pickup"], path: "Tests/PickupAppTests"),
    ],
    // Swift 5 language mode: the core predates strict concurrency checking (kept deliberately).
    swiftLanguageModes: [.v5]
)
