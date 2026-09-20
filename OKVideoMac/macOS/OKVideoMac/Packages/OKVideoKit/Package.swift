// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "OKVideoKit",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "OKVideoCore", targets: ["OKVideoCore"]),
        .library(name: "OKVideoPersistence", targets: ["OKVideoPersistence"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .brew(["sqlite3"])
            ]
        ),
        .systemLibrary(
            name: "CZlib",
            pkgConfig: "zlib"
        ),
        .target(
            name: "OKVideoCore",
            dependencies: ["CZlib"]
        ),
        .target(
            name: "OKVideoPersistence",
            dependencies: ["OKVideoCore", "CSQLite"]
        ),
        // Explicit developer invocation only; neither App library depends on this target.
        .target(name: "OKVideoMigrationDiagnostics", dependencies: ["OKVideoCore", "OKVideoPersistence", "CSQLite"]),
        .executableTarget(name: "ImportedIdentityDryRun", dependencies: ["OKVideoMigrationDiagnostics"]),
        .testTarget(name: "OKVideoMigrationDiagnosticsTests", dependencies: ["OKVideoMigrationDiagnostics", "OKVideoPersistence", "OKVideoCore", "CSQLite"]),
        .testTarget(
            name: "OKVideoCoreTests",
            dependencies: ["OKVideoCore"],
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "OKVideoPersistenceTests",
            dependencies: ["OKVideoPersistence", "OKVideoCore"]
        )
    ]
)
