// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "psvr-mac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "psvrctl", targets: ["psvrctl"]),
        .executable(name: "psvrplayer", targets: ["psvrplayer"]),
        .executable(name: "PSVRPlayerApp", targets: ["PSVRPlayerApp"]),
    ],
    targets: [
        .target(name: "PSVRKit"),
        .target(name: "PSVRPlayerCore", dependencies: ["PSVRKit"]),
        .executableTarget(name: "psvrctl", dependencies: ["PSVRKit"]),
        .executableTarget(name: "psvrplayer", dependencies: ["PSVRPlayerCore", "PSVRKit"]),
        .executableTarget(name: "PSVRPlayerApp", dependencies: ["PSVRPlayerCore", "PSVRKit"]),
        .testTarget(name: "PSVRKitTests", dependencies: ["PSVRKit", "PSVRPlayerCore"], resources: [.copy("Fixtures")]),
    ]
)
