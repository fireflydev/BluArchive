// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BDXLBackupApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "BDXLBackupApp", targets: ["BDXLBackupApp"])
    ],
    targets: [
        .executableTarget(
            name: "BDXLBackupApp",
            path: "Sources/BDXLBackupApp"
        )
    ]
)
