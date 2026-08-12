// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeepSeekCode",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DeepSeekCodeCore", targets: ["DeepSeekCodeCore"]),
        .executable(name: "DeepSeekCode", targets: ["DeepSeekCodeApp"]),
        .executable(name: "DeepSeekCodeChecks", targets: ["DeepSeekCodeChecks"]),
        .executable(name: "DeepSeekCodeRuntimeV2Checks", targets: ["DeepSeekCodeRuntimeV2Checks"]),
        .executable(name: "DeepSeekCodeSSHLoopbackChecks", targets: ["DeepSeekCodeSSHLoopbackChecks"]),
        .executable(name: "DeepSeekCodeScheduler", targets: ["DeepSeekCodeScheduler"]),
        .executable(name: "DeepSeekCodeToolHost", targets: ["DeepSeekCodeToolHost"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.16.0")
    ],
    targets: [
        .target(
            name: "DeepSeekCodeCore",
            path: "Sources/DeepSeekCodeCore"
        ),
        .executableTarget(
            name: "DeepSeekCodeApp",
            dependencies: [
                "DeepSeekCodeCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/DeepSeekCodeApp"
        ),
        .executableTarget(
            name: "DeepSeekCodeChecks",
            dependencies: ["DeepSeekCodeCore"],
            path: "Tests/DeepSeekCodeTests"
        ),
        .executableTarget(
            name: "DeepSeekCodeRuntimeV2Checks",
            dependencies: ["DeepSeekCodeCore"],
            path: "Tests/RuntimeV2Checks"
        ),
        .executableTarget(
            name: "DeepSeekCodeSSHLoopbackChecks",
            dependencies: ["DeepSeekCodeCore"],
            path: "Tests/SSHLoopbackTerminalChecks"
        ),
        .executableTarget(
            name: "DeepSeekCodeScheduler",
            dependencies: ["DeepSeekCodeCore"],
            path: "Sources/DeepSeekCodeScheduler"
        ),
        .executableTarget(
            name: "DeepSeekCodeToolHost",
            dependencies: ["DeepSeekCodeCore"],
            path: "Sources/DeepSeekCodeToolHost"
        )
    ]
)
