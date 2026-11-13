import Foundation

// v0.20：錄音中斷看得到、留得下紀錄。
// 起因：真機實測一場錄音，牆上時間 2:51、音檔只有 1:36，
// 錯誤資料裡什麼都沒有——v0.19 以前來電、Siri、別的 App 搶聲音時錄音停掉不記一筆、接不回來也不講，畫面照樣顯示錄音中（只是秒數不動）。
// 這裡只放算數（不碰麥克風），雲端編譯前 shape_check 會跑。

/// 每秒拿「這段按下錄音後過了幾秒（牆上時間）」和「真的錄進檔案幾秒」比：
/// 錄進檔的秒數超過 stallAfter 秒不動＝錄音停了；又開始動＝接回來了，中間少了幾秒。
struct RecordWatch {
    enum Event: Equatable {
        /// 停了：audio 是停在錄音第幾秒，silentFor 是已經幾秒沒聲音進來。
        case stalled(audio: Double, silentFor: Double)
        /// 接回來了：中間少了幾秒（牆上過的時間減掉錄到的）。
        case resumed(lost: Double)
    }

    /// 10 秒：iOS 給麥克風一批約 0.1 秒，正常錄音時錄進檔的秒數每秒都在長；10 秒不動不會是正常的。【我推論】門檻
    static let stallAfter: Double = 10

    private var lastAudio: Double = 0
    private var lastGrowWall: Double = 0
    private(set) var stalled = false
    /// 這段一共停過幾次、少了幾秒（停到按停止還沒接回來的那次，在 finish 才算進去）。
    private(set) var stallCount = 0
    private(set) var lostSeconds: Double = 0

    init() {}

    /// wall：按下錄音後過了幾秒；audio：錄進檔幾秒。
    mutating func tick(wall: Double, audio: Double) -> Event? {
        if audio > lastAudio + 0.05 {
            // 牆上過的減掉這次錄到的增量＝停的那段；正常抖動（一批晚到）不算
            let lost = max(0, (wall - lastGrowWall) - (audio - lastAudio))
            lastAudio = audio
            lastGrowWall = wall
            guard stalled else { return nil }
            stalled = false
            lostSeconds += lost
            return .resumed(lost: lost)
        }
        let silent = wall - lastGrowWall
        if !stalled, silent >= Self.stallAfter {
            stalled = true
            stallCount += 1
            return .stalled(audio: lastAudio, silentFor: silent)
        }
        return nil
    }

    /// 停著的話已經幾秒沒聲音；沒停是 nil。
    func silentFor(wall: Double) -> Double? {
        stalled ? wall - lastGrowWall : nil
    }

    /// 按停止時那一行：實際經過多久、錄到多久；差 3 秒以上才講少了多少。
    static func stopLine(wall: Double, audio: Double, stalls: Int) -> String {
        let lost = wall - audio
        var line = "這段實際經過 \(clock(wall))，錄到 \(clock(audio))"
        if lost >= 3 {
            line += "，少了 \(clock(lost))"
            line += stalls > 0 ? "（錄音中停過 \(stalls) 次）" : "（App 沒看到停：可能是收音一開始就慢，或系統暫停了 App）"
        }
        return line
    }

    /// 畫面紅字。
    static func banner(silentFor: Double) -> String {
        "錄音停了：已經 \(Int(silentFor)) 秒沒有聲音進來（計時也不會動）。App 正在試著接回來；接不回來請按停止再續錄。"
    }

    /// 跟 formatClock 一樣的寫法（這個檔不靠畫面那邊的函式，shape_check 才編得過）。
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// v0.26.1：打斷結束後第一次接不回來（多半是 Siri 剛叫出來又關掉、麥克風還沒放手），0.5、1、2、4 秒各再試一次，成功就停；
/// 4 次都失敗才交回 10 秒看門狗（以前第一次失敗就乾等看門狗，每次少約 11 秒）。這裡只算排程，接麥克風在 Recorder.swift。
enum RecoverRetry {
    static let delays: [Double] = [0.5, 1, 2, 4]

    /// 已經快速重試了 done 次（都失敗）之後，下一次要等幾秒；nil＝不再快速重試
    static func delay(afterRetries done: Int) -> Double? {
        done >= 0 && done < delays.count ? delays[done] : nil
    }

    /// 測試用：outcomes[i]＝第 i 次快速重試成不成（打斷結束當下那一次不算）。回傳試了幾次、最後有沒有接回、一共等了幾秒。
    static func simulate(_ outcomes: [Bool]) -> (tries: Int, recovered: Bool, waited: Double) {
        var tries = 0
        var waited = 0.0
        while let wait = delay(afterRetries: tries) {
            waited += wait
            let ok = tries < outcomes.count ? outcomes[tries] : false
            tries += 1
            if ok { return (tries, true, waited) }
        }
        return (tries, false, waited)
    }
}

/// v0.26.1「麥克風和別的 App 共用」：開＝.playAndRecord＋mixWithOthers（別的 App 播聲音、錄音不會打斷我們；別的 App 的聲音可能一起錄進去），
/// 關＝.record（原本，獨佔）。只在按下錄音時套用。
enum MicShare {
    static let key = "micShared"

    static func line(_ shared: Bool) -> String {
        shared ? "麥克風：和別的 App 共用（playAndRecord＋mixWithOthers）" : "麥克風：獨佔（record）"
    }
}
