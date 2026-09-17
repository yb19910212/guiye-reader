// swift-tools-version:5.10
import PackageDescription
let package = Package(name: "QwenTokenizerSmoke", platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/huggingface/swift-transformers", exact: "1.0.0")],
    targets: [.executableTarget(name: "QwenTokenizerSmoke", dependencies: [
        .product(name: "Transformers", package: "swift-transformers")])])
