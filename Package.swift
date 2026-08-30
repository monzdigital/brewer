// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Brewer",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Brewer",
            path: "Sources/Brewer"
        )
    ]
)
