import AVFoundation
import CoreML
import Foundation
import WhisperKit

// v0.23.5：Whisper 的共用呼叫。實驗模式（EngineLab）和下課後再轉一份（WhisperAfter）都用這裡；下一版錄音中每 30 秒一段也要用。
// 呼叫方式沿用 v0.23.4 實驗模式在 iPad 真機跑過的那套（WhisperKitConfig、DecodingOptions、簡轉繁）。
// 錄音不上傳；只有第一次從 Hugging Face 下載模型（約 600 MB）。

enum WhisperRunner {
    /// 模型放 Application Support（不出現在檔案 App、不進備份）
    static var folder: URL {
        var url = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("whisperkit", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    /// 已經下載好的模型資料夾（WhisperKit 存在 <folder>/models/argmaxinc/whisperkit-coreml/openai_whisper-<模型>）。
    /// 有就直接載入、不連網（download: true 每次都會先上網查檔名，沒網路就失敗）。三個模型檔都在才算。
    static func cachedModelFolder() -> URL? {
        let repo = folder.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: repo.path) else { return nil }
        for name in names.sorted() where name.hasSuffix(WhisperPlan.model) {
            let url = repo.appendingPathComponent(name, isDirectory: true)
            let needed = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
            if needed.allSatisfy({ FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }) {
                return url
            }
        }
        return nil
    }

    /// 頻譜改在 CPU 算（預設是 GPU；App 在背景時 iOS 不給用 GPU）。編碼、解碼照預設（Neural Engine）。
    static var compute: ModelComputeOptions {
        ModelComputeOptions(melCompute: .cpuOnly)
    }

    /// 載入模型。回傳模型、花幾秒、是不是用已下載的。已下載的載入失敗就改走下載那條（v0.23.4 驗過的設定）再試一次。
    static func load(state: @escaping @MainActor (String) -> Void) async throws -> (pipe: WhisperKit, seconds: Double, cached: Bool) {
        let started = Date()
        if let local = cachedModelFolder() {
            await state("載入模型")
            do {
                let config = WhisperKitConfig(model: WhisperPlan.model, downloadBase: folder, modelFolder: local.path, computeOptions: compute,
                                              verbose: false, prewarm: true, load: true, download: false)
                let pipe = try await WhisperKit(config)
                return (pipe, Date().timeIntervalSince(started), true)
            } catch {
                try Task.checkCancellation()
            }
        }
        await state("下載／載入模型（第一次約 600 MB，要幾分鐘）")
        let config = WhisperKitConfig(model: WhisperPlan.model, downloadBase: folder, computeOptions: compute,
                                      verbose: false, prewarm: true, load: true, download: true)
        let pipe = try await WhisperKit(config)
        return (pipe, Date().timeIntervalSince(started), false)
    }

    /// 關鍵字提示詞（實驗模式可開；下課轉檔不放：實測加提示詞鬼打牆約 970 字、不加約 226 字）
    static func prompt(_ pipe: WhisperKit, keywords: [String]) -> [Int]? {
        guard !keywords.isEmpty, let tokenizer = pipe.tokenizer else { return nil }
        let text = " " + keywords.prefix(60).joined(separator: ", ")
        let tokens = tokenizer.encode(text: text).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return Array(tokens.prefix(200))
    }

    static func options(prompt: [Int]?, seconds: Double = 30) -> DecodingOptions {
        DecodingOptions(task: .transcribe, language: "zh", temperatureFallbackCount: 3, sampleLength: WhisperPlan.tokenLimit(seconds: seconds),
                        usePrefillPrompt: true, detectLanguage: false, skipSpecialTokens: true, promptTokens: prompt, chunkingStrategy: .vad)
    }

    static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : 0
    }

    /// 共用的最小單位：一段聲音（16 kHz 單聲道）→ 這段的字和時間。offset＝這段在整個檔的第幾秒，回傳的時間已加上。
    /// 下一版錄音中照電腦版：人聲偵測切句（停 0.6 秒定稿、一句最長 20 秒、超過在最安靜處切），每句單獨送這裡。
    /// 超過 30 秒的段由 WhisperKit 用人聲偵測（VAD）再切。字已簡轉繁，前後空白沒去（濾鬼打牆要用）。
    static func transcribe(_ pipe: WhisperKit, samples: [Float], offset: Double, prompt: [Int]?) async throws -> [TimedPiece] {
        guard !samples.isEmpty else { return [] }
        let seconds = Double(samples.count) / WhisperPlan.sampleRate
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options(prompt: prompt, seconds: seconds))
        try Task.checkCancellation()
        return convert(results, offset: offset)
    }

    /// 一個錄音檔的一段（from～to 秒）→ 這段的字和時間（時間是檔裡的秒數）
    static func transcribe(_ pipe: WhisperKit, url: URL, from start: Double, to end: Double, prompt: [Int]?) async throws -> [TimedPiece] {
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path, startTime: start, endTime: end)
        return try await transcribe(pipe, samples: samples, offset: start, prompt: prompt)
    }

    /// 轉一個錄音檔：從 start 秒開始，每次 5 分鐘（切在最安靜的 0.1 秒），每轉完一窗就叫 onWindow(這窗的小段, 轉到第幾秒)。
    /// 每窗都走上面那個「一段聲音 → 字」。被取消、或 onWindow 回 false（這窗不算、要停），就丟 CancellationError。
    /// WhisperKit 窗內某一小塊出錯時不會丟錯誤、只是少字（AudioChunker.updateSeekOffsetsForResults 把失敗的丟掉），所以由呼叫的一方決定這窗算不算。
    static func transcribeFile(_ pipe: WhisperKit, url: URL, from start: Double = 0, prompt: [Int]?,
                               onWindow: @escaping @MainActor ([TimedPiece], Double) -> Bool) async throws {
        let total = try duration(of: url)
        let rate = WhisperPlan.sampleRate
        var at = max(0, start)
        while total - at > 0.5 {
            try Task.checkCancellation()
            let end = min(total, at + WhisperPlan.windowSeconds + WhisperPlan.cutSearchSeconds)
            let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path, startTime: at, endTime: end)
            guard !samples.isEmpty else { break }
            let cut = end < total ? WhisperPlan.quietCut(samples, from: Int(WhisperPlan.windowSeconds * rate)) : samples.count
            guard cut > 0 else { break }
            let chunk = cut < samples.count ? Array(samples[0..<cut]) : samples
            let pieces = try await transcribe(pipe, samples: chunk, offset: at, prompt: prompt)
            at += Double(cut) / rate
            guard await onWindow(pieces, at) else { throw CancellationError() }
        }
    }

    static func convert(_ results: [TranscriptionResult], offset: Double) -> [TimedPiece] {
        let hant = StringTransform("Hans-Hant")
        return results.flatMap(\.segments).sorted { $0.start < $1.start }.map { seg in
            let text = seg.text.applyingTransform(hant, reverse: false) ?? seg.text
            return TimedPiece(text: text, start: Double(seg.start) + offset, end: Double(seg.end) + offset)
        }
    }
}
