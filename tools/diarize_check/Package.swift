// swift-tools-version: 5.9
// 只在雲端 Mac 跑一次：驗分人這條路接得通（下載模型、算、時間對回字）。App 不用這個。
// 雲端先把 Sources/Speakers.swift 和 Sources/TextShaping.swift 複製進來，跑的是 App 同一份程式。
import PackageDescription

let package = Package(
    name: "diarize_check",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.18.2")
    ],
    targets: [
        .executableTarget(
            name: "diarize_check",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources"
        )
    ]
)
