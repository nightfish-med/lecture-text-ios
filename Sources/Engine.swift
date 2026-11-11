import AVFoundation
import CoreMedia
import Foundation
import Speech

/// 只用 iOS 26.0 就有的 API。AssetInputSequenceProvider、CaptureInputSequenceProvider、
/// AnalyzerInputConverter 是 iOS 27 才有，雲端的 macos-26（Xcode 26.6、iOS SDK 26.5）編不過，不要用。
enum EngineError: LocalizedError {
    case deviceUnsupported
    case noTaiwanChinese(available: [String])
    case emptyAudio
    case unreadable(fileExtension: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .deviceUnsupported:
            return "這台不支援 SpeechTranscriber。"
        case .noTaiwanChinese(let available):
            let list = available.isEmpty ? "（清單是空的）" : available.joined(separator: "、")
            return "沒有 zh-TW，沒有改用其他中文。這台的中文語言：\(list)"
        case .emptyAudio:
            return "這個檔沒有聲音。"
        case .unreadable(let fileExtension, let detail):
            return "讀不出 .\(fileExtension) 裡的聲音。\(detail)"
        }
    }
}

struct RunResult {
    let audioSeconds: Double
    let convertSeconds: Double
}

enum SpeechEngine {
    static let name = "SpeechTranscriber"

    /// 找 zh-TW。supportedLocale(equivalentTo:) 找不到完全相同時會給同語言的別區（文件明寫），
    /// 可能變成 zh_CN 出簡體，所以要自己檢查地區，不對就停下來講清楚。
    static func resolveTaiwanLocale() async throws -> Locale {
        guard SpeechTranscriber.isAvailable else {
            throw EngineError.deviceUnsupported
        }
        let wanted = Locale(identifier: "zh-TW")
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted),
           locale.region?.identifier == "TW" {
            return locale
        }
        let all = await SpeechTranscriber.supportedLocales
        let chinese = all.map(\.identifier).filter { $0.hasPrefix("zh") || $0.hasPrefix("yue") }
        throw EngineError.noTaiwanChinese(available: chinese)
    }

    /// 語言模型由系統管、從 Apple 下載，下載的是模型，聲音不會傳出去。已裝好時 request 是 nil。
    static func installModelIfNeeded(
        for transcriber: SpeechTranscriber,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }
        await progress(0)
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { poll.cancel() }
        try await request.downloadAndInstall()
    }

    /// AVAudioFile 開得了就直接用；開不了（例如影片）先把聲音抽成 m4a。
    /// 回傳要讀的檔；若有產生暫存檔，呼叫的人負責刪。
    static func readableAudio(at url: URL) async throws -> URL {
        if (try? AVAudioFile(forReading: url)) != nil {
            return url
        }
        let fileExtension = url.pathExtension
        guard let session = AVAssetExportSession(
            asset: AVURLAsset(url: url),
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw EngineError.unreadable(fileExtension: fileExtension, detail: "")
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        do {
            try await session.export(to: output, as: .m4a)
        } catch {
            throw EngineError.unreadable(fileExtension: fileExtension, detail: error.localizedDescription)
        }
        return output
    }

    /// 把一段結果拆成帶時間的小片段。某段沒有時間就用整段的時間。
    static func pieces(of text: AttributedString, fallback: CMTimeRange) -> [TimedPiece] {
        func seconds(_ time: CMTime) -> Double {
            time.seconds.isFinite ? time.seconds : -1
        }
        return text.runs.map { run in
            let range = run.audioTimeRange ?? fallback
            return TimedPiece(
                text: String(text[run.range].characters),
                start: seconds(range.start),
                end: seconds(range.end)
            )
        }
    }

    /// 取消（外層 Task.cancel）時會結束分析，已經出來的字留著。
    /// onDownload 只有第一次要裝模型時才呼叫；計時只算分析，不算下載。
    static func transcribe(
        audioURL: URL,
        locale: Locale,
        onStart: @escaping @MainActor (Double) -> Void,
        onDownload: @escaping @MainActor (Double) -> Void,
        onSegment: @escaping @MainActor ([TimedPiece], Double) -> Void
    ) async throws -> RunResult {
        let file = try AVAudioFile(forReading: audioURL)
        let sampleRate = file.processingFormat.sampleRate
        let audioSeconds = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        guard audioSeconds > 0 else {
            throw EngineError.emptyAudio
        }

        // 和 .transcription 一樣只給最後結果（文件寫「basic, accurate」）、不開 fastResults（文件：較快但較不準），
        // 多要時間點：斷句和之後分人都要用。
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        try await installModelIfNeeded(for: transcriber, progress: onDownload)
        await onStart(audioSeconds)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let clock = ContinuousClock()
        let startedAt = clock.now

        // 先開始收結果，再餵聲音。
        let collector = Task {
            for try await result in transcriber.results {
                let reached = result.range.end.seconds
                await onSegment(pieces(of: result.text, fallback: result.range), reached)
            }
        }

        do {
            try await withTaskCancellationHandler {
                if let lastSample = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                try await collector.value
                // 取消後串流可能正常結束而不是丟錯，不能當成轉完。
                try Task.checkCancellation()
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }

        let elapsed = startedAt.duration(to: clock.now).components
        let convertSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return RunResult(audioSeconds: audioSeconds, convertSeconds: convertSeconds)
    }
}
