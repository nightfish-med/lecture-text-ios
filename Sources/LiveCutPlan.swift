import Foundation

// v0.23.5 實驗模式「Whisper 切句（照電腦版，模擬邊錄邊轉）」的純邏輯（只用 Foundation；shape_check 用 tools/shape_check/livecut_tests.swift 測）。
// 目的：估「如果錄音中邊錄邊轉，會落後多少、鬼打牆多少」；不用真的開口錄音，拿已錄好的檔模擬：
// 人聲偵測切成一句一句 → 每句單獨送 Whisper（WhisperRunner）→ 照實測運算時間排隊算落後。
// 切句照電腦版（engine.py，不在這個倉庫）的 Track.step／quietest／commit（已實戰），參數一個一個照搬：
// 一窗 32 毫秒；進入人聲機率 ≥0.5、離開 <0.35；句首往前留 0.3 秒、句尾留 0.2 秒；停 ≥0.6 秒定一句；
// 一句最長 20 秒，超過在最後 6 秒內最安靜處（20 毫秒能量、5 點平滑取最小）切開；有聲不到 0.25 秒當雜音不送。
// 和電腦版不同的地方：最安靜處的 20 毫秒格子從檔頭算起（電腦版從那段的起點算），差不到 20 毫秒。
// 真的跑人聲偵測、Whisper 在 LiveCutRunner.swift、LiveCutVad.swift；這裡只吃「每窗人聲機率＋能量」。

enum LiveCut {
    static let sampleRate = 16_000
    /// 人聲偵測一窗（Silero 一次 512 點＝32 毫秒）
    static let window = 512
    /// 找最安靜處用的能量格（20 毫秒）
    static let frame = 320
    static let enter: Float = 0.5
    static let exit: Float = 0.35
    static let prerollSeconds = 0.3
    static let tailSeconds = 0.2
    static let pauseSeconds = 0.6
    static let maxSeconds = 20.0
    /// 超過最長時在最後幾秒內找最安靜處
    static let searchSeconds = 6.0
    static let minVoiceSeconds = 0.25
    /// 整窗幾乎沒聲音（RMS 小於這個）不跑人聲偵測、直接當沒人聲（電腦版 SILENCE_RMS）
    static let silenceRMS: Float = 1e-4

    /// 切出來的一句。樣本位置都是 16 kHz、從檔頭算。
    struct Segment: Equatable {
        var start: Int
        var end: Int
        /// 錄音中的切句器在哪一刻才知道這句結束（停 0.6 秒後；硬切是切的那刻；最後一句是錄音結束）
        var decided: Int
        /// 這句是因為超過 20 秒被硬切的
        var forced: Bool
        var startSeconds: Double { Double(start) / Double(LiveCut.sampleRate) }
        var endSeconds: Double { Double(end) / Double(LiveCut.sampleRate) }
        var decidedSeconds: Double { Double(decided) / Double(LiveCut.sampleRate) }
        var seconds: Double { endSeconds - startSeconds }
    }

    /// probs：每窗（32 毫秒）的人聲機率；windowRMS：每窗的 RMS（nil＝不檢查靜音）；frameRMS：每 20 毫秒的 RMS（從檔頭算）；
    /// total：整個檔幾個樣本（nil＝窗數 × 512）。回傳句子、和當雜音沒送的段數。
    static func cut(probs: [Float], windowRMS: [Float]? = nil, frameRMS: [Float], total: Int? = nil) -> (segments: [Segment], noise: Int) {
        let total = total ?? probs.count * window
        let preroll = Int(prerollSeconds * Double(sampleRate))
        let tail = Int(tailSeconds * Double(sampleRate))
        let pause = Int(pauseSeconds * Double(sampleRate))
        let longest = Int(maxSeconds * Double(sampleRate))
        let search = Int((maxSeconds - searchSeconds) * Double(sampleRate))
        let minVoice = Int(minVoiceSeconds * Double(sampleRate))
        var segments: [Segment] = []
        var noise = 0
        var inSpeech = false
        var segStart = 0
        var lastVoice = 0
        var voiced = 0
        var pos = 0

        func commit(_ wanted: Int, decided: Int, forced: Bool) {
            let end = min(wanted, total)
            if voiced < minVoice || end - segStart < window {
                noise += 1
                return
            }
            segments.append(Segment(start: segStart, end: end, decided: decided, forced: forced))
        }

        for (i, p) in probs.enumerated() {
            pos += window
            let quiet = windowRMS.map { i < $0.count && $0[i] < LiveCut.silenceRMS } ?? false
            let isVoice = !quiet && p >= (inSpeech ? LiveCut.exit : LiveCut.enter)
            if !inSpeech {
                if isVoice {
                    inSpeech = true
                    segStart = max(pos - window - preroll, 0)
                    lastVoice = pos
                    voiced = window
                }
                continue
            }
            if isVoice {
                lastVoice = pos
                voiced += window
            }
            if pos - lastVoice >= pause {
                commit(lastVoice + tail, decided: pos, forced: false)
                inSpeech = false
            } else if pos - segStart >= longest {
                let at = quietest(frameRMS, from: segStart + search, to: pos)
                commit(at, decided: pos, forced: true)
                segStart = at
                voiced = window
            }
        }
        if inSpeech {
            commit(total, decided: total, forced: false)
        }
        return (segments, noise)
    }

    /// a～b（樣本）之間最安靜的地方：20 毫秒能量、5 點平均（兩端補 0，同 numpy convolve 'same'）取最小的第一個。
    /// 格子不到 2 個就切在 b（同電腦版）。
    static func quietest(_ frameRMS: [Float], from a: Int, to b: Int) -> Int {
        let f0 = (a + frame - 1) / frame
        let f1 = min(b / frame, frameRMS.count)
        guard f1 - f0 >= 2 else { return b }
        let e = Array(frameRMS[f0..<f1])
        var best = 0
        var bestValue = Float.greatestFiniteMagnitude
        for k in e.indices {
            var sum: Float = 0
            for j in (k - 2)...(k + 2) where j >= 0 && j < e.count { sum += e[j] }
            let v = sum / 5
            if v < bestValue {
                bestValue = v
                best = k
            }
        }
        return (f0 + best) * frame
    }

    /// 每塊人聲機率（Silero 一塊 256 毫秒＝8 窗）攤成每窗；windows 是總窗數，最後不夠的用最後一塊的
    static func spread(_ chunkProbs: [Float], windowsPerChunk: Int, windows: Int) -> [Float] {
        guard !chunkProbs.isEmpty, windowsPerChunk > 0 else { return [Float](repeating: 0, count: windows) }
        return (0..<windows).map { chunkProbs[min($0 / windowsPerChunk, chunkProbs.count - 1)] }
    }

    /// 人聲模型載不起來時的備案：簡單能量門檻（【我推論】門檻＝有聲窗 RMS 第 20 百分位的 3 倍，至少 0.003）。回傳每窗 0 或 1。
    static func energyProbs(_ windowRMS: [Float]) -> (probs: [Float], threshold: Float) {
        let heard = windowRMS.filter { $0 >= LiveCut.silenceRMS }.sorted()
        let base: Float = heard.isEmpty ? 0 : heard[min(heard.count - 1, heard.count / 5)]
        let threshold: Float = max(base * 3, 0.003)
        let probs: [Float] = windowRMS.map { $0 >= threshold ? Float(1) : Float(0) }
        return (probs, threshold)
    }

    /// 一段聲音的 RMS
    static func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        var sum: Float = 0
        for v in x { sum += v * v }
        return (sum / Float(x.count)).squareRoot()
    }
}

// MARK: 落後模擬

/// 一句：句尾（秒）、錄音中什麼時候拿得到這句的聲音（秒）、實測運算幾秒
struct LiveLagItem: Equatable {
    var end: Double
    var available: Double
    var compute: Double
}

enum LiveLag {
    /// 一次只跑一句、照拿到聲音的順序排隊：開始＝max(拿到聲音, 上一句跑完)，跑完＝開始＋運算。
    /// 回傳每句「字出現時間 − 句尾時間」。
    static func simulate(_ items: [LiveLagItem]) -> [Double] {
        var busyUntil = -Double.infinity
        var lags: [Double] = []
        for item in items.sorted(by: { $0.available < $1.available }) {
            let start = max(item.available, busyUntil)
            let finish = start + item.compute
            busyUntil = finish
            lags.append(finish - item.end)
        }
        return lags
    }

    /// 百分位（取最近的那一筆：排序後第 ⌈q×n⌉ 筆）；空的回 nil
    static func percentile(_ values: [Double], _ q: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((q * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    /// 「中位 x 秒、90% y 秒、最大 z 秒」
    static func spread(_ values: [Double], digits: Int = 1) -> String {
        guard let median = percentile(values, 0.5), let p90 = percentile(values, 0.9), let top = values.max() else { return "沒有資料" }
        let f = "%.\(digits)f"
        return "中位 " + String(format: f, median) + " 秒、90% " + String(format: f, p90) + " 秒、最大 " + String(format: f, top) + " 秒"
    }
}

// MARK: 報告

/// 一句的實測結果（存成「4_Whisper切句_每句.json」，報告的數字都從這裡算，可以離線重算）
struct LiveSentence: Codable, Equatable {
    var start: Double
    var end: Double
    /// 錄音中的切句器什麼時候知道這句結束
    var decided: Double
    var forced: Bool
    /// 只算 Whisper 轉這句的時間（不含讀檔：錄音中聲音已經在記憶體裡）
    var compute: Double
    /// 濾完、這句留下幾個字（去空白標點）
    var chars: Int
}

/// 切句引擎跑完的全部數字
struct LiveCutSummary: Codable, Equatable {
    /// 用了哪個人聲偵測（寫進報告）
    var detector: String
    var detectSeconds: Double
    var sentences: [LiveSentence]
    var noise: Int
    var audioSeconds: Double
    /// 濾鬼打牆：壓縮幾處少幾字、整段略過幾段幾字、幻覺句幾段幾字
    var runs = 0
    var removed = 0
    var loops = 0
    var loopChars = 0
    var hallucinations = 0
    var hallucinationChars = 0
    /// 每分鐘熱度（第 0 分鐘起）、電量起訖
    var thermal: [String] = []
    var batteryStart = ""
    var batteryEnd = ""
    /// 跑到一半被停：只跑到第幾句
    var stoppedAt: Int?
}

enum LiveCutReport {
    /// 每句長度分布：<2、2–5、5–10、10–15、15–20、>20 秒各幾句
    static func histogram(_ lengths: [Double]) -> String {
        let edges: [(String, Double, Double)] = [("<2 秒", 0, 2), ("2–5", 2, 5), ("5–10", 5, 10), ("10–15", 10, 15), ("15–20", 15, 20.001), (">20", 20.001, .infinity)]
        var parts: [String] = []
        for edge in edges {
            let n = lengths.filter { $0 >= edge.1 && $0 < edge.2 }.count
            if edge.0 == ">20" && n == 0 { continue }
            parts.append("\(edge.0) \(n) 句")
        }
        return parts.joined(separator: "｜")
    }

    /// 報告裡「Whisper 切句」那一節
    static func section(_ s: LiveCutSummary) -> [String] {
        var lines: [String] = []
        let done = s.sentences
        lines.append("## Whisper 切句（照電腦版，模擬邊錄邊轉）")
        lines.append("")
        lines.append("- 人聲偵測：\(s.detector)；花 \(String(format: "%.0f", s.detectSeconds)) 秒（不算在下面的運算裡）")
        lines.append("- 切法照電腦版 engine.py：進入人聲機率 ≥0.5、離開 <0.35；句首留 0.3 秒、句尾留 0.2 秒；停 ≥0.6 秒定一句；一句最長 20 秒（超過在最後 6 秒內最安靜處切）；有聲不到 0.25 秒當雜音不送。每句 token 上限 16＋每秒 15（最多 224）；沒有提示詞；每句過濾鬼打牆（同下課 Whisper）")
        if let stopped = s.stoppedAt {
            lines.append("- **跑到一半被停**：只跑了前 \(stopped) 句，下面的數字只算這些")
        }
        let forced = done.filter(\.forced).count
        lines.append("- 句數：\(done.count)（其中 \(forced) 句超過 20 秒被硬切）；當雜音沒送：\(s.noise) 段")
        let lengths = done.map { $0.end - $0.start }
        lines.append("- 每句長度：\(LiveLag.spread(lengths))；分布 \(histogram(lengths))")
        let computes = done.map(\.compute)
        lines.append("- 每句運算：\(LiveLag.spread(computes, digits: 2))")
        let totalCompute = computes.reduce(0, +)
        let spoken = lengths.reduce(0, +)
        var totalLine = String(format: "- 運算合計：%.0f 秒；", totalCompute) + "錄音 " + LabReport.clock(s.audioSeconds) + "、送進 Whisper 的聲音合計 " + LabReport.clock(spoken)
        if totalCompute > 0 {
            totalLine += String(format: "；運算 ÷ 錄音長度＝%.2f（小於 1 才有機會跟得上）", totalCompute / max(s.audioSeconds, 1))
        }
        lines.append(totalLine)
        lines.append("")
        lines.append("### 錄音中跑得跟不跟得上（模擬）")
        lines.append("")
        lines.append("假設每句在句尾就拿到聲音、一次只跑一句、照上面實測的運算時間排隊；落後＝字出現的時間 − 句尾時間。")
        lines.append("")
        let lags = LiveLag.simulate(done.map { LiveLagItem(end: $0.end, available: $0.end, compute: $0.compute) })
        lines.append("- 落後：\(LiveLag.spread(lags))")
        if let last = lags.last {
            lines.append("- 整場最後一句落後 \(String(format: "%.1f", last)) 秒（＝講完最後一句之後還要等多久）")
        }
        let real = LiveLag.simulate(done.map { LiveLagItem(end: $0.end, available: $0.decided, compute: $0.compute) })
        var realLine = "- 另算：錄音中的切句器要停 0.6 秒才知道一句結束（硬切的要到切的那刻），照「知道的那刻才開始跑」算：" + LiveLag.spread(real)
        if let last = real.last {
            realLine += String(format: "；最後一句 %.1f 秒", last)
        }
        lines.append(realLine)
        lines.append("- 注意：這是一個引擎單獨跑的數字。真的錄音中 Apple 轉文字同時在跑、機器連續熱 50 分鐘，會比這裡慢")
        lines.append("")
        lines.append("### 鬼打牆（每句各自濾）")
        lines.append("")
        lines.append("- 連續重複壓縮：\(s.runs) 處、少了 \(s.removed) 字（標〔重複×N，已壓縮〕）")
        lines.append("- 整段疑似迴圈略過：\(s.loops) 段、\(s.loopChars) 字（標〔疑似鬼打牆，略過 N 字〕）")
        lines.append("- 幻覺句拿掉：\(s.hallucinations) 段、\(s.hallucinationChars) 字")
        lines.append("- 實驗模式的「Whisper（整檔）」沒有過這個濾鏡（照原樣），所以和它比字數、一致度時，整檔那份的鬼打牆字還在裡面")
        lines.append("")
        lines.append("### 熱度與電量")
        lines.append("")
        lines.append("- 開始：\(s.batteryStart)；結束：\(s.batteryEnd)")
        if !s.thermal.isEmpty {
            lines.append("- 每分鐘熱度：" + s.thermal.enumerated().map { "\($0.offset)′ \($0.element)" }.joined(separator: "、"))
        }
        lines.append("- 每句的起訖、運算秒數、字數在「4_Whisper切句_每句.json」，上面的數字都能從那裡重算")
        return lines
    }
}
