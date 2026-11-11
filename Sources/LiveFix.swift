import Foundation

// v0.22 錄音中即時改字（只改畫面，不改稿）。
// 設計原則：即時稿是給人邊聽邊抄筆記用的；聽不懂、看起來和課程無關的字照原樣顯示，不去猜。
// 這一層只用固定的對照表，跟課程無關、聽不懂的字不會被碰到。run.text、定稿、原始轉錄都不經過這裡。
// 課程對照表不寫在程式裡：執行時從設定檔（Documents/設定/轉文字設定.json 的 liveFix）讀，見 Schedule.swift 的 AppSettings。
// 對照表的來源建議：同一堂課的即時稿和人工校過的逐字稿比對，挑重複出現、而且在這門課幾乎不會是正常用法的錯。
// 只用 Foundation，shape_check 也編。

/// 一條改字規則。v0.23.2 起新欄位都有預設值，舊的 LiveFixRule(wrong:right:) 寫法照舊能用（規格 B2）。
/// keepLeft／keepRight：wrong 前後幾個字只是定位用（定位擴充，規格 B5），不換、不上綠底；right 前後是同樣的字。
struct LiveFixRule: Equatable, Codable {
    let wrong: String
    let right: String
    var keepLeft = 0
    var keepRight = 0
    /// .table 課程對照表／.haiku 錄音中 Haiku 改、程式驗過的／.promoted 同一組改法這場通過 2 次、升成全場規則
    var source: Source = .table
    /// "詞表"／"投影片p.6"／"前後文"（Haiku 給的依據）
    var evidence: String? = nil
    /// 對到 fixes.json 的哪一筆（FixRecord.id）
    var fixID: Int? = nil

    enum Source: String, Codable { case table, haiku, promoted }

    /// 真正被換掉的原字：wrong 去掉前後定位用的字
    var core: String { Self.trim(wrong, left: keepLeft, right: keepRight) }
    /// 換成的字：right 去掉同樣的前後字
    var coreRight: String { Self.trim(right, left: keepLeft, right: keepRight) }

    private static func trim(_ text: String, left: Int, right: Int) -> String {
        let chars = Array(text)
        let l = min(max(left, 0), chars.count)
        let r = min(max(right, 0), chars.count - l)
        return String(chars[l..<(chars.count - r)])
    }
}

extension LiveFixRule {
    /// 少欄位也讀得開（只有 wrong、right 的舊資料照讀）。寫在 extension 裡，結構本身的逐欄 init 才留著。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wrong = try c.decode(String.self, forKey: .wrong)
        right = try c.decode(String.self, forKey: .right)
        keepLeft = try c.decodeIfPresent(Int.self, forKey: .keepLeft) ?? 0
        keepRight = try c.decodeIfPresent(Int.self, forKey: .keepRight) ?? 0
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .table
        evidence = try c.decodeIfPresent(String.self, forKey: .evidence)
        fixID = try c.decodeIfPresent(Int.self, forKey: .fixID)
    }
}

/// 畫面上的一段：original 是 nil＝原字照抄；不是 nil＝換過的字，original 是原字（定位擴充的規則只有中間那段）。
/// rule：換過的那段是哪一條規則換的（小卡要寫來源）；原字照抄的是 nil。
struct LiveFixPiece: Equatable {
    let text: String
    let original: String?
    var rule: LiveFixRule? = nil
}

enum LiveFix {
    /// 每門課都套：字形錯（繁體一對多沒修到的）。TextCleanup 已經修的這裡不重複。
    static let common: [LiveFixRule] = [
        ("特征", "特徵"), ("上麵", "上面"), ("下麵", "下面"), ("外麵", "外面"), ("前麵", "前面"), ("後麵", "後面"),
        ("隻有", "只有"), ("隻能", "只能"), ("隻是", "只是"), ("隻要", "只要"),
        ("往迴", "往回"), ("迴去", "回去"), ("迴來", "回來"),
    ].map { LiveFixRule(wrong: $0.0, right: $0.1) }

    /// 課程對照表，key 是正式課名（CourseSchedule.formalName）。內容來自設定檔（AppSettings.liveFix），沒有設定檔就是空的。
    /// 層／成→乘、可以→可逆這種要看上下文的不放（實測一份稿裡這類字大多是正常用字）。
    static var byCourse: [String: [LiveFixRule]] { AppSettings.rulesByCourse }

    /// 這門課要套的表：課程表在前、通用在後、錄音中學到的（learned）最後；off 是這場被使用者按掉的原字（比對 core）。
    static func rules(course: String?, off: Set<String> = [], learned: [LiveFixRule] = []) -> [LiveFixRule] {
        let own = course.flatMap { byCourse[$0] } ?? []
        return (own + common + learned).filter { !off.contains($0.core) }
    }

    /// 首字索引：[原字第一個字: 規則]，每格裡長的在前；一樣長的照原本順序（規格 A 還要補的事：規則漲到幾百條不卡）。
    static func index(_ rules: [LiveFixRule]) -> [Character: [LiveFixRule]] {
        let ordered = rules.enumerated()
            .filter { !$0.element.wrong.isEmpty && !$0.element.core.isEmpty }
            .map { (order: $0.offset, length: $0.element.wrong.count, rule: $0.element) }
            .sorted { $0.length != $1.length ? $0.length > $1.length : $0.order < $1.order }
        var out: [Character: [LiveFixRule]] = [:]
        for item in ordered {
            out[item.rule.wrong.first!, default: []].append(item.rule)
        }
        return out
    }

    /// 從左往右掃，同一個位置先比長的原字；換過的字不再被別條規則碰到。
    /// 命中時輸出 前綴（原字照抄）＋改字（original＝core）＋後綴（原字照抄）；前後綴併進旁邊的原字段。
    static func pieces(_ text: String, rules: [LiveFixRule]) -> [LiveFixPiece] {
        guard !rules.isEmpty, !text.isEmpty else { return text.isEmpty ? [] : [LiveFixPiece(text: text, original: nil)] }
        let byFirst = index(rules)
        var out: [LiveFixPiece] = []
        var plain = ""
        var i = text.startIndex
        while i < text.endIndex {
            if let rule = byFirst[text[i]]?.first(where: { text[i...].hasPrefix($0.wrong) }) {
                let wrong = Array(rule.wrong)
                let left = min(max(rule.keepLeft, 0), wrong.count)
                let right = min(max(rule.keepRight, 0), wrong.count - left)
                plain += String(wrong[0..<left])
                if !plain.isEmpty {
                    out.append(LiveFixPiece(text: plain, original: nil))
                }
                out.append(LiveFixPiece(text: rule.coreRight, original: rule.core, rule: rule))
                plain = String(wrong[(wrong.count - right)...])
                i = text.index(i, offsetBy: wrong.count)
            } else {
                plain.append(text[i])
                i = text.index(after: i)
            }
        }
        if !plain.isEmpty { out.append(LiveFixPiece(text: plain, original: nil)) }
        return out
    }

    /// 複製用：改字和原字標在一起 → 改字［原字］。
    static func copyText(_ text: String, rules: [LiveFixRule]) -> String {
        pieces(text, rules: rules).map { piece in
            piece.original.map { "\(piece.text)［\($0)］" } ?? piece.text
        }.joined()
    }

    /// 這段裡改了幾處。
    static func count(_ text: String, rules: [LiveFixRule]) -> Int {
        pieces(text, rules: rules).filter { $0.original != nil }.count
    }
}

/// v0.22 背景看門狗通知（App 在背景時看門狗會被系統暫停，所以改用排好的通知）。
/// App 在背景被系統暫停時什麼程式都跑不了，所以反過來做：錄音正常時每 15 秒把「一分鐘後提醒」往後延；
/// App 被暫停、延不了，提醒就會響。這裡只放算數，畫面和通知在 Model。
enum WatchAlarm {
    static let identifier = "rec-watch-alarm"
    /// 多久沒延就響。
    static let fireAfter: Double = 60
    /// 每隔幾秒延一次。
    static let rearmEvery: Double = 15

    /// 這一秒要做什麼：延後提醒、立刻提醒（背景中已經停了）、或不動。
    enum Action: Equatable { case rearm, alertNow, none }

    static func action(wall: Double, lastRearm: Double, stalled: Bool, inBackground: Bool, alerted: Bool) -> Action {
        if stalled {
            return inBackground && !alerted ? .alertNow : .none
        }
        return wall - lastRearm >= rearmEvery ? .rearm : .none
    }

    static let title = "錄音可能停了"
    static func body(course: String?) -> String {
        "「\(course ?? "這場")」超過一分鐘沒收到聲音。打開轉文字看一下；停了就按停止再續錄。"
    }
}
