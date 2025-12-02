// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IMAPMenu",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "IMAPMenu", targets: ["IMAPMenu"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "IMAPMenu",
            dependencies: [],
            path: "Sources"
        )
    ]
)
