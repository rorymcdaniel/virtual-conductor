// swift-tools-version: 6.4
import PackageDescription
let package = Package(
    name: "VirtualConductor",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "VirtualConductor", targets: ["VirtualConductor"])],
    targets: [
        .target(name: "ConductorCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "VirtualConductor", dependencies: ["ConductorCore"], resources: [.copy("Resources/MuseScore")]),
        .testTarget(name: "ConductorCoreTests", dependencies: ["ConductorCore", "VirtualConductor"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
