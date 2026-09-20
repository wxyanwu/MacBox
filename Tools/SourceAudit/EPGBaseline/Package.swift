// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "EPGBaseline",
    platforms: [.macOS(.v12)],
    dependencies: [.package(path: "../../../OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit")],
    targets: [
        .executableTarget(name: "EPGBaseline", dependencies: [
            .product(name: "OKVideoCore", package: "OKVideoKit")]),
        .testTarget(name: "EPGBaselineTests", dependencies: ["EPGBaseline", .product(name: "OKVideoCore", package: "OKVideoKit")])
    ]
)
