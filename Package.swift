// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConfigSSH",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ConfigSSH", targets: ["ConfigSSH"])
    ],
    targets: [
        .target(name: "ConfigSSHCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "ConfigSSH", dependencies: ["ConfigSSHCore"],
                          resources: [.process("Resources")],
                          linkerSettings: [.linkedFramework("Carbon")]),
        .testTarget(name: "ConfigSSHCoreTests", dependencies: ["ConfigSSHCore"])
    ]
)
