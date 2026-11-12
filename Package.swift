// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CouchMode",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure rules: focus movement, input mapping, the service list. No AppKit/WebKit.
        .target(name: "CouchModeCore", path: "Sources/CouchModeCore"),
        // The app: windows, SwiftUI, WebKit, controllers. Wires CouchModeCore to the system.
        .executableTarget(name: "CouchMode", dependencies: ["CouchModeCore"], path: "Sources/CouchMode"),
        .testTarget(name: "CouchModeCoreTests", dependencies: ["CouchModeCore"], path: "Tests/CouchModeCoreTests", resources: [.copy("Fixtures")]),
    ]
)
