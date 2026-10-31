// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HardSubExtractor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HardSubExtractor", targets: ["HardSubExtractor"])
    ],
    targets: [
        // onnxruntime 的 C 桥接层。用 dlopen 运行时加载动态库，
        // 因此不产生链接期依赖：缺库时应用照常启动，只是 PaddleOCR 不可用。
        .target(
            name: "COnnxRuntime",
            path: "Sources/COnnxRuntime",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "HardSubExtractor",
            dependencies: ["COnnxRuntime"],
            path: "Sources/HardSubExtractor"
        )
    ]
)
