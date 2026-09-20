// swift-tools-version: 5.7
import PackageDescription
let package = Package(name: "XMLTVStreamingProbe", platforms: [.macOS(.v12)],
    dependencies: [.package(path: "../../../OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit")],
    targets: [.executableTarget(name: "XMLTVStreamingProbe", dependencies: [
        .product(name: "OKVideoCore", package: "OKVideoKit")])])
