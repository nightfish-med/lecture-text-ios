import Foundation

// v0.23.5 Sources/WhisperPlan.swift：下課後 Whisper 再轉一份的純邏輯——濾鬼打牆（iPad 實測看過的樣子）、
// 切窗的安靜點、稿頭與分段、待辦標記合併、紀錄的字；LabPlan 的「疑似失敗」。main.swift 只呼叫 whisperTests(check)。

func whisperTests(_ check: @escaping (String, String, String) -> Void) {
    func r(_ s: String, _ n: Int) -> String { String(repeating: s, count: n) }
    func collapsed(_ s: String) -> String { LoopFilter.collapse(s).text }

    // ---- 濾鬼打牆：iPad 實驗模式 Whisper 稿裡出現過的樣子（人名是假的）。留 1 份＋〔重複×N，已壓縮〕（電腦版 engine.py collapse_repeats 的標法）
    func m(_ n: Int) -> String { "〔重複×\(n)，已壓縮〕" }
    check(collapsed(r(" 林小安", 28)), " 林小安" + m(28), "鬼打牆：「 林小安」×28 → 1 份＋標註")
    check(collapsed(r(", Wait", 36)), ", Wait" + m(36), "鬼打牆：「, Wait」×36 → 1 份＋標註")
    check(collapsed(r("請問一下,", 40)), "請問一下," + m(40), "鬼打牆：「請問一下,」×40 → 1 份＋標註")
    check(collapsed(r("嘖嘖", 50)), "嘖" + m(100), "鬼打牆：「嘖嘖」×50 → 嘖＋標註 100 次")
    check(collapsed(r(" even,", 41)), " even," + m(41), "鬼打牆：「 even,」×41")
    check(collapsed(r(" dhs", 27)), " dhs" + m(27), "鬼打牆：「dhs」×27")
    check(collapsed(r("什麼? ", 25)), "什麼? " + m(25), "鬼打牆：「什麼? 」×25")
    check(collapsed("前面 " + r("orthogonalization ", 5) + "後面"), "前面 orthogonalization" + m(5) + " 後面", "鬼打牆：長英文詞算 1 字，重複 5 次")
    check(collapsed("老師說林小安 林小安 林小安 林小安 林小安 然後"), "老師說林小安 " + m(5) + "然後", "鬼打牆：夾在句子中間也壓")
    check(collapsed("請問一下,請問一下,請問一下,請問一下,請問老師"), "請問一下," + m(4) + "請問老師", "鬼打牆：後面接的下一句開頭（請問老師）不能吃掉")
    check(collapsed("Wait, Wait, Wait, Wait, Wait"), "Wait, " + m(5), "鬼打牆：最後一個沒有標點也算一次")
    let counted = LoopFilter.collapse(r("請問一下,", 40))
    check("\(counted.runs) 處 \(counted.removed) 字", "1 處 195 字", "鬼打牆：數幾處、少幾字（不算空白、不算標註）")
    let wait = LoopFilter.collapse(r(", Wait", 36))
    check("\(wait.runs) 處 \(wait.removed) 字", "1 處 175 字", "鬼打牆：英文的空白不算字")
    let two = LoopFilter.collapse("開始" + r(" 林小安", 10) + "中間" + r("嘖嘖", 8) + "結束")
    check("\(two.text)｜\(two.runs)", "開始 林小安" + m(10) + "中間嘖" + m(16) + "結束｜2", "鬼打牆：同一段兩處各算一處")

    // ---- 反例：不能動
    let rollCall = "王小明 李大華 陳美玲 林志豪 張雅婷 黃俊傑 吳承恩 林小安"
    check(collapsed(rollCall), rollCall, "鬼打牆反例：點名一串不同名字各一次不動")
    check(collapsed("王小明 有 李大華 有 陳美玲 有 林志豪 有"), "王小明 有 李大華 有 陳美玲 有 林志豪 有", "鬼打牆反例：點名每個人答「有」不動")
    check(collapsed("對對對"), "對對對", "鬼打牆反例：對對對不動")
    check(collapsed("對對對對"), "對對對對", "鬼打牆反例：單一個字 4 次（對對對對）不動，要 8 次")
    check(collapsed("對對對，好，OK OK OK，那我們開始"), "對對對，好，OK OK OK，那我們開始", "鬼打牆反例：對對對、OK OK OK 在句子裡不動")
    check(collapsed("OK OK"), "OK OK", "鬼打牆反例：OK OK 不動")
    check(collapsed("哈哈哈哈"), "哈哈哈哈", "鬼打牆反例：哈哈哈哈不動")
    check(collapsed("我們看 matrix matrix matrix 跟 rank"), "我們看 matrix matrix matrix 跟 rank", "鬼打牆反例：同一個詞 3 次不動")
    check(collapsed("1111 2222 ......... ————————"), "1111 2222 ......... ————————", "鬼打牆反例：只有數字、標點的不動")
    check(collapsed("Ahhhh 好 Mississippi"), "Ahhhh 好 Mississippi", "鬼打牆反例：英文詞裡面的重複字母不動")
    check("\(LoopFilter.collapse(rollCall).runs)", "0", "鬼打牆反例：點名一處都不算")

    // ---- 跨小段：Whisper 常把每次重複切成一小段
    let names = (0..<28).map { TimedPiece(text: " 林小安", start: Double($0), end: Double($0) + 1) }
    let one = LoopFilter.filter(names)
    check("\(one.pieces.count) 段 \(one.pieces.first?.text ?? "") \(one.pieces.first?.start ?? -1) \(one.runs) 處 \(one.removed) 字",
          "1 段  林小安" + m(28) + " 0.0 1 處 81 字", "鬼打牆跨小段：28 段「 林小安」剩第一段＋標註、時間留著")
    let mixed = [TimedPiece(text: "老師點名：", start: 0, end: 1)]
        + (0..<4).map { TimedPiece(text: " 林小安", start: 1 + Double($0), end: 2 + Double($0)) }
        + [TimedPiece(text: "，好，下一位。", start: 5, end: 6)]
    let kept = LoopFilter.filter(mixed)
    check(kept.pieces.map { "\($0.text)@\(Int($0.start))" }.joined(separator: "|"), "老師點名：@0| 林小安" + m(4) + "@1|，好，下一位。@5", "鬼打牆跨小段：前後的段不動、中間重複的段拿掉")
    let differentNames = ["王小明", "李大華", "陳美玲", "林志豪", "張雅婷"].enumerated().map { TimedPiece(text: " " + $1, start: Double($0), end: Double($0) + 1) }
    check("\(LoopFilter.filter(differentNames).pieces.count)", "5", "鬼打牆跨小段反例：點名不同名字一段一個不動")
    let inside = LoopFilter.filter([TimedPiece(text: r("請問一下,", 40) + "那個", start: 10, end: 70)])
    check(inside.pieces.map { "\($0.text)@\(Int($0.start))-\(Int($0.end))" }.joined(), "請問一下," + m(40) + "那個@10-70", "鬼打牆：一小段裡面的也壓，時間不變")

    // ---- 電腦版另外兩層：幻覺句、整段迴圈（壓縮比 ≥2.4 且 ≥20 字）
    check(WhisperClean.isHallucination("請不吝點讚訂閱轉發打賞") ? "是" : "不是", "是", "幻覺句：請不吝點讚訂閱")
    check(WhisperClean.isHallucination("字幕由Amara.org社群提供") ? "是" : "不是", "是", "幻覺句：字幕由 Amara.org 提供")
    check(WhisperClean.isHallucination("今天講向量空間，基底") ? "是" : "不是", "不是", "幻覺句反例：上課的話不動")
    check(WhisperClean.isLoop(r("我們看一下這個式子我們看一下那個式子", 3)) ? "迴圈" : "不是", "迴圈", "整段迴圈：同一句換一個字重複，壓縮比高")
    check(WhisperClean.isLoop("今天我們要講的是向量空間，矩陣的秩和維度有關係") ? "迴圈" : "不是", "不是", "整段迴圈反例：正常一句話")
    check(WhisperClean.isLoop(r("哈", 12)) ? "迴圈" : "不是", "不是", "整段迴圈反例：不到 20 字不判")
    let cleaned = WhisperClean.clean([TimedPiece(text: "請不吝點讚訂閱轉發打賞", start: 0, end: 2),
                                      TimedPiece(text: "今天講向量空間", start: 2, end: 4),
                                      TimedPiece(text: r("我們看一下這個式子我們看一下那個式子", 3), start: 4, end: 30),
                                      TimedPiece(text: r(" 林小安", 6), start: 30, end: 34)])
    check(cleaned.pieces.map(\.text).joined(separator: "|"), "今天講向量空間|〔疑似鬼打牆，略過 54 字〕| 林小安" + m(6), "清理：幻覺句拿掉、整段迴圈換標註、重複壓縮")
    check("\(cleaned.hallucinations) \(cleaned.loops) \(cleaned.runs)", "1 1 1", "清理：各算幾處")
    check(cleaned.events.map(\.line).joined(separator: "｜"), "幻覺句拿掉：00:00–00:02，11 字｜疑似鬼打牆整段略過：00:04–00:30，54 字", "清理：每處記時間和字數（不寫稿的字）")
    check("\(WhisperPlan.tokenLimit(seconds: 5)) \(WhisperPlan.tokenLimit(seconds: 20)) \(WhisperPlan.tokenLimit(seconds: 300))", "91 224 224", "每段 token 上限：16＋每秒 15，WhisperKit 一窗最多 224")

    // ---- 轉完幾乎沒有字：當失敗（WhisperKit 窗內出錯不丟錯誤、只少字）
    check(WhisperPlan.tooFew(chars: 0, audioSeconds: 2_784) ? "失敗" : "完成", "失敗", "幾乎沒有字：46 分鐘 0 字當失敗")
    check(WhisperPlan.tooFew(chars: 500, audioSeconds: 2_784) ? "失敗" : "完成", "失敗", "幾乎沒有字：46 分鐘 500 字當失敗")
    check(WhisperPlan.tooFew(chars: 9_000, audioSeconds: 2_784) ? "失敗" : "完成", "完成", "幾乎沒有字：46 分鐘 9000 字是正常")
    check(WhisperPlan.tooFew(chars: 0, audioSeconds: 30) ? "失敗" : "完成", "完成", "幾乎沒有字：不到 1 分鐘不判")

    // ---- 切窗：找最安靜的 0.1 秒
    var loud = [Float](repeating: 0.5, count: 32_000)
    for i in 19_200..<20_800 { loud[i] = 0 }
    check("\(WhisperPlan.quietCut(loud, from: 16_000))", "20000", "切窗：切在最安靜的 0.1 秒中間")
    check("\(WhisperPlan.quietCut(loud, from: 40_000))", "32000", "切窗：找的起點超過長度就切在最後")

    // ---- 稿：英文接英文補空白、續錄分隔行
    let spaced = WhisperText.spaced([TimedPiece(text: " matrix", start: 0, end: 1), TimedPiece(text: "rank ", start: 1, end: 2),
                                     TimedPiece(text: "旋轉", start: 2, end: 3), TimedPiece(text: "NMR", start: 3, end: 4), TimedPiece(text: "  ", start: 4, end: 5)])
    check(spaced.map(\.text).joined(separator: "|"), "matrix| rank|旋轉|NMR", "Whisper 稿：英文接英文補空白、空白小段拿掉")
    let body = WhisperText.body([TimedPiece(text: "第一段的字。", start: 1, end: 2), TimedPiece(text: "第二段的字。", start: 101, end: 102)], partStarts: [0, 100])
    check(body, "第一段的字。\n\n——續錄第 2 段，從 01:40 起——\n\n第二段的字。\n", "Whisper 稿：續錄的每段之間放分隔行")
    check(WhisperText.body([TimedPiece(text: "hello", start: 0, end: 1), TimedPiece(text: "world", start: 1, end: 2)], partStarts: [0]), "hello world\n", "Whisper 稿：只有一段沒有分隔行")

    // ---- 紀錄和稿頭
    var record = WhisperRecord()
    record.parts = ["20261111-101000.caf"]
    record.audioSeconds = 2_784
    record.seconds = 261
    record.loadSeconds = 12
    record.runs = 3
    record.removed = 1_234
    check(record.timeLine, "轉換：261 秒（錄音 46:24，10.7 倍速，不含載入模型）；載入模型 12 秒", "Whisper 紀錄：轉換時間、倍速、載入另列")
    record.loops = 1
    record.hallucinations = 2
    check(record.filterLine, "鬼打牆：壓縮 3 處、少了 1234 字（同一片段連續重複 4 次以上留 1 份，標〔重複×N，已壓縮〕）；整段疑似迴圈 1 段（換成〔疑似鬼打牆，略過 N 字〕）；拿掉幻覺句 2 段（沒人講話時會出現的「請不吝點讚訂閱」這類）", "Whisper 紀錄：壓縮幾處幾字、迴圈、幻覺句")
    check(WhisperRecord().filterLine, "鬼打牆：沒有連續重複", "Whisper 紀錄：沒有就寫沒有")
    let header = WhisperText.header(title: "11/11 幾何", record: record, app: "0.23.5（build 40）", finished: "20261111-140500")
    check(header.contains("模型：WhisperKit large-v3-v20240930_626MB，語言 zh，沒有提示詞，簡轉繁") ? "有" : "沒有", "有", "Whisper 稿頭：寫模型、沒有提示詞")
    check(header.contains("壓縮 3 處") && header.hasPrefix("---\n") && header.hasSuffix("---\n") ? "對" : "錯", "對", "Whisper 稿頭：寫濾掉幾處、前後有 ---")
    check(record.reportLines.first ?? "", "下課 Whisper：還沒轉完", "Whisper 紀錄：info.txt 第一行")
    check(WhisperPlan.thermalName(.serious), "很熱", "Whisper 紀錄：熱的狀態寫中文")
    check(WhisperPlan.batteryText(level: 0.5, charging: true), "電量 50%（充電中）", "Whisper 紀錄：電量")
    check(WhisperPlan.batteryText(level: -1, charging: false), "電量讀不到", "Whisper 紀錄：電量讀不到")

    // ---- 待辦標記：再排一次（續錄後按停止）
    let fresh = WhisperJob(stem: "逐字稿/幾何/20261111-101500 20261111-101000", audioFolder: "錄音/幾何",
                           parts: ["20261111-101000.caf", "20261111-101000 第2段.caf"], partStarts: [0, 2_784], title: "11/11 幾何", queued: "20261111-120000")
    var pending = fresh
    pending.parts = ["20261111-101000.caf"]
    pending.partStarts = [0]
    pending.at = 600
    pending.attempts = 2
    pending.running = true
    let resumed = WhisperJob.merge(new: fresh, pending: pending, record: nil)
    check(resumed.map { "\($0.part) \(Int($0.at)) \($0.parts.count) \($0.attempts) \($0.running)" } ?? "nil", "0 600 2 0 false", "Whisper 待辦：沒轉完又續錄 → 接著原本的進度、段數變多、次數歸零")
    var done = WhisperRecord()
    done.parts = ["20261111-101000.caf"]
    done.audioSeconds = 2_784
    done.seconds = 261
    done.runs = 2
    done.result = "完成（20261111-110000）"
    let onlyNew = WhisperJob.merge(new: fresh, pending: nil, record: done)
    check(onlyNew.map { "\($0.part) \(Int($0.doneAudio)) \($0.priorRuns) \(Int($0.priorSeconds))" } ?? "nil", "1 2784 2 261", "Whisper 待辦：第 1 段轉完過 → 只轉第 2 段，數字帶過來")
    done.parts = fresh.parts
    check(WhisperJob.merge(new: fresh, pending: nil, record: done) == nil ? "不用轉" : "要轉", "不用轉", "Whisper 待辦：同樣的段都轉完過就不再轉")
    var failedRecord = WhisperRecord()
    failedRecord.parts = ["20261111-101000.caf"]
    failedRecord.result = "放棄：試了 3 次"
    check(WhisperJob.merge(new: fresh, pending: nil, record: failedRecord).map { "\($0.part)" } ?? "nil", "0", "Whisper 待辦：上次放棄的從頭轉")
    let data = try? JSONEncoder().encode(resumed)
    let back = data.flatMap { try? JSONDecoder().decode(WhisperJob.self, from: $0) }
    check(back == resumed ? "一樣" : "不一樣", "一樣", "Whisper 待辦：存檔讀回來一樣")
    check(fresh.offset(of: 1) == 2_784 ? "對" : "錯", "對", "Whisper 待辦：第 2 段從整場 46:24 開始")
    var noStarts = fresh
    noStarts.partStarts = nil
    noStarts.doneAudio = 1_000
    check("\(Int(noStarts.offset(of: 1)))", "1000", "Whisper 待辦：沒存每段開始秒數就用已轉完的長度")
    check(pending.progressLine, "第 1／1 段 10:00", "Whisper 待辦：進度那行")

    // ---- 實驗模式：字數不到 Apple 現用 10% 寫「疑似失敗」
    check(LabReport.suspicious(chars: 2, baseline: 10_000) ? "疑似失敗" : "完成", "疑似失敗", "實驗模式：Apple 聽寫只出 2 字 → 疑似失敗")
    check(LabReport.suspicious(chars: 5_000, baseline: 10_000) ? "疑似失敗" : "完成", "完成", "實驗模式：字數一半 → 完成")
    check(LabReport.suspicious(chars: 2, baseline: nil) ? "疑似失敗" : "完成", "完成", "實驗模式：沒有對照組不判")
    check(LabReport.rowStatus(seconds: 261, load: 12, chars: 9_000, baseline: 10_000), "完成，261 秒（另載入模型 12 秒），9000 字", "實驗模式：進度寫轉換和載入秒數")
    check(LabReport.rowStatus(seconds: 50, load: nil, chars: 2, baseline: 10_000).hasPrefix("疑似失敗") ? "對" : "錯", "對", "實驗模式：進度寫疑似失敗")
    let lab = [LabResult(name: "Apple 現用", note: "", pieces: [], text: r("向量很長", 30), seconds: 60, error: nil),
               LabResult(name: "Apple 聽寫＋關鍵字", note: "", pieces: [], text: "多少？", seconds: 40, error: nil),
               LabResult(name: "Whisper", note: "", pieces: [], text: r("向量很長", 29), seconds: 261, error: nil, loadSeconds: 12)]
    let md = LabReport.markdown(file: "x.caf", course: "解析幾何", audioSeconds: 2_784, keywords: [], results: lab, app: "0.23.5")
    check(md.contains("| Apple 聽寫＋關鍵字 | 疑似失敗") ? "有" : "沒有", "有", "實驗模式：報告寫疑似失敗")
    check(md.contains("| Whisper | 完成 | 261 秒（10.7 倍速）；另載入模型 12 秒") ? "有" : "沒有", "有", "實驗模式：報告的 Whisper 轉換時間不含載入、載入另列")

    // ---- v0.28.0 錄音中一段卡住或沒字：切兩半重轉（LoopRetry）。結果用手做的 Result，不靠壓縮比；字是編的
    func retryPiece(_ text: String, _ start: Double, _ end: Double) -> TimedPiece { TimedPiece(text: text, start: start, end: end) }
    func reasonName(_ reason: LoopRetry.Reason?) -> String {
        switch reason {
        case .loop?: return "卡住"
        case .empty?: return "沒字"
        case nil: return "不用"
        }
    }
    let retryStuck = WhisperClean.Result(pieces: [retryPiece("我們先算這一列，然後", 0, 3), retryPiece("就是" + m(60), 3, 3)], runs: 1, removed: 118)
    check(reasonName(LoopRetry.reason(retryStuck, seconds: 15)), "卡住", "卡住重轉：壓掉 118 字 → 重轉")
    let retryLoopEvent = WhisperClean.Result(pieces: [retryPiece("〔疑似鬼打牆，略過 40 字〕", 0, 5)], loops: 1,
                                             events: [WhisperClean.Event(kind: .loop, start: 0, end: 5, chars: 40)])
    check(reasonName(LoopRetry.reason(retryLoopEvent, seconds: 15)), "卡住", "卡住重轉：整段迴圈 → 重轉")
    check(reasonName(LoopRetry.reason(WhisperClean.Result(pieces: [retryPiece("對" + m(8), 0, 1)], runs: 1, removed: 7), seconds: 15)), "不用",
          "卡住重轉反例：對×8 只壓掉 7 字不重轉")
    check(reasonName(LoopRetry.reason(WhisperClean.Result(pieces: [retryPiece("今天講到第三題", 0, 3)]), seconds: 15)), "不用", "卡住重轉反例：正常的段不重轉")
    check(reasonName(LoopRetry.reason(WhisperClean.Result(pieces: [retryPiece("", 0, 15)]), seconds: 15)), "沒字", "沒字重轉：15 秒整段沒字 → 重轉")
    check(reasonName(LoopRetry.reason(WhisperClean.Result(pieces: []), seconds: 6)), "不用", "沒字重轉反例：不到 8 秒（切不成兩個 4 秒）不重轉")
    check(reasonName(LoopRetry.reason(retryStuck, seconds: 7)), "不用", "卡住重轉反例：不到 8 秒不重轉")
    check("\(LoopRetry.realChars([retryPiece(" 好 " + m(15), 0, 1), retryPiece("〔疑似鬼打牆，略過 40 字〕", 1, 2), retryPiece("大家好", 2, 3)]))", "4",
          "卡住重轉：真的字不算空白、不算標註")
    check("\(LoopRetry.garbage(retryLoopEvent)) \(LoopRetry.garbage(retryStuck))", "40 118", "卡住重轉：垃圾＝壓掉的字＋整段略過的字")

    // 切點：10 秒的聲音，中間 40%–60% 最安靜的 0.1 秒（樣本 80000 起）→ 切在 80800；7 秒切不成兩個 4 秒
    var retryAudio = [Float](repeating: 0.5, count: 160_000)
    for i in 80_000..<81_600 { retryAudio[i] = 0 }
    check(LoopRetry.splitPoint(retryAudio).map { "\($0)" } ?? "nil", "80800", "卡住重轉：切在中間最安靜處")
    check(LoopRetry.splitPoint([Float](repeating: 0.5, count: 112_000)).map { "\($0)" } ?? "nil", "nil", "卡住重轉：不到 8 秒不切")

    // 換不換
    let retryBetter = WhisperClean.Result(pieces: [retryPiece("我們先算這一列，然後就要換位", 0, 4), retryPiece("答案是第二個，因為分母不能是零", 7.5, 12)])
    check(LoopRetry.accept(original: retryStuck, retry: retryBetter, reason: .loop, end: 15) ? "換" : "不換", "換", "卡住重轉：重轉的乾淨、字比較多 → 換")
    let retryStillStuck = WhisperClean.Result(pieces: [retryPiece("我們先算這一列，然後", 0, 3), retryPiece("就是" + m(30), 3, 3),
                                                       retryPiece("答案是第二個", 7.5, 9)], runs: 1, removed: 58)
    check(LoopRetry.accept(original: retryStuck, retry: retryStillStuck, reason: .loop, end: 15) ? "換" : "不換", "換",
          "卡住重轉：前半段還卡（標註留著）、後半段救回來 → 換")
    let retryFewer = WhisperClean.Result(pieces: [retryPiece("我們", 0, 1)])
    check(LoopRetry.accept(original: retryStuck, retry: retryFewer, reason: .loop, end: 15) ? "換" : "不換", "不換", "卡住重轉反例：重轉的字比較少不換")
    let retryHallucination = WhisperClean.Result(pieces: [retryPiece("我們先算這一列，然後就要換位答案是第二個", 0, 12)], hallucinations: 1)
    check(LoopRetry.accept(original: retryStuck, retry: retryHallucination, reason: .loop, end: 15) ? "換" : "不換", "不換", "卡住重轉反例：重轉出現幻覺句不換")
    let retryOutside = WhisperClean.Result(pieces: [retryPiece("我們先算這一列，然後就要換位", 0, 4), retryPiece("答案是第二個，因為分母不能是零", 16, 18)])
    check(LoopRetry.accept(original: retryStuck, retry: retryOutside, reason: .loop, end: 15) ? "換" : "不換", "不換", "卡住重轉反例：時間跑到這段聲音外面不換")
    let retryEmpty = WhisperClean.Result(pieces: [retryPiece("", 0, 15)])
    check(LoopRetry.accept(original: retryEmpty, retry: retryBetter, reason: .empty, end: 15) ? "換" : "不換", "換", "沒字重轉：補到一句以上乾淨的字 → 換")
    check(LoopRetry.accept(original: retryEmpty, retry: WhisperClean.Result(pieces: [retryPiece("謝謝大家", 3, 4)]), reason: .empty, end: 15) ? "換" : "不換", "不換",
          "沒字重轉反例：只補到短短一句（多半是沒人講話時的幻覺）不換")
    check(LoopRetry.accept(original: retryEmpty, retry: retryStillStuck, reason: .empty, end: 15) ? "換" : "不換", "不換", "沒字重轉反例：重轉的又卡住不換")
}
