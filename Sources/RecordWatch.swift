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

/// v0.28.0：獨佔麥克風（.record）在背景被打斷後接不回來時，這場暫時改成和別的 App 共用再接一次。
/// 起因：真機一場錄音在背景被打斷，打斷結束後 setActive 回 '!pla'，之後是 '!int'（背景不能啟用不能混音的聲音工作階段），
/// 接不回來以後 App 在背景被系統暫停，回前景才接回，中間十幾分鐘沒錄到。
/// 【推論，未實機驗證】可混音的工作階段在背景可以啟用。只在獨佔、碰到這兩個錯誤碼、這場還沒改過時試；
/// 改了還是不行就改回獨佔，照原本的流程（快速重試、看門狗）。接回來以後這場維持共用到按停止（錄音中換回獨佔要重設類別，可能又斷一次）；下一場照開關重設。
enum MicFallback {
    /// '!int'（0x21696E74）、'!pla'（0x21706C61）：AVAudioSession 的 NSOSStatusErrorDomain 錯誤碼
    static let codes: Set<Int> = [560557684, 561015905]

    static func shouldTryShared(code: Int, shareMic: Bool, alreadyShared: Bool) -> Bool {
        !shareMic && !alreadyShared && codes.contains(code)
    }
}

/// v0.28.0：錄音中斷的一段（看門狗看到停了、之後又接回來）。存進這場（SavedRun.gaps，場的 json），
/// 停止後的逐字稿、md、PDF 在那個錄音位置插一行〔錄音中斷…〕，稿頭也寫一行。
/// 起因：錄音接起來是連著的，中間少了十幾分鐘，稿裡看不出來（前後兩個人講的話接得像同一個人）。
struct RecordGap: Codable, Equatable {
    /// 整場錄音第幾秒斷的（續錄從第一段開頭算）
    var at: Double
    /// 少了幾秒（牆上時間過了、錄音沒長的那段）
    var lost: Double
    /// 牆上時間起訖（yyyyMMdd-HHmmss）
    var from: String
    var to: String

    /// 稿裡那一行：〔錄音中斷 2:05（10:01–10:03），這段沒錄到〕
    var line: String {
        "〔錄音中斷 \(RecordWatch.clock(lost))（\(Self.hourMinute(from))–\(Self.hourMinute(to))），這段沒錄到〕"
    }

    /// 稿頭、紀錄用：錄音 12:34 處少了 2:05（10:01–10:03）
    var spot: String {
        "錄音 \(RecordWatch.clock(at)) 處少了 \(RecordWatch.clock(lost))（\(Self.hourMinute(from))–\(Self.hourMinute(to))）"
    }

    /// yyyyMMdd-HHmmss → HH:mm；格式不對寫 ?
    static func hourMinute(_ stamp: String) -> String {
        let c = Array(stamp)
        guard c.count == 15, c[8] == "-" else { return "?" }
        return "\(String(c[9..<11])):\(String(c[11..<13]))"
    }

    /// 牆上時間 → yyyyMMdd-HHmmss（和 Store.timestamp 同一個格式）
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

/// v0.28.0：依錄音位置把中斷標記排進一串有開始時間的塊（卡片、段落）。逐字稿、md、PDF 共用這個順序。
enum GapMarks {
    enum Slot: Equatable {
        /// 第幾個塊（starts 的索引）
        case block(Int)
        case gap(RecordGap)
    }

    /// starts 要先依時間排好。每個中斷放在第一個「開始時間 ≥ 中斷位置」的塊前面（斷在一張卡中間＝排在那張卡後面）；
    /// 比全部塊都晚的接在最後。中斷照位置排。
    static func order(starts: [Double], gaps: [RecordGap]) -> [Slot] {
        let sorted = gaps.sorted { $0.at < $1.at }
        var out: [Slot] = []
        var next = 0
        for (index, start) in starts.enumerated() {
            while next < sorted.count, sorted[next].at <= start {
                out.append(.gap(sorted[next]))
                next += 1
            }
            out.append(.block(index))
        }
        while next < sorted.count {
            out.append(.gap(sorted[next]))
            next += 1
        }
        return out
    }

    /// 有開始時間的塊插好中斷那一行，依序回傳（空的塊照樣留著，呼叫的人自己濾）
    static func insert(_ blocks: [(start: Double, text: String)], gaps: [RecordGap]) -> [String] {
        order(starts: blocks.map { $0.start }, gaps: gaps).map { slot -> String in
            switch slot {
            case .block(let index): return blocks[index].text
            case .gap(let gap): return gap.line
            }
        }
    }

    /// 稿頭一行：「錄音中斷：錄音 12:34 處少了 2:05（10:01–10:03）、…；這些時間沒錄到」；沒有中斷＝nil
    static func headLine(_ gaps: [RecordGap]) -> String? {
        guard !gaps.isEmpty else { return nil }
        let spots = gaps.sorted { $0.at < $1.at }.map { $0.spot }
        return "錄音中斷：" + spots.joined(separator: "、") + "；這些時間沒錄到"
    }
}
