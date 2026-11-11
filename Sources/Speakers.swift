import FluidAudio
import Foundation

/// 分人：用 FluidAudio 的離線分人（pyannote community-1 的 Core ML 版）。
/// 聲音只在手機上算；第一次要下載模型（這是下載，不是上傳聲音）。11/07 看過 v0.18.2 原始碼：網路只用在下載模型和資源，沒有遙測。
enum SpeakerEngine {
    struct Result {
        let turns: [SpeakerTurn]
        let timing: SpeakerTiming?
    }

    /// 照 FluidAudio 0.18.2 文件：
    /// batchSize 8：iPhone 上 32 的 400 MB 尖峰有被系統殺的風險，8 約 100 MB、結果相同（GettingStarted.md）。
    /// stepRatio 0.1＋最短段 0：救回被鄰居吃掉的短句，官方測的錯誤率較低；代價是分人時間約 2 倍（Benchmarks.md）。
    /// zeroVoteReembed：不開時整段話可能被併進旁邊那個人（OfflineDiarizerTypes.swift）。
    /// 這組設定在真人音檔上的效果還沒上機驗過。
    static func config(count: Int?) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig()
        config.clustering.numSpeakers = count
        config.segmentation.batchSize = 8
        config.segmentation.stepRatio = 0.1
        config.embedding.minSegmentDurationSeconds = 0
        config.zeroVoteReembed = OfflineDiarizerConfig.ZeroVoteReembed(enabled: true)
        return config
    }

    /// count 是 nil 時由模型自己判斷人數。
    /// 取消：FluidAudio 內部每批都檢查 Task 取消，會丟 CancellationError。
    static func run(
        audioURL: URL,
        count: Int?,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> Result {
        let manager = OfflineDiarizerManager(config: config(count: count))
        try await manager.prepareModels()
        let result = try await manager.process(audioURL, progressCallback: { done, total in
            guard total > 0 else { return }
            let fraction = Double(done) / Double(total)
            Task { @MainActor in onProgress(fraction) }
        })
        let turns = result.segments
            .map { SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
            .sorted { $0.start < $1.start }
        let timing = result.timings.map {
            SpeakerTiming(
                load: $0.modelCompilationSeconds + $0.audioLoadingSeconds,
                segment: $0.segmentationSeconds,
                embed: $0.embeddingExtractionSeconds,
                cluster: $0.speakerClusteringSeconds + $0.postProcessingSeconds
            )
        }
        return Result(turns: turns, timing: timing)
    }
}
