// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Pimento",
    platforms: [.macOS(.v14)],
    products: [
        // The app and its read-only CLI mode share one binary.
        .executable(name: "pimento", targets: ["PimentoApp"]),
    ],
    targets: [
        // Pure logic + Azure plumbing, no UI. Everything here is unit-tested.
        .target(name: "PimentoCore"),
        // SwiftUI app (plus the read-only `--list` / `--dry-run` / `--tenants` CLI mode).
        .executableTarget(name: "PimentoApp", dependencies: ["PimentoCore"]),
        .testTarget(
            name: "PimentoCoreTests",
            dependencies: ["PimentoCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
