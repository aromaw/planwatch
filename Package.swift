// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PlanWatch",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PlanWatch", targets: ["PlanWatch"])],
    targets: [
        .target(name: "PlanWatchCore"),
        .executableTarget(name: "PlanWatch", dependencies: ["PlanWatchCore"]),
        .testTarget(name: "PlanWatchCoreTests", dependencies: ["PlanWatchCore"]),
    ]
)
