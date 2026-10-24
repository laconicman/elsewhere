// swift-tools-version: 6.4
// devin-kick's shape: the façade library in the middle, the executable thin at the edge,
// house tooling on top. The engine is a binary-target package of its own (swift-libxray);
// SwiftSoup is the HTML parser for `Renderer` (§3.7 — the field of tiny libraries);
// the MCP SDK joins at M2.
import PackageDescription

/// Swift 7 upcoming features, on for every handwritten target (see the Design article).
/// `InternalImportsByDefault` turns the layering into a compiler rule: `ElsewhereKit` can
/// only expose a dependency's types through an explicit `public import`.
let upcoming: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
    name: "elsewhere",
    platforms: [
        // D12: macOS 15 — `proxyConfigurations` needs 14+, `Synchronization.Mutex` 15+.
        .macOS(.v15),
    ],
    products: [
        // The tool: `elsewhere fetch|whoami|run|exits|doctor|serve`.
        .executable(name: "elsewhere", targets: ["elsewhere"]),
        // The façade: config, exits, Xray config generation, lifecycle, guards — every
        // surface (CLI now, MCP later) shares it.
        .library(name: "ElsewhereKit", targets: ["ElsewhereKit"]),
    ],
    dependencies: [
        // The engine: the official libXray artifact as a SwiftPM package (sibling repo).
        .package(url: "https://github.com/laconicman/swift-libxray", from: "0.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        // HTML → Markdown: the parser (§3.7). Internal to ElsewhereKit — never a
        // SwiftSoup type in the public surface (rule 1).
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.14.0"),
        // DocC catalog rendering via `swift package generate-documentation`.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
    ],
    targets: [
        // Thin façade over `XrayCore`: the JSON envelope stays inside swift-libxray; here
        // live exits, the generated config, the tunnel lifecycle and the guards.
        .target(
            name: "ElsewhereKit",
            dependencies: [
                .product(name: "XrayCore", package: "swift-libxray"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            swiftSettings: upcoming
        ),
        // The `elsewhere` binary: ArgumentParser glue only — the logic is the Kit's
        // (deepwiki-mcp's untested-executable lesson).
        .executableTarget(
            name: "elsewhere",
            dependencies: [
                "ElsewhereKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: upcoming
        ),
        // Offline suite: loopback only, fixtures copied verbatim. `XrayCore` is a direct
        // dependency because the lifecycle tests drive the engine themselves.
        .testTarget(
            name: "ElsewhereKitTests",
            dependencies: [
                "ElsewhereKit",
                .product(name: "XrayCore", package: "swift-libxray"),
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: upcoming
        ),
    ]
)
