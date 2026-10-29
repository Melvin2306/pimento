// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Pimento",
    platforms: [.macOS(.v14)],
    products: [
        // The command-line tool: Foundation + PimentoCore only.
        .executable(name: "pimento", targets: ["pimento"]),
        // The SwiftUI app. scripts/bundle.sh installs this binary as
        // Pimento.app/Contents/MacOS/Pimento. (The product is not called
        // "Pimento": on a case-insensitive disk it would overwrite `pimento`
        // in the build folder.)
        .executable(name: "PimentoApp", targets: ["PimentoApp"]),
    ],
    targets: [
        // Pure logic + Azure plumbing + the CLI's commands, no UI. Unit-tested.
        .target(name: "PimentoCore"),
        .executableTarget(name: "pimento", dependencies: ["PimentoCore"]),
        .executableTarget(name: "PimentoApp", dependencies: ["PimentoCore"]),
        .testTarget(
            name: "PimentoCoreTests",
            dependencies: ["PimentoCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
