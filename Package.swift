// swift-tools-version: 6.2
import PackageDescription

// Pixel Agency Run: the run workflow of an MES client, as an open package. It was Pixel Agency Lite's (LITE-16, v0.4.2)
// and moved here so that the apps built on it link a package, not an app repo: Pixel Agency Desktop embeds it (D-8),
// and Gaea Lab, the MES reference client, is built on it (G-14, G-20; AB-D-0182 item 4; AB-T-0360).
//
//   PixelAgencyRun     the model: engines (discovery, pairing, credentials), a run (inputs, controls from the
//                      descriptor, progress, results, provenance), the session list, the working folder, masks.
//   PixelAgencyRunUI   the SwiftUI views of the workflow, on MESFormsUI and DesignScaffold.
//   pa-run             the same run workflow without a window, for the MES client conformance suite.
let package = Package(
    name: "PixelAgencyRun",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PixelAgencyRun", targets: ["PixelAgencyRun"]),
        .library(name: "PixelAgencyRunUI", targets: ["PixelAgencyRunUI"]),
        .executable(name: "pa-run", targets: ["RunCLI"]),
    ],
    dependencies: [
        // The Media Engine Specification SDKs.
        .package(url: "https://github.com/xocialize/media-engine-spec.git", from: "0.1.0"),
        .package(url: "https://github.com/xocialize/DesignScaffold.git", from: "0.25.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "PixelAgencyRun", dependencies: [
            .product(name: "MESClientKit", package: "media-engine-spec"),
            .product(name: "MESCore", package: "media-engine-spec"),
            .product(name: "MESFormsUI", package: "media-engine-spec"),
        ]),
        .target(name: "PixelAgencyRunUI", dependencies: [
            "PixelAgencyRun",
            .product(name: "MESClientKit", package: "media-engine-spec"),
            .product(name: "MESFormsUI", package: "media-engine-spec"),
            .product(name: "DesignScaffold", package: "DesignScaffold"),
            .product(name: "DesignScaffoldControls", package: "DesignScaffold"),
            .product(name: "DesignScaffoldMedia", package: "DesignScaffold"),
            .product(name: "DesignScaffoldStatus", package: "DesignScaffold"),
            .product(name: "DesignScaffoldWorkspace", package: "DesignScaffold"),
        ]),
        .executableTarget(name: "RunCLI", dependencies: [
            "PixelAgencyRun", .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "PixelAgencyRunTests", dependencies: [
            "PixelAgencyRun",
            .product(name: "MESEngineKit", package: "media-engine-spec"),
            .product(name: "MockEngineCore", package: "media-engine-spec"),
            .product(name: "MESConformance", package: "media-engine-spec"),
            .product(name: "MESInProcess", package: "media-engine-spec"),
        ]),
    ]
)
