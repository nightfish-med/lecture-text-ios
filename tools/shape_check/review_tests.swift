import Foundation

// v0.23.2 Sources/ReviewPlan.swift：重試／停用的決定（規格 B6）、待送批次合併、停止後補定稿命中（規格 A③）、
// 狀態列與綠字小卡的字、正式課名換回簡稱。main.swift 只呼叫 reviewTests(check)。

func reviewTests(_ check: @escaping (String, String, String) -> Void) {
    func step(_ s: ReviewRetry.Step) -> String {
        switch s {
        case .parse: return "parse"
        case .retry(let after): return "retry \(after)"
        case .giveUp: return "giveUp"
        case .reject: return "reject"
        case .stop(let reason): return "stop \(reason.rawValue)"
        }
    }

    // ---- 重試與停用（B6）
    check(step(ReviewRetry.after(status: 200, attempts: 1, retryAfter: nil)), "parse", "送審 200 → 解析")
    check(step(ReviewRetry.after(status: 401, attempts: 1, retryAfter: nil)), "stop badKey", "送審 401 → 停用（金鑰無效）")
    check(step(ReviewRetry.after(status: 403, attempts: 1, retryAfter: nil)), "stop badKey", "送審 403 → 停用（金鑰無效）")
    check(step(ReviewRetry.after(status: 402, attempts: 1, retryAfter: nil)), "stop noCredit", "送審 402 → 停用（額度）")
    check(step(ReviewRetry.after(status: 429, attempts: 1, retryAfter: "20")), "retry 20.0", "送審 429 照 retry-after")
    check(step(ReviewRetry.after(status: 429, attempts: 1, retryAfter: "120")), "retry 60.0", "送審 429 最多等 60 秒")
    check(step(ReviewRetry.after(status: 429, attempts: 1, retryAfter: nil)), "retry 15.0", "送審 429 沒給 retry-after 等 15 秒")
    check(step(ReviewRetry.after(status: 429, attempts: 3, retryAfter: "5")), "giveUp", "送審 429 試滿 3 次放棄")
    check(step(ReviewRetry.after(status: 529, attempts: 1, retryAfter: nil)), "retry 5.0", "送審 529 第 1 次等 5 秒")
    check(step(ReviewRetry.after(status: 503, attempts: 2, retryAfter: nil)), "retry 15.0", "送審 5xx 第 2 次等 15 秒")
    check(step(ReviewRetry.after(status: 500, attempts: 3, retryAfter: nil)), "giveUp", "送審 5xx 試滿 3 次放棄")
    check(step(ReviewRetry.after(status: 400, attempts: 1, retryAfter: nil)), "reject", "送審 400 不重送")
    check(step(ReviewRetry.after(status: 404, attempts: 1, retryAfter: nil)), "reject", "送審 404 當 400 不重送")
    check(step(ReviewRetry.afterNetworkError(offline: true, attempts: 3)), "retry 5.0", "沒網路不算次數，5 秒後再看")
    check(step(ReviewRetry.afterNetworkError(offline: false, attempts: 1)), "retry 5.0", "逾時第 1 次等 5 秒")
    check(step(ReviewRetry.afterNetworkError(offline: false, attempts: 3)), "giveUp", "逾時試滿 3 次放棄")
    check(step(ReviewRetry.afterUnreadable(attempts: 1)), "retry 0.0", "回覆解析失敗重送一次")
    check(step(ReviewRetry.afterUnreadable(attempts: 2)), "giveUp", "回覆解析失敗第二次就放棄")

    // ---- 待送超過 4 批合併成每批最多 600 字
    func batch(_ id: Int, _ units: [Int], _ state: ReviewBatch.State = .pending, attempts: Int = 0) -> ReviewBatch {
        var b = ReviewBatch(id: id, unitIDs: units, context: "前文\(id)", audioStart: Double(id * 15), audioEnd: Double(id * 15 + 15))
        b.state = state
        b.attempts = attempts
        return b
    }
    var chars: [Int: Int] = [:]
    for id in 1...20 { chars[id] = 150 }
    let four = [batch(1, [1]), batch(2, [2]), batch(3, [3]), batch(4, [4])]
    check("\(ReviewQueue.merge(four, chars: chars).map(\.id))", "[1, 2, 3, 4]", "待送 4 批不合併")
    let six = [batch(1, [1], .done), batch(2, [2]), batch(3, [3], attempts: 2), batch(4, [4]), batch(5, [5]), batch(6, [6]), batch(7, [7])]
    let merged = ReviewQueue.merge(six, chars: chars)
    check(merged.map { "\($0.id):\($0.unitIDs.map(String.init).joined(separator: ","))" }.joined(separator: " "),
          "1:1 2:2,3,4,5 6:6,7", "待送 6 批 → 每批最多 600 字，已完成的不動")
    check("\(merged[1].context) \(merged[1].audioStart)-\(merged[1].audioEnd) 次數\(merged[1].attempts)", "前文2 30.0-90.0 次數2",
          "合併的批用第一批的前文和開始時間、次數取大的")
    chars[30] = 700
    let big = [batch(1, [30]), batch(2, [2]), batch(3, [3]), batch(4, [4]), batch(5, [5])]
    check("\(ReviewQueue.merge(big, chars: chars).map(\.id))", "[1, 2]", "超過 600 字的一批不拆、不併")
    check("\(ReviewQueue.pendingCount([batch(1, [1], .done), batch(2, [2], .sending), batch(3, [3]), batch(4, [4], .abandoned)]))", "2",
          "待送數＝待送＋送出中")

    // ---- 停止後補定稿命中（A③）
    func fix(_ id: Int, s: Int, rules: [LiveFixRule], verdict: FixVerdict = .passed, hits: Int? = nil) -> FixRecord {
        var f = FixRecord(id: id, batch: 1, s: s, at: 20, unitText: "", wrong: rules.first?.core ?? "", right: rules.first?.coreRight ?? "",
                          type: "同音", evidence: "前後文", verdict: verdict, rules: rules)
        f.finalHits = hits
        return f
    }
    let rule = LiveFixRule(wrong: "消去發", right: "消去法", source: .haiku)
    let units = [LiveUnit(id: 1, text: "我們用高斯消去發來做", start: 10, end: 12, offsetStart: 0, offsetEnd: 10),
                 LiveUnit(id: 2, text: "另外一段", start: 40, end: 42, offsetStart: 10, offsetEnd: 14)]
    let finalPieces = [TimedPiece(text: "我們用高斯", start: 9, end: 10.5), TimedPiece(text: "消去法來做", start: 10.5, end: 12),
                       TimedPiece(text: "很遠的消去發", start: 30, end: 31), TimedPiece(text: "沒時間", start: -1, end: -1)]
    let finalText = finalPieces.map(\.text).joined()
    let annotated = ReviewFinal.annotate([fix(1, s: 1, rules: [rule]), fix(2, s: 1, rules: [rule], verdict: .notNear),
                                          fix(3, s: 1, rules: [rule], hits: 9), fix(4, s: 99, rules: [rule])],
                                         units: units, finalText: finalText, finalPieces: finalPieces)
    check("\(annotated[0].finalHits ?? -1) \(annotated[0].finalWindow ?? "nil") \(annotated[0].windowHas ?? "nil")",
          "1 我們用高斯消去法來做 right", "定稿命中：次數、同時間的字、windowHas＝right（時間窗外和沒時間的不算）")
    check("\(annotated[1].finalHits == nil) \(annotated[2].finalHits ?? -1) \(annotated[3].finalHits == nil)", "true 9 true",
          "沒通過、已補過、找不到單位的不動")
    check([ReviewFinal.has("甲消去發", wrong: "消去發", right: "消去法"), ReviewFinal.has("消去發消去法", wrong: "消去發", right: "消去法"),
           ReviewFinal.has("別的字", wrong: "消去發", right: "消去法")].joined(separator: " "), "wrong both neither", "windowHas 四種")
    let anchored = LiveFixRule(wrong: "一個洛加到", right: "一個row加到", keepLeft: 2, keepRight: 2, source: .haiku)
    check("\(LiveFix.count("第一個洛加到第二個洛", rules: [anchored]))", "1", "定位擴充的規則在定稿只算真的對到的地方")

    // ---- 狀態列、橫幅、小卡
    check(ReviewText.status(done: 0, passed: 0, blocked: 0, lastLatency: nil, stop: nil), "Haiku：等待第一批", "狀態列：還沒回來")
    check(ReviewText.status(done: 3, passed: 2, blocked: 1, lastLatency: 4.24, stop: nil), "Haiku：已送 3 批・改 2 處・擋 1 處・上一批 4.2 秒",
          "狀態列：已送、改、擋、上一批秒數")
    check(ReviewText.status(done: 3, passed: 2, blocked: 1, lastLatency: 4, stop: .costCap), "Haiku：已停（花費到上限）・已送 3 批・改 2 處・擋 1 處",
          "狀態列：停用")
    check(ReviewText.closed("這門課的開關關著"), "Haiku：已關閉（這門課的開關關著）", "狀態列：已關閉")
    check(ReviewText.offline(pending: 3), "沒有網路，3 批待送；網路回來自動補送", "橫幅：沒有網路")
    check("\(ReviewStop.badKey.banner.contains("金鑰無效")) \(ReviewStop.costCap.banner.contains("花費到上限")) \(ReviewStop.rejected.banner.hasPrefix("Haiku 暫停"))",
          "true true true", "橫幅：金鑰無效、花費到上限、Haiku 暫停")
    check(ReviewText.slides(nil) + "／" + ReviewText.slides("lecture-17"), "沒有投影片／投影片：lecture-17", "狀態列：投影片")
    check(ReviewText.cardSource(nil), "課程對照表改的；只改畫面，存檔的稿還是原字", "小卡：對照表")
    check(ReviewText.cardSource(LiveFixRule(wrong: "pibbet", right: "pivot", source: .promoted, evidence: "升級", fixID: 3)),
          "這場同一個改法通過 2 次，整場一起改（程式驗過）；只改畫面，存檔的稿還是原字", "小卡：同字升級的全場規則")
    let promotedRule = LiveFixRule(wrong: "pibbet", right: "pivot", source: .promoted, evidence: "升級", fixID: 3)
    check(LiveFix.rules(course: nil, off: ["pibbet"], learned: [promotedRule]).contains(promotedRule) ? "還在" : "關掉了", "關掉了",
          "小卡：「這場不再改這個詞」也關得掉升級的規則")
    var slideRule = rule
    slideRule.evidence = "投影片p.6"
    check(ReviewText.cardSource(slideRule), "Haiku 依 p.6 改的（程式驗過）；只改畫面，存檔的稿還是原字", "小卡：Haiku 依投影片頁")
    slideRule.evidence = "詞表"
    check(ReviewText.cardSource(slideRule), "Haiku 依 詞表 改的（程式驗過）；只改畫面，存檔的稿還是原字", "小卡：Haiku 依詞表")
    slideRule.evidence = nil
    check(ReviewText.cardSource(slideRule), "Haiku 改的（程式驗過）；只改畫面，存檔的稿還是原字", "小卡：Haiku 沒寫依據")

    // ---- 指定課名：正式名換回簡稱（標題、資料夾和上課時段錄的一樣）
    check([CourseSchedule.shortName("解析幾何"), CourseSchedule.shortName("美術鑑賞"), CourseSchedule.shortName("日文"),
           CourseSchedule.shortName("不在課表")].joined(separator: " "), "幾何 美術 日文 不在課表", "正式課名換回簡稱")

    // ---- 改字紀錄存讀（off、userOff、批次狀態，續錄讀得回）
    var log = ReviewLog(course: "解析幾何", slides: "lecture-17.pdf")
    log.off = ["消去發"]
    log.batches = [batch(1, [1], .done)]
    var off = fix(1, s: 1, rules: [rule])
    off.userOff = true
    log.fixes = [off]
    log.maxUnitID = 7
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let back = (try? encoder.encode(log)).flatMap { try? JSONDecoder().decode(ReviewLog.self, from: $0) }
    check("\(back?.off ?? []) \(back?.fixes.first?.userOff ?? false) \(back?.maxUnitID ?? 0) \(back?.learnedRules.count ?? -1)",
          "[\"消去發\"] true 7 0", "改字紀錄存讀：off、userOff、最大單位編號；被按掉的規則續錄不再套")
}
