// swift-tools-version:5.10
import PackageDescription

// The command-line tool and the core build on macOS, Linux and Windows; the
// SwiftUI app only on macOS, so it is declared only there.
var products: [Product] = [
    // The command-line tool: Foundation + PimentoCore only.
    .executable(name: "pimento", targets: ["pimento"]),
]
var targets: [Target] = [
    // Pure logic + Azure plumbing + the CLI's commands, no UI. Unit-tested.
    .target(name: "PimentoCore"),
    .executableTarget(name: "pimento", dependencies: ["PimentoCore"]),
    .testTarget(
        name: "PimentoCoreTests",
        dependencies: ["PimentoCore"],
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
// The SwiftUI app. scripts/bundle.sh installs this binary as
// Pimento.app/Contents/MacOS/Pimento. (The product is not called "Pimento":
// on a case-insensitive disk it would overwrite `pimento` in the build folder.)
products.append(.executable(name: "PimentoApp", targets: ["PimentoApp"]))
targets.append(.executableTarget(name: "PimentoApp", dependencies: ["PimentoCore"]))
#endif

let package = Package(
    name: "Pimento",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
