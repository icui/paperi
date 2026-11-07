// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Paperi",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PaperiCore", targets: ["PaperiCore"]), .executable(name: "paperi", targets: ["Paperi"])],
    targets: [
        .target(name: "PaperiCore"),
        .target(name: "PaperiBridge", linkerSettings: [.linkedFramework("ApplicationServices")]),
        .target(name: "PaperiPlatform", dependencies: ["PaperiCore", "PaperiBridge"]),
        .executableTarget(name: "Paperi", dependencies: ["PaperiCore", "PaperiPlatform"]),
        .testTarget(name: "PaperiCoreTests", dependencies: ["PaperiCore"]),
        .testTarget(name: "PaperiPlatformTests", dependencies: ["PaperiPlatform"])
    ],
    swiftLanguageModes: [.v6]
)
