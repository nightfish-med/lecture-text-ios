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
}
