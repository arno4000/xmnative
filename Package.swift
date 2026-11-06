// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "XMNative",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "XMNative", targets: ["XMNative"]),
        .library(name: "HeadphoneKit", targets: ["HeadphoneKit"]),
        .library(name: "SonyMDR", targets: ["SonyMDR"]),
    ],
    targets: [
        // Vendor-neutral model, driver + transport abstractions. Pure Swift, no OS APIs.
        .target(name: "HeadphoneKit"),

        // Sony "MDR"/Tandem protocol (framing, ACK/sequence, table set 1 + 2). Pure Swift.
        .target(name: "SonyMDR", dependencies: ["HeadphoneKit"]),

        // macOS-only: IOBluetooth RFCOMM transport + paired-device discovery.
        .target(
            name: "MacBluetooth",
            dependencies: ["HeadphoneKit"],
            linkerSettings: [.linkedFramework("IOBluetooth")]
        ),

        // macOS-only: SwiftUI menu bar app.
        .executableTarget(
            name: "XMNative",
            dependencies: ["HeadphoneKit", "SonyMDR", "MacBluetooth"]
        ),

        .testTarget(name: "SonyMDRTests", dependencies: ["SonyMDR", "HeadphoneKit"]),
    ],
    swiftLanguageModes: [.v5]
)
