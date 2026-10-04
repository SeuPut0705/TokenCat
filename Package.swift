// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenCat",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TokenCat", targets: ["TokenCat"])],
    targets: [.executableTarget(name: "TokenCat")]
)
