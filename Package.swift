// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Skrinsut",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Skrinsut",
            path: "Sources/Skrinsut",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
