import Foundation

// v0.26.1 Sources/RecordWatch.swift：打斷結束後接不回麥克風的快速重試排程（0.5、1、2、4 秒，最多 4 次、成功就停）、麥克風共用那一行。
// main.swift 只呼叫 recoverTests(check)。

func recoverTests(_ check: @escaping (String, String, String) -> Void) {
    func show(_ r: (tries: Int, recovered: Bool, waited: Double)) -> String {
        "\(r.tries) 次" + (r.recovered ? "接回" : "沒接回") + String(format: "，等 %.1f 秒", r.waited)
    }
    check(RecoverRetry.delays.map { String(format: "%.1f", $0) }.joined(separator: ","), "0.5,1.0,2.0,4.0", "快速重試：間隔 0.5、1、2、4 秒")
    check(show(RecoverRetry.simulate([true])), "1 次接回，等 0.5 秒", "快速重試：第 1 次就接回，不再試")
    check(show(RecoverRetry.simulate([false, false, true])), "3 次接回，等 3.5 秒", "快速重試：前兩次失敗、第 3 次接回就停")
    check(show(RecoverRetry.simulate([])), "4 次沒接回，等 7.5 秒", "快速重試：全失敗最多 4 次（之後交給看門狗）")
    check(show(RecoverRetry.simulate([false, false, false, false, true])), "4 次沒接回，等 7.5 秒", "快速重試：第 5 次不會試")
    check(RecoverRetry.delay(afterRetries: 4).map { "\($0)" } ?? "不再試", "不再試", "快速重試：試滿 4 次後不再排")
    check(RecoverRetry.delay(afterRetries: -1).map { "\($0)" } ?? "不再試", "不再試", "快速重試：負數不排")
    check(MicShare.line(false), "麥克風：獨佔（record）", "麥克風共用：關＝獨佔")
    check(MicShare.line(true), "麥克風：和別的 App 共用（playAndRecord＋mixWithOthers）", "麥克風共用：開＝playAndRecord＋mixWithOthers")

    // ---- v0.28.0 獨佔麥克風在背景接不回來：只在獨佔、碰到 '!int'／'!pla'、這場還沒改過時，改成共用再接一次
    check("\(MicFallback.shouldTryShared(code: 0x21696E74, shareMic: false, alreadyShared: false))", "true", "改共用：獨佔、'!int' → 試")
    check("\(MicFallback.shouldTryShared(code: 0x21706C61, shareMic: false, alreadyShared: false))", "true", "改共用：獨佔、'!pla' → 試")
    check("\(MicFallback.shouldTryShared(code: 560557684, shareMic: true, alreadyShared: false))", "false", "改共用：本來就共用 → 不用改")
    check("\(MicFallback.shouldTryShared(code: 561015905, shareMic: false, alreadyShared: true))", "false", "改共用：這場改過了 → 不再改")
    check("\(MicFallback.shouldTryShared(code: -50, shareMic: false, alreadyShared: false))", "false", "改共用：別的錯誤照原本流程")

    // ---- v0.28.0 錄音中斷的一段：稿裡那行、稿頭、依錄音位置排進卡片之間（時間都是編的）
    let gapA = RecordGap(at: 754, lost: 125, from: "20260105-100105", to: "20260105-100310")
    let gapB = RecordGap(at: 2000, lost: 15, from: "20260105-103010", to: "20260105-103025")
    check(gapA.line, "〔錄音中斷 2:05（10:01–10:03），這段沒錄到〕", "錄音中斷：稿裡那一行（少了多久、牆上時間）")
    check(gapA.spot, "錄音 12:34 處少了 2:05（10:01–10:03）", "錄音中斷：位置那句")
    check(RecordGap.hourMinute("壞掉的"), "?", "錄音中斷：時間格式不對寫 ?")
    let stampFormat = DateFormatter()
    stampFormat.locale = Locale(identifier: "en_US_POSIX")
    stampFormat.dateFormat = "yyyyMMdd-HHmmss"
    let stampDate: Date? = stampFormat.date(from: "20260105-100105")
    check(stampDate.map { RecordGap.stamp($0) } ?? "nil", "20260105-100105", "錄音中斷：牆上時間寫成 yyyyMMdd-HHmmss")
    check(GapMarks.headLine([]) ?? "nil", "nil", "錄音中斷：沒斷過不寫稿頭")
    check(GapMarks.headLine([gapB, gapA]) ?? "nil", "錄音中斷：錄音 12:34 處少了 2:05（10:01–10:03）、錄音 33:20 處少了 0:15（10:30–10:30）；這些時間沒錄到",
          "錄音中斷：稿頭一行（照位置排）")
    func slots(_ list: [GapMarks.Slot]) -> String {
        list.map { slot -> String in
            switch slot {
            case .block(let i): return "卡\(i)"
            case .gap(let g): return "斷@\(Int(g.at))"
            }
        }.joined(separator: ",")
    }
    func gap(at: Double) -> RecordGap { RecordGap(at: at, lost: 20, from: "20260105-100000", to: "20260105-100020") }
    check(slots(GapMarks.order(starts: [0, 60, 120], gaps: [gap(at: 200), gap(at: 90), gap(at: 60)])), "卡0,斷@60,卡1,斷@90,卡2,斷@200",
          "錄音中斷：放在第一個開始時間 ≥ 位置的卡前面；斷在卡中間排在那張後面；比全部晚的接最後")
    check(slots(GapMarks.order(starts: [], gaps: [gap(at: 5)])), "斷@5", "錄音中斷：還沒有卡也留得住")
    check(slots(GapMarks.order(starts: [0, 60], gaps: [])), "卡0,卡1", "錄音中斷：沒斷過照原樣")
    let timedBlocks: [(start: Double, text: String)] = [(start: 0, text: "甲"), (start: 60, text: "乙")]
    let inserted: [String] = GapMarks.insert(timedBlocks, gaps: [gap(at: 30)])
    check(inserted.joined(separator: "|"), "甲|〔錄音中斷 0:20（10:00–10:00），這段沒錄到〕|乙", "錄音中斷：插進有時間的塊之間")
    let coded: Data? = try? JSONEncoder().encode([gapA])
    let decoded: [RecordGap] = coded.flatMap { try? JSONDecoder().decode([RecordGap].self, from: $0) } ?? []
    check(decoded == [gapA] ? "一樣" : "不一樣", "一樣", "錄音中斷：存檔讀回一樣")
}
