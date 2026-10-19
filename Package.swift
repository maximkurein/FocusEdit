// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FocusEdit",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FocusEdit",
            path: "Sources/FocusEdit"
        )
    ],
    swiftLanguageModes: [.v5]
)
