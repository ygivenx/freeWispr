// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FreeWispr",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", branch: "master"),
    ],
    targets: [
        .executableTarget(
            name: "FreeWispr",
            dependencies: ["SwiftWhisper"],
            path: "Sources/FreeWispr",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "FreeWisprTests",
            dependencies: ["FreeWispr"],
            path: "Tests/FreeWisprTests"
        ),
    ]
)
