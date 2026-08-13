// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeepSeekCode",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DeepSeekCodeCore", targets: ["DeepSeekCodeCore"]),
        .executable(name: "DeepSeekCode", targets: ["DeepSeekCodeApp"]),
        .executable(name: "deepseekd", targets: ["DeepSeekCodeDaemon"]),
        .executable(name: "deepseek", targets: ["DeepSeekCodeCLI"]),
        .executable(name: "deepseek-worker", targets: ["DeepSeekCodeWorker"]),
        .executable(name: "DeepSeekCodeChecks", targets: ["DeepSeekCodeChecks"]),
        .executable(name: "DeepSeekCodeRuntimeV2Checks", targets: ["DeepSeekCodeRuntimeV2Checks"]),
        .executable(name: "DeepSeekCodeHarnessChecks", targets: ["DeepSeekCodeHarnessChecks"]),
        .executable(name: "DeepSeekCodeDaemonChecks", targets: ["DeepSeekCodeDaemonChecks"]),
        .executable(name: "DeepSeekCodeWorkerChecks", targets: ["DeepSeekCodeWorkerChecks"]),
        .executable(name: "DeepSeekCodeCLIChecks", targets: ["DeepSeekCodeCLIChecks"]),
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
            name: "DeepSeekCodeDaemon",
            dependencies: ["DeepSeekCodeCore"],
            path: "Sources/DeepSeekCodeDaemon"
        ),
        .executableTarget(
            name: "DeepSeekCodeCLI",
            dependencies: ["DeepSeekCodeCore"],
            path: "Sources/DeepSeekCodeCLI"
        ),
        .executableTarget(
            name: "DeepSeekCodeWorker",
            dependencies: ["DeepSeekCodeCore"],
            path: "Sources/DeepSeekCodeWorker"
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
            name: "DeepSeekCodeHarnessChecks",
            dependencies: ["DeepSeekCodeCore"],
            path: "Tests/HarnessChecks"
        ),
        .executableTarget(
            name: "DeepSeekCodeDaemonChecks",
            dependencies: ["DeepSeekCodeCore"],
            path: "Tests/DaemonChecks"
        ),
        .executableTarget(
            name: "DeepSeekCodeWorkerChecks",
            dependencies: ["DeepSeekCodeCore"],
            path: "Tests/WorkerChecks"
        ),
        .executableTarget(
            name: "DeepSeekCodeCLIChecks",
            dependencies: ["DeepSeekCodeCore"],
            path: "Tests/CLIChecks"
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
