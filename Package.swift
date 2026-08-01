// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CNVS",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "CNVS",
            dependencies: ["SwiftTerm"],
            path: "Sources/CNVS",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
