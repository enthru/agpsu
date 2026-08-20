// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgilentPSU",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgilentPSU", targets: ["AgilentPSU"]),
        .library(name: "AgilentPSUKit", targets: ["AgilentPSUKit"]),
        .executable(name: "agpsu-sim", targets: ["agpsu-sim"]),
        .library(name: "PSUCore", targets: ["PSUCore"]),
        .library(name: "PSUSimulator", targets: ["PSUSimulator"]),
    ],
    targets: [
        .target(name: "PSUCore"),
        .target(name: "PSUSimulator", dependencies: ["PSUCore"]),
        .executableTarget(name: "agpsu-sim", dependencies: ["PSUSimulator"]),
        .target(name: "AgilentPSUKit", dependencies: ["PSUCore", "PSUSimulator"]),
        .executableTarget(name: "AgilentPSU", dependencies: ["AgilentPSUKit"]),
        .testTarget(name: "PSUCoreTests", dependencies: ["PSUCore", "PSUSimulator", "AgilentPSUKit"]),
    ],
    swiftLanguageModes: [.v5]
)
