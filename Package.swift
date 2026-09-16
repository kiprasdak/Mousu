// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Mousu",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Mousu", targets: ["Mousu"])],
    targets: [
        .target(name: "MousuCore", resources: [.process("Resources")]),
        .target(
            name: "MousuNative", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [
                .linkedFramework("IOKit"), .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"), .linkedFramework("Foundation"),
            ]),
        .executableTarget(name: "Mousu", dependencies: ["MousuCore", "MousuNative"]),
    ]
)
