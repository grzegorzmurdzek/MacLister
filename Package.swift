// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacLister",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MacLister",
            path: "Sources/MacLister"
        )
    ]
)
