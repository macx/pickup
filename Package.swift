// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Pickup",
    platforms: [.macOS(.v26)],
    products: [
        // Protocol and call state logic. No IOBluetooth/AppKit; testable without hardware.
        .library(name: "PickupCore", targets: ["PickupCore"]),
        // Path A transport: IOBluetoothHandsFreeDevice (macOS only).
        .library(name: "PickupBluetooth", targets: ["PickupBluetooth"]),
    ],
    targets: [
        .target(name: "PickupCore"),
        // Objective-C tap of the raw RFCOMM AT lines (logging and command/result correlation).
        .target(
            name: "PickupBluetoothShim",
            linkerSettings: [.linkedFramework("IOBluetooth")]
        ),
        .target(
            name: "PickupBluetooth",
            dependencies: ["PickupCore", "PickupBluetoothShim"],
            linkerSettings: [.linkedFramework("IOBluetooth")]
        ),
        .testTarget(name: "PickupCoreTests", dependencies: ["PickupCore"]),
        .testTarget(name: "PickupBluetoothTests", dependencies: ["PickupBluetooth", "PickupCore"]),
    ],
    // Swift 5 language mode: the core predates strict concurrency checking (kept deliberately).
    swiftLanguageModes: [.v5]
)
