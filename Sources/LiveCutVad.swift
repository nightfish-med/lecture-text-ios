import FluidAudio
import Foundation

// v0.23.5 實驗模式「Whisper 切句」用的人聲偵測：FluidAudio 0.18.2 的 Silero VAD（Core ML，App 分人已經在用 FluidAudio）。
// 和電腦版的差別：FluidAudio 的 Silero 模型（silero-vad-unified-256ms-v6.2.1）一次吃 4096 點＝256 毫秒，不是電腦版的 512 點＝32 毫秒；
// 所以每塊的機率攤到 8 個 32 毫秒窗（LiveCut.spread），停頓和雜音的判斷精細度只到 256 毫秒。
// 第一次用要從 Hugging Face 下載模型（FluidInference/silero-vad-coreml，放 Application Support/FluidAudio/Models）；只下載，錄音不上傳。
// 只 import FluidAudio（不和 WhisperKit 放同一檔，免得型別名字撞到）。

final class SileroProbe {
    static let chunk = VadManager.chunkSize
    static let name = "Silero VAD v6（FluidAudio 0.18.2 的 Core ML 版 silero-vad-unified-256ms-v6.2.1；一次 256 毫秒，機率攤到 8 個 32 毫秒窗：停頓實際約要 0.77 秒〔3 塊〕才切；一塊有聲就超過 0.25 秒，所以「雜音不送」幾乎擋不到）"

    private let manager: VadManager
    private var state = VadStreamState.initial()

    private init(manager: VadManager) {
        self.manager = manager
    }

    /// 載入模型（第一次會下載）
    static func make() async throws -> SileroProbe {
        let manager = try await VadManager(config: VadConfig(defaultThreshold: LiveCut.enter))
        return SileroProbe(manager: manager)
    }

    /// 下一塊（4096 點，最後一塊可以比較短，FluidAudio 會補 0）的人聲機率；模型狀態接著上一塊
    func next(_ samples: [Float]) async throws -> Float {
        let result = try await manager.processStreamingChunk(samples, state: state)
        state = result.state
        return result.probability
    }
}
