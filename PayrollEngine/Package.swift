// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PayrollEngine",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PayrollEngine", targets: ["PayrollEngine"])
    ],
    targets: [
        .target(name: "PayrollEngine"),
        .testTarget(name: "PayrollEngineTests", dependencies: ["PayrollEngine"])
    ]
)
