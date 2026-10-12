// swift-tools-version:6.2
// UI tests for Pickup.app (docs/TESTING.md, section 4). A standalone package so that `swift test` in App/
// never launches the app; run it through scripts/run-ui-tests.sh.
import PackageDescription

let package = Package(
    name: "PickupUITests",
    platforms: [.macOS(.v26)],
    targets: [
        .testTarget(name: "PickupUITests", path: "Cases"),
    ],
    swiftLanguageModes: [.v5]
)
