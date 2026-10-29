// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "VirtualConductor",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "VirtualConductor", targets: ["VirtualConductor"])],
    targets: [
        .target(name: "ConductorCore"),
        .executableTarget(name: "VirtualConductor", dependencies: ["ConductorCore"]),
        .testTarget(name: "ConductorCoreTests", dependencies: ["ConductorCore", "VirtualConductor"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
