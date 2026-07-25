// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VitalsCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SystemMetrics", targets: ["SystemMetrics"]),
        .library(name: "MetricsEngine", targets: ["MetricsEngine"]),
        .library(name: "VitalsUI", targets: ["VitalsUI"]),
        .executable(name: "vitals-dump", targets: ["vitals-dump"]),
        .executable(name: "VitalsApp", targets: ["VitalsApp"]),
    ],
    targets: [
        .target(
            name: "SystemMetrics",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MetricsEngine",
            dependencies: ["SystemMetrics"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "VitalsUI",
            dependencies: ["SystemMetrics", "MetricsEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "vitals-dump",
            dependencies: ["SystemMetrics", "MetricsEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "VitalsApp",
            dependencies: ["VitalsUI", "SystemMetrics", "MetricsEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SystemMetricsTests",
            dependencies: ["SystemMetrics"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MetricsEngineTests",
            dependencies: ["MetricsEngine"]
        ),
        .testTarget(
            name: "VitalsUITests",
            dependencies: ["VitalsUI"]
        ),
    ]
)
