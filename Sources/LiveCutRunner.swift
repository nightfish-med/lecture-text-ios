import Foundation
import WhisperKit

// v0.23.5 實驗模式「Whisper 切句（照電腦版，模擬邊錄邊轉）」：拿已錄好的檔，模擬錄音中邊錄邊轉。
// 1. 整個檔跑一次人聲偵測（每 5 分鐘讀一塊，模型狀態接著跑）：每 32 毫秒窗的人聲機率和 RMS、每 20 毫秒的 RMS
// 2. 照電腦版切句（LiveCutPlan.swift 的 LiveCut.cut，純邏輯）
// 3. 每句單獨送 Whisper（WhisperRunner，和下課轉檔、整檔實驗同一套；不放提示詞），量每句運算秒數，每句過濾鬼打牆（WhisperClean）
// 落後怎麼算在 LiveCutPlan.swift（LiveLag）。真的在錄音中跑是下一版。

enum LiveCutRunner {
    struct Detection {
        var probs: [Float]
        var windowRMS: [Float]
        var frameRMS: [Float]
        var total: Int
        var detector: String
        var seconds: Double
    }

    /// 第一步：人聲偵測。Silero 載不起來（例如第一次沒網路下載不到）就改用能量門檻，報告寫明。
    static func detect(url: URL, state: @escaping @MainActor (String) -> Void) async throws -> Detection {
        let started = Date()
        let duration = try WhisperRunner.duration(of: url)
        var probe: SileroProbe?
        var detector = SileroProbe.name
        await state("載入人聲偵測模型（第一次要下載）")
        do {
            probe = try await SileroProbe.make()
        } catch {
            try Task.checkCancellation()
            detector = "能量門檻（Silero 人聲偵測載不起來：\(error.localizedDescription)）"
        }
        let chunk = SileroProbe.chunk
        let window = LiveCut.window
        let frame = LiveCut.frame
        var chunkProbs: [Float] = []
        var windowRMS: [Float] = []
        var frameRMS: [Float] = []
        var pending: [Float] = []
        var framePending: [Float] = []
        var total = 0
        var at = 0.0
        while duration - at > 0.001 {
            try Task.checkCancellation()
            let end = min(duration, at + 300)
            let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path, startTime: at, endTime: end)
            at = end
            guard !samples.isEmpty else { break }
            total += samples.count
            framePending += samples
            var i = 0
            while i + frame <= framePending.count {
                frameRMS.append(LiveCut.rms(framePending[i..<(i + frame)]))
                i += frame
            }
            framePending.removeFirst(i)
            pending += samples
            var j = 0
            while j + chunk <= pending.count {
                let piece = Array(pending[j..<(j + chunk)])
                var w = 0
                while w + window <= piece.count {
                    windowRMS.append(LiveCut.rms(piece[w..<(w + window)]))
                    w += window
                }
                if let probe {
                    let p = try await probe.next(piece)
                    chunkProbs.append(p)
                }
                j += chunk
            }
            pending.removeFirst(j)
            await state("人聲偵測 \(LabReport.clock(at))／\(LabReport.clock(duration))")
        }
        // 最後不滿一塊的
        let rest = pending.count / window
        if rest > 0 {
            for w in 0..<rest {
                windowRMS.append(LiveCut.rms(pending[(w * window)..<((w + 1) * window)]))
            }
            if let probe {
                let p = try await probe.next(pending)
                chunkProbs.append(p)
            }
        }
        let probs: [Float]
        if probe != nil {
            probs = LiveCut.spread(chunkProbs, windowsPerChunk: chunk / window, windows: windowRMS.count)
        } else {
            let energy = LiveCut.energyProbs(windowRMS)
            probs = energy.probs
            detector += String(format: "；門檻 RMS %.4f（【我推論】有聲窗第 20 百分位的 3 倍，至少 0.003）", energy.threshold)
        }
        return Detection(probs: probs, windowRMS: windowRMS, frameRMS: frameRMS, total: total, detector: detector,
                         seconds: Date().timeIntervalSince(started))
    }

    struct Outcome {
        var pieces: [TimedPiece]
        var summary: LiveCutSummary
    }

    /// 第三步：每句單獨送 Whisper。被停的話，已經跑完的句子照樣回傳（summary.stoppedAt＝跑了幾句）。
    static func transcribe(_ pipe: WhisperKit, url: URL, detection: Detection, audioSeconds: Double,
                           progress: @escaping @MainActor (Int, Int, Double) -> Void) async throws -> Outcome {
        let (segments, noise) = LiveCut.cut(probs: detection.probs, windowRMS: detection.windowRMS, frameRMS: detection.frameRMS, total: detection.total)
        var summary = LiveCutSummary(detector: detection.detector, detectSeconds: detection.seconds, sentences: [], noise: noise, audioSeconds: audioSeconds)
        var pieces: [TimedPiece] = []
        let started = Date()
        for (index, segment) in segments.enumerated() {
            // 每分鐘記一次熱度（第 0 分鐘＝開始）
            while Date().timeIntervalSince(started) >= Double(summary.thermal.count) * 60 {
                summary.thermal.append(WhisperPlan.thermalName(ProcessInfo.processInfo.thermalState))
            }
            if Task.isCancelled {
                summary.stoppedAt = index
                break
            }
            await progress(index, segments.count, segment.startSeconds)
            do {
                // 讀檔不算時間：錄音中聲音已經在記憶體裡
                let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path, startTime: segment.startSeconds, endTime: segment.endSeconds)
                let clock = Date()
                let raw = try await WhisperRunner.transcribe(pipe, samples: samples, offset: segment.startSeconds, prompt: nil)
                let compute = Date().timeIntervalSince(clock)
                let cleaned = WhisperClean.clean(raw)
                summary.runs += cleaned.runs
                summary.removed += cleaned.removed
                summary.loops += cleaned.loops
                summary.hallucinations += cleaned.hallucinations
                for event in cleaned.events {
                    switch event.kind {
                    case .loop: summary.loopChars += event.chars
                    case .hallucination: summary.hallucinationChars += event.chars
                    }
                }
                pieces += cleaned.pieces
                let chars = LabMetrics.normalize(cleaned.pieces.map(\.text).joined()).count
                summary.sentences.append(LiveSentence(start: segment.startSeconds, end: segment.endSeconds, decided: segment.decidedSeconds,
                                                      forced: segment.forced, compute: compute, chars: chars))
            } catch where Task.isCancelled {
                summary.stoppedAt = index
                break
            }
        }
        return Outcome(pieces: pieces, summary: summary)
    }
}
