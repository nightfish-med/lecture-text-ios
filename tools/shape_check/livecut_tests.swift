import Foundation

// v0.23.5 Sources/LiveCutPlan.swift：實驗模式「Whisper 切句（照電腦版，模擬邊錄邊轉）」的純邏輯——照電腦版 engine.py 切句、落後模擬、報告那一節。
// 期望值先用 Python 照抄電腦版 Track.step／quietest／commit 跑同樣的輸入算出來（不是看 Swift 的結果回填）。main.swift 只呼叫 liveCutTests(check)。

func liveCutTests(_ check: @escaping (String, String, String) -> Void) {
    let W = LiveCut.window
    /// 秒數 → 窗數（四捨五入，同 Python 那份）
    func win(_ seconds: Double) -> Int { Int((seconds * 16_000 / Double(W)).rounded()) }
    func ones(_ n: Int, _ p: Float = 1) -> [Float] { [Float](repeating: p, count: n) }
    func flat(_ probs: [Float]) -> [Float] { [Float](repeating: 0.1, count: probs.count * W / LiveCut.frame) }
    func show(_ r: (segments: [LiveCut.Segment], noise: Int)) -> String {
        r.segments.map { String(format: "%.3f-%.3f", $0.startSeconds, $0.endSeconds) + ($0.forced ? "硬切" : "") }.joined(separator: " ") + "｜雜音 \(r.noise)"
    }

    // ---- 連續講 45 秒沒停：每句 ≤20 秒
    let talk = ones(win(45))
    let even = LiveCut.cut(probs: talk, frameRMS: flat(talk))
    check(show(even), "0.000-14.000硬切 14.000-28.000硬切 28.000-44.992｜雜音 0", "切句：連續講 45 秒、能量一樣 → 3 句（同電腦版：平均時兩端補 0，最安靜處落在搜尋範圍的頭，14 秒）")
    check(even.segments.allSatisfy { $0.seconds <= 20 } ? "都 ≤20 秒" : "有超過", "都 ≤20 秒", "切句：連續講 45 秒每句都 ≤20 秒")
    let dips = (0..<(talk.count * W / LiveCut.frame)).map { i -> Float in
        let t = Double(i) * 0.02
        return abs(t - 17) < 0.05 || abs(t - 35) < 0.05 ? 0.001 : 0.1
    }
    check(show(LiveCut.cut(probs: talk, frameRMS: dips)), "0.000-17.000硬切 17.000-35.000硬切 35.000-44.992｜雜音 0", "切句：連續講 45 秒、17 秒和 35 秒比較安靜 → 切在那裡")
    check(String(format: "%.3f", even.segments[0].decidedSeconds), "20.000", "切句：硬切的那句在 20 秒那刻才知道")

    // ---- 停頓：停 ≥0.6 秒才切（一窗 32 毫秒，0.6 秒＝第 19 個沒聲音的窗）
    func gap(_ n: Int) -> (segments: [LiveCut.Segment], noise: Int) {
        let p = ones(win(3)) + ones(n, 0) + ones(win(3)) + ones(win(1), 0)
        return LiveCut.cut(probs: p, frameRMS: flat(p))
    }
    check(show(gap(16)), "0.000-6.728｜雜音 0", "切句：停 0.5 秒（16 窗）不切")
    check(show(gap(18)), "0.000-6.792｜雜音 0", "切句：停 0.576 秒（18 窗）不切")
    check(show(gap(19)), "0.000-3.208 3.316-6.824｜雜音 0", "切句：停 0.608 秒（19 窗）切；句尾留 0.2、句首留 0.3")
    check(show(gap(22)), "0.000-3.208 3.412-6.920｜雜音 0", "切句：停 0.7 秒（22 窗）切")
    check(String(format: "%.3f", gap(22).segments[0].decidedSeconds), "3.616", "切句：停 0.6 秒那刻才知道上一句結束（句尾 3.208＋0.408）")

    // ---- 雜音：有聲不到 0.25 秒不送
    func blip(_ n: Int) -> (segments: [LiveCut.Segment], noise: Int) {
        let p = ones(win(1), 0) + ones(n) + ones(win(2), 0)
        return LiveCut.cut(probs: p, frameRMS: flat(p))
    }
    check(show(blip(6)), "｜雜音 1", "切句：0.2 秒雜音（6 窗）不送")
    check(show(blip(7)), "｜雜音 1", "切句：0.224 秒（7 窗）也不送")
    check(show(blip(8)), "0.692-1.448｜雜音 0", "切句：0.256 秒（8 窗）送")

    // ---- 進入 ≥0.5、離開 <0.35
    let hyst = ones(10, 0) + ones(20, 0.4) + ones(20, 0.6) + ones(20, 0.4) + ones(30, 0.3)
    check(show(LiveCut.cut(probs: hyst, frameRMS: flat(hyst))), "0.660-2.440｜雜音 0", "切句：0.4 進不去、進去後 0.4 還算人聲、0.3 才算停")
    let silent = ones(win(3))
    check(show(LiveCut.cut(probs: silent, windowRMS: [Float](repeating: 0, count: silent.count), frameRMS: flat(silent))), "｜雜音 0", "切句：整窗沒聲音（RMS<1e-4）不算人聲")
    let tailOpen = ones(win(1), 0) + ones(win(2))
    check(show(LiveCut.cut(probs: tailOpen, frameRMS: flat(tailOpen))), "0.692-3.008｜雜音 0", "切句：講到檔尾沒停，最後一句到檔尾")

    // ---- 最安靜處
    check("\(LiveCut.quietest([0.1, 0.1, 0.1], from: 0, to: 320))", "320", "最安靜處：不到 2 格切在終點（同電腦版）")
    let valley: [Float] = [0.5, 0.5, 0.5, 0.5, 0.01, 0.01, 0.01, 0.01, 0.01, 0.5, 0.5, 0.5, 0.5]
    check("\(LiveCut.quietest(valley, from: 0, to: 13 * 320))", "1920", "最安靜處：5 點平均後最小的那格（第 6 格＝0.12 秒）")
    check("\(LiveCut.quietest([0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.01, 0.5, 0.5, 0.5, 0.5, 0.5], from: 0, to: 12 * 320))", "0", "最安靜處：只有一格安靜時，兩端補 0 的平均反而比較小（同電腦版 numpy）")

    // ---- Silero 一塊 256 毫秒攤到 8 窗
    check(LiveCut.spread([0.9, 0.1], windowsPerChunk: 8, windows: 12).map { String(format: "%.1f", $0) }.joined(separator: ","),
          "0.9,0.9,0.9,0.9,0.9,0.9,0.9,0.9,0.1,0.1,0.1,0.1", "人聲機率：一塊攤到 8 窗")
    let energy = LiveCut.energyProbs([Float](repeating: 0.001, count: 8) + [0.1, 0.1])
    check(energy.probs.map { String(format: "%.0f", $0) }.joined() + String(format: " %.3f", energy.threshold), "0000000011 0.003", "能量門檻備案：大聲的窗才算人聲")

    // ---- 落後模擬：一次只跑一句
    let fast = LiveLag.simulate([10.0, 20, 30].map { LiveLagItem(end: $0, available: $0, compute: 1) })
    check(fast.map { String(format: "%.1f", $0) }.joined(separator: ","), "1.0,1.0,1.0", "落後：運算比句子快 → 落後≈運算時間")
    let slow = LiveLag.simulate([10.0, 20, 30].map { LiveLagItem(end: $0, available: $0, compute: 15) })
    check(slow.map { String(format: "%.1f", $0) }.joined(separator: ","), "15.0,20.0,25.0", "落後：運算比句子慢 → 越排越後面")
    let waited = LiveLag.simulate([LiveLagItem(end: 3.2, available: 3.6, compute: 1)])
    check(waited.map { String(format: "%.1f", $0) }.joined(), "1.4", "落後：等停 0.6 秒才知道一句結束的版本")
    let ten: [Double] = (1...10).map { Double($0) }
    check("\(LiveLag.percentile(ten, 0.5) ?? -1) \(LiveLag.percentile(ten, 0.9) ?? -1) \(LiveLag.percentile([], 0.5) == nil)", "5.0 9.0 true", "百分位：中位、90%、空的")
    check(LiveLag.spread(ten), "中位 5.0 秒、90% 9.0 秒、最大 10.0 秒", "百分位：報告的寫法")

    // ---- 報告那一節
    var summary = LiveCutSummary(detector: "Silero", detectSeconds: 12, sentences: [
        LiveSentence(start: 0, end: 20, decided: 20, forced: true, compute: 2, chars: 80),
        LiveSentence(start: 21, end: 24, decided: 24.4, forced: false, compute: 0.5, chars: 12),
    ], noise: 3, audioSeconds: 30)
    summary.runs = 2
    summary.removed = 40
    summary.loops = 1
    summary.loopChars = 60
    summary.thermal = ["正常", "微溫"]
    summary.batteryStart = "電量 80%"
    summary.batteryEnd = "電量 78%"
    let section = LiveCutReport.section(summary).joined(separator: "\n")
    for want in ["句數：2（其中 1 句超過 20 秒被硬切）；當雜音沒送：3 段", "落後：中位 0.5 秒、90% 2.0 秒、最大 2.0 秒", "整場最後一句落後 0.5 秒",
                 "連續重複壓縮：2 處、少了 40 字", "整段疑似迴圈略過：1 段、60 字", "每分鐘熱度：0′ 正常、1′ 微溫", "開始：電量 80%；結束：電量 78%",
                 "分布 <2 秒 0 句｜2–5 1 句｜5–10 0 句｜10–15 0 句｜15–20 1 句"] {
        check(section.contains(want) ? want : "沒有：" + want, want, "報告切句那節：" + want)
    }
    let lab = [LabResult(name: "Apple 現用", note: "", pieces: [], text: "向量很長", seconds: 60, error: nil),
               LabResult(name: "Whisper 切句", note: "", pieces: [], text: "向量很長", seconds: 60, error: nil, live: summary)]
    let md = LabReport.markdown(file: "x.caf", course: "解析幾何", audioSeconds: 30, keywords: [], results: lab, app: "0.23.5")
    check(md.contains("## Whisper 切句（照電腦版，模擬邊錄邊轉）") ? "有" : "沒有", "有", "報告：有切句那一節")
    check(LabReport.markdown(file: "x.caf", course: "解析幾何", audioSeconds: 30, keywords: [], results: [lab[0]], app: "0.23.5").contains("模擬邊錄邊轉") ? "有" : "沒有", "沒有", "報告：沒跑切句就沒有那一節")
    let json = (try? JSONEncoder().encode(summary)).flatMap { try? JSONDecoder().decode(LiveCutSummary.self, from: $0) }
    check(json == summary ? "一樣" : "不一樣", "一樣", "每句.json：存了讀回來一樣")
}
