// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GuiyeQwen3TTS",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "Qwen3TTS", targets: ["Qwen3TTS"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.29.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", exact: "2.29.1"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.0.0")
    ],
    targets: [.target(name: "Qwen3TTS", dependencies: [
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXFast", package: "mlx-swift"),
        .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
        .product(name: "Transformers", package: "swift-transformers")
    ])]
)
