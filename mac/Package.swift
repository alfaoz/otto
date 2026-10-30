// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OttoApp",
    platforms: [.macOS("26.0")],
    dependencies: [
        // updates: EdDSA-signed appcast on otto.alfaoz.dev
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "OttoApp",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/OttoApp",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle.framework goes in Contents/Frameworks
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
