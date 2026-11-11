import Foundation

// v0.23.2 錄音中 Haiku 改字：純邏輯層（規格 A①②、B2–B6）。只用 Foundation，shape_check 也編。
// 單位切分、批次、提示詞與請求內容、回覆解析、驗證決策表、拼音近音、詞池、定位擴充、問題限頻、費用、紀錄格式。
// 網路（URLSession、重試）、畫面、接進錄音流程不在這裡（HaikuClient.swift、LiveReviewer.swift、Model.swift）。
// 判定名稱、規則順序以 tools/haiku_prompt/驗證案例.json 為準；另有一份桌面 Python 模擬器（不在這個倉庫）用同一份案例，兩邊要得到同樣判定。
// 這個檔不寫任何 log 字串：稿的字只會出現在 FixRecord.unitText 等存檔欄位，金鑰只經過 APIKeyMask。

// MARK: - 金鑰遮蔽

enum APIKeyMask {
    /// 給人看、寫紀錄用：sk-ant-…末4碼（規格 A 表第 8 點）
    static func masked(_ key: String) -> String {
        "sk-ant-…\(key.suffix(4))"
    }
}

// MARK: - 單位與批次（規格 A①、B2）

/// 一個單位＝一次 isFinal 的那一塊（太短的併進前一個還沒送的、太長的在標點切）。文字是 TextCleanup.fix 過的，算完就不再變。
struct LiveUnit: Codable, Equatable {
    let id: Int
    var text: String
    /// 錄音秒數
    let start: Double
    var end: Double
    /// append 前後 run.text.count（頁碼分隔線、「？」定位用；切開的單位照字數比例分）
    let offsetStart: Int
    var offsetEnd: Int
    /// 送到第幾批；nil＝還沒送
    var batch: Int? = nil
}

struct UnitSplitter {
    /// 少於 6 字的塊併進前一個還沒送的單位（或前一個少於 6 字時，新的併進它）
    static let minChars = 6
    /// 超過 120 字在最後一個標點切（找不到就硬切在 120 字）
    static let maxChars = 120
    static let cutMarks: Set<Character> = ["，", "。", "？", "！", "、", "；", "：", ",", ".", "?", "!", ";", ":"]

    var nextID: Int
    /// 這場切出來的全部單位（依編號）。前文從這裡取。
    private(set) var units: [LiveUnit] = []
    /// 下一塊不要併進前一個單位（續錄開新的一段時設）
    private var breakBefore = false

    init(nextID: Int = 1) {
        self.nextID = nextID
    }

    var unsent: [LiveUnit] { units.filter { $0.batch == nil } }

    /// 續錄開新的一段：下一塊不併進上一段的單位。
    mutating func newSegment() {
        breakBefore = true
    }

    /// 收一次 isFinal 的那一塊。回傳這次新增或變長的單位（都還沒送）。
    @discardableResult
    mutating func add(_ pieces: [TimedPiece], offsetBefore: Int, offsetAfter: Int) -> [LiveUnit] {
        let text = TextCleanup.fix(pieces.map(\.text).joined())
        guard !text.isEmpty, let first = pieces.first, let last = pieces.last else { return [] }
        let merge = !breakBefore && units.last.map { $0.batch == nil && ($0.text.count < Self.minChars || text.count < Self.minChars) } ?? false
        breakBefore = false
        if merge {
            var unit = units[units.count - 1]
            unit.text += text
            unit.end = last.end
            unit.offsetEnd = offsetAfter
            units[units.count - 1] = unit
        } else {
            units.append(LiveUnit(id: nextID, text: text, start: first.start, end: last.end, offsetStart: offsetBefore, offsetEnd: offsetAfter))
            nextID += 1
        }
        return splitLong(at: units.count - 1)
    }

    /// 這些單位送進第幾批（之後不再併字）。
    mutating func markSent(_ ids: [Int], batch: Int) {
        let set = Set(ids)
        for i in units.indices where set.contains(units[i].id) {
            units[i].batch = batch
        }
    }

    /// 編號 id 之前的稿，最後 300 字（給 Haiku 當前文）
    func context(before id: Int) -> String {
        BatchPlanner.context(units.filter { $0.id < id })
    }

    private mutating func splitLong(at index: Int) -> [LiveUnit] {
        var touched: [LiveUnit] = []
        var i = index
        while true {
            var unit = units[i]
            let chars = Array(unit.text)
            guard chars.count > Self.maxChars else {
                touched.append(unit)
                return touched
            }
            let p = (0..<Self.maxChars).last {
                Self.cutMarks.contains(chars[$0]) && $0 >= Self.minChars - 1 && chars.count - ($0 + 1) >= Self.minChars
            } ?? Self.maxChars - 1
            let cut = p + 1
            let fraction = Double(cut) / Double(chars.count)
            let mid = unit.start + (unit.end - unit.start) * fraction
            let restEnd = unit.end
            let restOffsetEnd = unit.offsetEnd
            let offsetCut = unit.offsetStart + cut
            unit.text = String(chars[..<cut])
            unit.end = mid
            unit.offsetEnd = offsetCut
            units[i] = unit
            touched.append(unit)
            let rest = LiveUnit(id: nextID, text: String(chars[cut...]), start: mid, end: restEnd,
                                offsetStart: offsetCut, offsetEnd: restOffsetEnd)
            nextID += 1
            units.insert(rest, at: i + 1)
            i += 1
        }
    }
}

enum BatchPlanner {
    /// 每 15 秒（錄音秒數）檢查；新字 ≥150 立刻送；新字 <20 先不送；最多等 45 秒；前文 300 字
    static let every = 15.0, maxChars = 150, minChars = 20, maxWait = 45.0, contextChars = 300

    static func due(unsentChars: Int, now: Double, lastSent: Double, every: Double = BatchPlanner.every) -> Bool {
        if unsentChars <= 0 { return false }
        if unsentChars >= maxChars { return true }
        if now - lastSent >= every && unsentChars >= minChars { return true }
        return now - lastSent >= maxWait
    }

    static func due(unsent: [LiveUnit], now: Double, lastSent: Double) -> Bool {
        due(unsentChars: unsent.reduce(0) { $0 + $1.text.count }, now: now, lastSent: lastSent)
    }

    /// v0.24 即時模式 2、3：每 60 秒一批；新字 ≥600 立刻送；新字 <20 先不送；最多等 90 秒
    static let bigEvery = 60.0, bigMaxChars = 600, bigMaxWait = 90.0

    static func due(unsentChars: Int, now: Double, lastSent: Double, big: Bool) -> Bool {
        guard big else { return due(unsentChars: unsentChars, now: now, lastSent: lastSent) }
        if unsentChars <= 0 { return false }
        if unsentChars >= bigMaxChars { return true }
        if now - lastSent >= bigEvery && unsentChars >= minChars { return true }
        return now - lastSent >= bigMaxWait
    }

    /// 前文：這些單位接起來的最後 300 字，不帶編號
    static func context(_ before: [LiveUnit]) -> String {
        String(before.map(\.text).joined().suffix(contextChars))
    }

    static func userMessage(context: String, units: [LiveUnit]) -> String {
        HaikuPrompt.userMessage(context: context, units: units)
    }
}

/// 一批送 Haiku 的紀錄（fixes.json 裡；不放稿的字，context 例外：補送時要用，只存在這個檔）。
struct ReviewBatch: Codable, Equatable {
    let id: Int
    let unitIDs: [Int]
    let context: String
    let audioStart: Double
    let audioEnd: Double
    var attempts = 0
    var state: State = .pending
    var latency: Double? = nil
    var http: Int? = nil
    var stopReason: String? = nil
    var usage: Usage? = nil
    /// 不含稿的字、不含金鑰的錯誤說明（API 回應最多 200 字）
    var error: String? = nil
    var chatter: Bool? = nil
    var slidePage: Int? = nil
    var pageEvidence: String? = nil
    /// v0.24：附了幾個 Whisper 字（nil＝這場沒跑 Whisper）
    var whisperChars: Int? = nil

    enum State: String, Codable { case pending, sending, done, failed, abandoned }
}

// MARK: - 回覆與用量（規格 B2、B4）

struct HaikuReply: Codable, Equatable {
    struct Edit: Codable, Equatable {
        let s: Int
        let wrong: String
        let right: String
        let type: String
        let evidence: String
    }
    struct Question: Codable, Equatable {
        let s: Int
        let about: String
        let text: String
    }
    let edits: [Edit]
    let questions: [Question]
    let slide_page: Int
    let page_evidence: String
    let chatter: Bool
}

struct Usage: Codable, Equatable {
    var input_tokens = 0
    var output_tokens = 0
    var cache_read_input_tokens: Int? = nil
    var cache_creation_input_tokens: Int? = nil
    var cache_creation: CacheCreation? = nil

    struct CacheCreation: Codable, Equatable {
        var ephemeral_1h_input_tokens: Int? = nil
        var ephemeral_5m_input_tokens: Int? = nil
    }
}

extension Usage {
    /// 欄位缺了也解得開（規格 B9 第 43 項）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input_tokens = try c.decodeIfPresent(Int.self, forKey: .input_tokens) ?? 0
        output_tokens = try c.decodeIfPresent(Int.self, forKey: .output_tokens) ?? 0
        cache_read_input_tokens = try c.decodeIfPresent(Int.self, forKey: .cache_read_input_tokens)
        cache_creation_input_tokens = try c.decodeIfPresent(Int.self, forKey: .cache_creation_input_tokens)
        cache_creation = try c.decodeIfPresent(CacheCreation.self, forKey: .cache_creation)
    }
}

/// 每百萬 token 的美元（規格 B2）：輸入 0.10、1 小時快取寫入 0.20、5 分鐘快取寫入 0.125、快取讀取 0.01、輸出 0.50。
enum Cost {
    static let input = 0.10, write1h = 0.20, write5m = 0.125, read = 0.01, output = 0.50

    static func usd(_ u: Usage) -> Double {
        let w1h: Int
        let w5m: Int
        if let detail = u.cache_creation {
            w1h = detail.ephemeral_1h_input_tokens ?? 0
            w5m = detail.ephemeral_5m_input_tokens ?? 0
        } else {
            // 只送 1 小時快取，沒細分時當 1 小時（和桌面模擬器一樣）
            w1h = u.cache_creation_input_tokens ?? 0
            w5m = 0
        }
        let sum = Double(u.input_tokens) * input + Double(u.output_tokens) * output
            + Double(w1h) * write1h + Double(w5m) * write5m + Double(u.cache_read_input_tokens ?? 0) * read
        return sum / 1_000_000
    }
}

// MARK: - 驗證（規格 B5）

enum FixVerdict: String, Codable {
    case passed = "通過", chatter = "閒聊整批不套", notInBatch = "s不在新稿", empty = "空",
         same = "沒改", notFound = "原字不在該句", userOff = "使用者關掉", known = "已在表", conflict = "和先前改法衝突",
         wrongIsTerm = "原字是投影片詞表上的正確詞", pronoun = "只改代名詞或的得地", notInPool = "改後的字在投影片和詞表都找不到",
         notNear = "不同音也不在投影片詞表", deletion = "刪字不收", tooMany = "一批太多", cantAnchor = "太短無法定位",
         dropsChars = "改後少了太多中文字", sylMore = "英文改字多出原字沒有的音節"
}

/// 驗證規則版本（和桌面模擬器的驗證版一樣）。v1＝規格 B5 原樣；v2＝11/10 模擬後改（預設）：
/// ① 第 11.5 條：wrong 的中文字數 − right 的中文字數 ≥2 →「改後少了太多中文字」（擋整串字換成一個詞）
/// ② 定位擴充的前後字從這批全部單位依序接起來的字取（出現位置仍限 wrong 所在的單位，或 s 接 s+1）
/// v3＝v2＋11/11 英文音節檢查（right 核心有 ≥3 個字母的英文時，right 比 wrong 多 4 個音節以上 →「英文改字多出原字沒有的音節」；
/// 縮寫先換成投影片上首字母拼得出它的全名再數）。門檻由桌面模擬器用全部呼叫紀錄的英文改字算出。
enum ValidatorVersion: String, Codable {
    case v1, v2, v3
}

/// Haiku 給的一條改字和判定（fixes.json 一筆）。unitText 是稿的字，只存在這個檔，不進紀錄和錯誤資料。
struct FixRecord: Codable, Equatable {
    let id: Int
    let batch: Int
    /// 修正後的 s（原字整個在 s+1 時改成 s+1）
    let s: Int
    /// 收到回覆時的錄音秒數
    let at: Double
    let unitText: String
    /// Haiku 給的原樣
    let wrong: String
    let right: String
    let type: String
    let evidence: String
    var verdict: FixVerdict
    /// 通過時產生的規則（一個原字在同句出現兩次、定位擴充後可能兩條）
    var rules: [LiveFixRule] = []
    var page: Int? = nil
    var latency: Double? = nil
    var finalHits: Int? = nil
    var finalWindow: String? = nil
    var windowHas: String? = nil
    var userOff = false
    /// 11/11 同字升級：這筆有算進「同一組錯字→對字採用幾次」（通過，或 Haiku 再提一次判「已在表」、不是對照表的）
    var adopted: Bool? = nil
    /// 11/11 同字升級：這筆讓同一組改法滿 2 次，升成的全場規則（不帶定位前後字，source＝.promoted）
    var promoted: LiveFixRule? = nil
    /// 升級規則在這場即時稿套用了幾處（停止補送後算；筆電分析用）
    var promotedHits: Int? = nil
}

struct QuestionRecord: Codable, Equatable {
    let id: Int
    let batch: Int
    let s: Int
    let at: Double
    let about: String
    let text: String
    var shown: Bool
    /// 沒顯示的原因（QuestionGate.admit 的回傳）
    var reason: String? = nil
    var acked = false
}

/// 詞池＝投影片全部頁的文字＋對照表右邊的詞（正規化後比子字串）。
struct TermPool {
    let items: [String]
    /// 投影片各頁用換行接起來、轉小寫（v3 找縮寫的全名用；和桌面模擬器一樣）
    let slides: String

    init(pages: [String], glossary: [LiveFixRule]) {
        items = (pages + glossary.map(\.right)).map(Self.norm).filter { !$0.isEmpty }
        slides = pages.joined(separator: "\n").lowercased()
    }

    private static let dropped: Set<Character> = [",", "，", "。", "、", "/", "|", "(", ")", "（", "）", "-"]

    /// 正規化：⁻¹ 換 inverse、NFKC（全形轉半形）、轉小寫、去掉空白和 ,，。、/|()（）-
    static func norm(_ s: String) -> String {
        let replaced = s.replacingOccurrences(of: "⁻¹", with: "inverse").replacingOccurrences(of: "−", with: "-")
        let folded = replaced.precomposedStringWithCompatibilityMapping.lowercased()
        return String(folded.filter { !$0.isWhitespace && !dropped.contains($0) })
    }

    func has(_ s: String) -> Bool {
        let n = Self.norm(s)
        return !n.isEmpty && items.contains { $0.contains(n) }
    }
}

/// 拼音近音（規格 B5）。用 Darwin Foundation 的 mandarinToLatin，每個字一個讀音（Python 版用 pypinyin 的全部讀音，多音字可能有差）。
enum Pinyin {
    static let initials = ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "r", "z", "c", "s", "y", "w"]
    /// 0.23.3：加 zh/ch/sh、z/c/s 兩組（真機稿裡口音混的音被擋，例如 sh～zh、shi～ci）
    static let initialGroups: [Set<String>] = [["z", "zh", "j"], ["c", "ch", "q"], ["s", "sh", "x"], ["j", "q"], ["n", "l"], ["f", "h"], ["r", "l"],
                                               ["b", "p"], ["d", "t"], ["g", "k"], ["zh", "ch", "sh"], ["z", "c", "s"]]
    /// 0.23.3：舌尖元音（zhi chi shi ri zi ci si）彼此算近音（試→瓷、詞→枝）
    static let apical: Set<String> = ["zh", "ch", "sh", "r", "z", "c", "s"]

    /// 一個漢字的聲母、韻母（ü 當 u）；不是漢字或轉不出來是 nil
    static func reading(_ ch: Character) -> (initial: String, final: String)? {
        guard FixText.isCJK(ch) else { return nil }
        guard let latin = String(ch).applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
            !latin.isEmpty, latin.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        let syllable = latin.replacingOccurrences(of: "v", with: "u")
        let initial = initials.first { syllable.hasPrefix($0) } ?? ""
        return (initial, String(syllable.dropFirst(initial.count)))
    }

    static func syllables(_ s: String) -> [(initial: String, final: String)]? {
        var out: [(initial: String, final: String)] = []
        for ch in s {
            guard let r = reading(ch) else { return nil }
            out.append(r)
        }
        return out
    }

    static func nearChar(_ a: Character, _ b: Character) -> Bool {
        if a == b { return true }
        guard let ra = reading(a), let rb = reading(b) else { return false }
        if ra.final == "i", rb.final == "i", apical.contains(ra.initial), apical.contains(rb.initial) { return true }
        let okInitial = ra.initial == rb.initial || initialGroups.contains { $0.contains(ra.initial) && $0.contains(rb.initial) }
        let fa = ra.final.hasSuffix("g") ? String(ra.final.dropLast()) : ra.final
        let fb = rb.final.hasSuffix("g") ? String(rb.final.dropLast()) : rb.final
        let okFinal = fa == fb || Set([fa, fb]) == ["i", "in"]
        return okInitial && okFinal
    }

    /// 同字數、每個不同的字都近音
    static func near(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        guard x.count == y.count else { return false }
        return zip(x, y).allSatisfy { $0 == $1 || nearChar($0, $1) }
    }
}

/// 驗證和定位擴充用的字元判斷（和桌面模擬器一樣）。
enum FixText {
    static func isCJK(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
    }

    /// 定位擴充遇到就停：空白、標點、符號、分隔、控制字元
    static func isStop(_ ch: Character) -> Bool {
        if ch.isWhitespace { return true }
        guard let scalar = ch.unicodeScalars.first else { return true }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
             .spaceSeparator, .lineSeparator, .paragraphSeparator, .control, .format, .surrogate, .privateUse, .unassigned:
            return true
        default:
            return false
        }
    }

    static let chineseDigits: [Character: Character] = ["零": "0", "〇": "0", "一": "1", "二": "2", "三": "3", "四": "4",
                                                       "五": "5", "六": "6", "七": "7", "八": "8", "九": "9"]

    /// 依序取出數字（一二三…也算），連續重複的同一個數字算一個（語音常把 1 1 併成 11）
    static func digits(_ s: String) -> String {
        var out: [Character] = []
        for ch in s {
            let d: Character? = chineseDigits[ch] ?? (("0"..."9").contains(ch) ? ch : nil)
            if let d, out.last != d {
                out.append(d)
            }
        }
        return String(out)
    }

    static func isAllDigits(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { $0.properties.numericType == .decimal || $0.properties.numericType == .digit }
    }

    static func hasLatin(_ s: String) -> Bool {
        s.unicodeScalars.contains { ("A"..."Z").contains($0) || ("a"..."z").contains($0) }
    }

    /// 3 個字母以上的英文詞
    static func latinWords(_ s: String) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in s.unicodeScalars {
            if ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                if current.count >= 3 { words.append(current) }
                current = ""
            }
        }
        if current.count >= 3 { words.append(current) }
        return words
    }

    /// 不重疊的出現次數（和 Python str.count 一樣）
    static func occurrences(of needle: String, in haystack: String) -> Int {
        let n = Array(needle), h = Array(haystack)
        guard !n.isEmpty else { return 0 }
        var count = 0
        var i = 0
        while let at = find(n, in: h, from: i) {
            count += 1
            i = at + n.count
        }
        return count
    }

    static func find(_ needle: [Character], in haystack: [Character], from start: Int) -> Int? {
        guard !needle.isEmpty, start >= 0, haystack.count - needle.count >= start else { return nil }
        for i in start...(haystack.count - needle.count) where haystack[i] == needle[0] {
            if Array(haystack[i..<(i + needle.count)]) == needle { return i }
        }
        return nil
    }
}

/// 一條 edit 的檢查結果：判定、產生的規則、修正後的 s、清過的原字和改字、找到原字的那段稿。
struct FixCheck: Equatable {
    let verdict: FixVerdict
    let rules: [LiveFixRule]
    let s: Int
    let wrong: String
    let right: String
    let unitText: String
}

/// 一場的驗證狀態：已學規則、衝突次數、停用的原字、下一個紀錄編號。續錄時從 ReviewLog 還原。
struct FixState: Codable, Equatable {
    var learned: [LiveFixRule] = []
    /// 原字 → 和先前改法衝突幾次
    var conflicts: [String: Int] = [:]
    /// 衝突第 2 次的原字：之後再來都判衝突
    var disabled: Set<String> = []
    /// 因為衝突被停用的已學規則
    var retired: [LiveFixRule] = []
    /// 下一筆 FixRecord 的編號
    var nextID = 1
    /// 11/11 同字升級：核心錯字→對字（Promotion.key）被採用幾次
    var adopt: [String: Int] = [:]
}

enum FixValidator {
    /// 一批最多通過幾條（第 11 條起「一批太多」）
    static let maxPerBatch = 10
    static let defaultVersion = ValidatorVersion.v3

    /// 依 B5 表序檢查一條（不含第 0 條閒聊、第 1 條一批太多：那兩條看整批，在 validate 做）。
    /// rules＝對照表＋已學規則；disabled＝衝突第 2 次被停用的原字。
    static func check(_ e: HaikuReply.Edit, units: [LiveUnit], pool: TermPool, rules: [LiveFixRule],
                      off: Set<String>, sessionText: String, disabled: Set<String> = [],
                      version: ValidatorVersion = FixValidator.defaultVersion) -> FixCheck {
        let wrong = e.wrong.replacingOccurrences(of: #"\[s\d+\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let right = e.right.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = e.s
        var base = units.first { $0.id == s }?.text ?? ""
        // v2：這批全部單位依序接起來（定位擴充的前後字從這裡取），lo＝base 在裡面的起點
        let full = units.map(\.text).joined()
        func offset(of id: Int) -> Int {
            units.prefix { $0.id != id }.reduce(0) { $0 + $1.text.count }
        }
        var lo = offset(of: s)
        func result(_ verdict: FixVerdict, _ made: [LiveFixRule] = []) -> FixCheck {
            FixCheck(verdict: verdict, rules: made, s: s, wrong: wrong, right: right, unitText: base)
        }
        // 2 s 不在這批新稿（前文的改字也落在這裡）
        guard units.contains(where: { $0.id == s }) else { return result(.notInBatch) }
        // 3 空、4 刪字、5 沒改
        if wrong.isEmpty { return result(.empty) }
        if right.isEmpty { return result(.deletion) }
        if wrong == right { return result(.same) }
        // 6 原字不在單位 s：改看 s 接 s+1
        if !base.contains(wrong) {
            guard let next = units.first(where: { $0.id == s + 1 }) else { return result(.notFound) }
            let joined = Array(base + next.text)
            guard let at = FixText.find(Array(wrong), in: joined, from: 0) else { return result(.notFound) }
            if at >= base.count {
                s += 1
                base = next.text
                lo = offset(of: s)
            } else {
                base += next.text
            }
        }
        // 7 使用者關掉
        if off.contains(wrong) { return result(.userOff) }
        // 8 已在表（記成一致，不另外加規則）
        if rules.contains(where: { ($0.core == wrong && $0.coreRight == right) || ($0.wrong == wrong && $0.right == right) }) {
            return result(.known)
        }
        // 9 和先前改法衝突
        if disabled.contains(wrong) || rules.contains(where: { $0.core == wrong && $0.coreRight != right }) {
            return result(.conflict)
        }
        // 10 原字是投影片詞表上的正確詞
        if wrong.count >= 2, !FixText.isAllDigits(TermPool.norm(wrong)), pool.has(wrong) {
            return result(.wrongIsTerm)
        }
        // 11 只改代名詞或的得地
        let w = Array(wrong), r = Array(right)
        if w.count == r.count {
            let diffs = zip(w, r).filter { $0 != $1 }
            let pronouns: Set<Character> = ["他", "她", "它", "祂"], particles: Set<Character> = ["的", "得", "地"]
            if !diffs.isEmpty, diffs.allSatisfy({ (pronouns.contains($0) && pronouns.contains($1)) || (particles.contains($0) && particles.contains($1)) }) {
                return result(.pronoun)
            }
        }
        // 11.5（v2 起）改後少了太多中文字
        if version != .v1, w.filter(FixText.isCJK).count - r.filter(FixText.isCJK).count >= 2 {
            return result(.dropsChars)
        }
        // 11.6（v3）英文改字多出原字沒有的音節
        if version == .v3, Syllables.check(wrong: wrong, right: right, slides: pool.slides).verdict != nil {
            return result(.sylMore)
        }
        if right.contains(where: { !FixText.isCJK($0) }) || r.count != w.count {
            // 12 英文、數字、符號，或字數不同
            let digits = FixText.digits(wrong)
            var ok = false
            if !FixText.hasLatin(right), !digits.isEmpty, digits == FixText.digits(right) {
                ok = true   // 數字重排（3622 → 3 6 2 | 22）
            } else if pool.has(right) {
                ok = true
            } else {
                let words = FixText.latinWords(right)
                ok = !words.isEmpty && r.count <= 40 && words.allSatisfy(pool.has)
            }
            if !ok { return result(.notInPool) }
        } else if !(pool.has(right) || Pinyin.near(wrong, right)) {
            // 13 同字數的純中文
            return result(.notNear)
        }
        // 14 產生規則
        let made = version != .v1
            ? makeRules(wrong: wrong, right: right, base: full, sessionText: sessionText, lo: lo, hi: lo + base.count)
            : makeRules(wrong: wrong, right: right, base: base, sessionText: sessionText)
        return made.isEmpty ? result(.cantAnchor) : result(.passed, made)
    }

    /// 定位擴充（B5）：wrong ≤2 字、或全場稿裡出現 ≥5 次，就在 base 裡每次出現的位置左右各帶最多 2 個字（遇到標點、空白就停），
    /// 至少帶到 1 個字；其他直接 wrong→right 全場套。只找 base[lo..<hi] 裡的出現位置，前後字可以取到外面（v2 傳整批的字）。
    static func makeRules(wrong: String, right: String, base: String, sessionText: String, lo: Int = 0, hi: Int? = nil) -> [LiveFixRule] {
        let expand = wrong.count <= 2 || FixText.occurrences(of: wrong, in: sessionText) >= 5
        guard expand else { return [LiveFixRule(wrong: wrong, right: right, source: .haiku)] }
        let b = Array(base), w = Array(wrong)
        var out: [LiveFixRule] = []
        var seen: Set<[String]> = []
        let end = hi ?? b.count
        var found = FixText.find(w, in: b, from: lo)
        while let at = found, at + w.count <= end {
            var left: [Character] = []
            var k = at
            while left.count < 2, k - 1 >= 0, !FixText.isStop(b[k - 1]) {
                left.insert(b[k - 1], at: 0)
                k -= 1
            }
            var tail: [Character] = []
            k = at + w.count
            while tail.count < 2, k < b.count, !FixText.isStop(b[k]) {
                tail.append(b[k])
                k += 1
            }
            if !left.isEmpty || !tail.isEmpty {
                let l = String(left), t = String(tail)
                let key = [l + wrong + t, l + right + t]
                if !seen.contains(key) {
                    seen.insert(key)
                    out.append(LiveFixRule(wrong: key[0], right: key[1], keepLeft: left.count, keepRight: tail.count, source: .haiku))
                }
            }
            found = FixText.find(w, in: b, from: at + w.count)
        }
        return out
    }

    /// 一批的 edits → 每條一筆 FixRecord；通過的規則加進 state.learned（同一批後面的 edit 就看得到）。
    /// table＝這門課的對照表（LiveFix.rules(course:)，不受 off 影響）；units＝這批新稿的單位；at＝收到回覆時的錄音秒數。
    /// promotion：nil＝不升級（共用案例的「驗證」段）；App 傳 .app（核心至少 2 字、改後不縮字）。
    static func validate(edits: [HaikuReply.Edit], chatter: Bool, units: [LiveUnit], pool: TermPool, table: [LiveFixRule],
                         off: Set<String>, sessionText: String, state: inout FixState, batch: Int, at: Double,
                         page: Int? = nil, latency: Double? = nil, version: ValidatorVersion = FixValidator.defaultVersion,
                         promotion: Promotion? = nil) -> [FixRecord] {
        var records: [FixRecord] = []
        var passed = 0
        for e in edits {
            let id = state.nextID
            state.nextID += 1
            var verdict: FixVerdict
            var made: [LiveFixRule] = []
            var s = e.s
            var unitText = units.first { $0.id == e.s }?.text ?? ""
            var cleaned: (wrong: String, right: String)? = nil
            // 0.23.3：閒聊裡也常夾著課程內容，所以閒聊批照樣驗證、照樣改；chatter 只記在批次上
            do {
                let c = check(e, units: units, pool: pool, rules: table + state.learned, off: off,
                              sessionText: sessionText, disabled: state.disabled, version: version)
                verdict = c.verdict
                made = c.rules
                s = c.s
                unitText = c.unitText
                cleaned = (c.wrong, c.right)
                if verdict == .conflict {
                    let n = (state.conflicts[c.wrong] ?? 0) + 1
                    state.conflicts[c.wrong] = n
                    if n >= 2 {
                        state.retired += state.learned.filter { $0.core == c.wrong }
                        state.learned.removeAll { $0.core == c.wrong }
                        state.disabled.insert(c.wrong)
                    }
                }
                if verdict == .passed && passed >= maxPerBatch {
                    verdict = .tooMany
                    made = []
                }
            }
            if verdict == .passed {
                passed += 1
                made = made.map {
                    var rule = $0
                    rule.fixID = id
                    rule.evidence = e.evidence
                    return rule
                }
                state.learned += made
            }
            var record = FixRecord(id: id, batch: batch, s: s, at: at, unitText: unitText, wrong: e.wrong, right: e.right,
                                   type: e.type, evidence: e.evidence, verdict: verdict, rules: made, page: page, latency: latency)
            if let promotion, verdict == .passed || verdict == .known, let cleaned {
                let got = promotion.adopt(wrong: cleaned.wrong, right: cleaned.right, table: table, off: off, state: &state, fixID: id)
                record.adopted = got.counted ? true : nil
                record.promoted = got.rule
            }
            records.append(record)
        }
        return records
    }

    /// 和 check 一樣清 Haiku 給的原字、改字（去掉 [s編號]、前後空白）
    static func cleaned(wrong: String, right: String) -> (wrong: String, right: String) {
        (wrong.replacingOccurrences(of: #"\[s\d+\]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines),
         right.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// 11/11 同字升級（修法④）：同一組錯字→對字（去掉定位用的前後字後）同一場被採用滿 2 次，升成全場規則（不帶前後字，
/// 已出現的和之後出現的一起改）。App 用 .app：核心原字至少 2 個字、改後中文字數不比原字少（擋 是→式、理解→零 這種）。
/// 和桌面模擬器（升級 2 次、升級不縮字）同一個算法。
struct Promotion: Equatable {
    /// 核心原字至少幾個字才升級
    let minChars: Int
    /// 改後中文字數比原字少的不升級
    let noShrink: Bool
    /// 採用滿幾次升級
    static let after = 2
    static let app = Promotion(minChars: 2, noShrink: true)

    static func key(_ wrong: String, _ right: String) -> String { wrong + "\u{1F}" + right }

    /// 去掉 wrong／right 前後相同、為了定位多帶的字（只去中文、空白、標點；英文字母和數字不拆）
    static func corePair(_ wrong: String, _ right: String) -> (wrong: String, right: String) {
        let w = Array(wrong), r = Array(right)
        func keep(_ c: Character) -> Bool { FixText.isCJK(c) || FixText.isStop(c) }
        var i = 0
        while i < min(w.count, r.count), w[i] == r[i], keep(w[i]) { i += 1 }
        var j = 0
        while j < min(w.count, r.count) - i, w[w.count - 1 - j] == r[r.count - 1 - j], keep(w[w.count - 1 - j]) { j += 1 }
        return (String(w[i..<(w.count - j)]), String(r[i..<(r.count - j)]))
    }

    /// 一筆通過／已在表的改字：算一次採用；滿 2 次而且符合條件就加一條全場規則進 state.learned。
    /// counted＝有算進次數（對照表的改法、核心空的不算）；rule＝這次新加的升級規則。
    func adopt(wrong: String, right: String, table: [LiveFixRule], off: Set<String>, state: inout FixState,
               fixID: Int) -> (counted: Bool, rule: LiveFixRule?) {
        if table.contains(where: { $0.wrong == wrong && $0.right == right }) { return (false, nil) }
        let (cw, cr) = Self.corePair(wrong, right)
        if cw.isEmpty || cr.isEmpty || cw == cr { return (false, nil) }
        let k = Self.key(cw, cr)
        let n = (state.adopt[k] ?? 0) + 1
        state.adopt[k] = n
        if n < Self.after || cw.count < minChars || state.disabled.contains(cw) || off.contains(cw) { return (true, nil) }
        if noShrink, cr.filter(FixText.isCJK).count < cw.filter(FixText.isCJK).count { return (true, nil) }
        if state.learned.contains(where: { $0.wrong == cw && $0.right == cr }) { return (true, nil) }
        let rule = LiveFixRule(wrong: cw, right: cr, source: .promoted, evidence: "升級", fixID: fixID)
        state.learned.append(rule)
        return (true, rule)
    }
}

/// 11/11 英文音節檢查（修法③，驗證 v3）。和桌面模擬器同一個算法。
enum Syllables {
    /// right 比 wrong 多幾個音節以上就擋
    static let extra = 4

    private static func isASCIILetter(_ u: Unicode.Scalar) -> Bool { ("A"..."Z").contains(u) || ("a"..."z").contains(u) }

    /// 依序取出連續的英文字母（[A-Za-z]+）
    static func latinRuns(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for u in s.unicodeScalars {
            if isASCIILetter(u) {
                cur.unicodeScalars.append(u)
            } else if !cur.isEmpty {
                out.append(cur)
                cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func isAllUpper(_ w: String) -> Bool { !w.isEmpty && w.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) } }

    /// 全大寫 2–6 字母的縮寫：在投影片（slides 已轉小寫）找一串首字母拼得出它的字；找不到回 nil
    static func acronymExpansion(_ word: String, slides: String) -> String? {
        guard (2...6).contains(word.count), isAllUpper(word) else { return nil }
        let pattern = "\\b" + word.lowercased().map { "\($0)[a-z]*" }.joined(separator: "[\\s\\-]+") + "\\b"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: slides, range: NSRange(slides.startIndex..., in: slides)),
              let r = Range(m.range, in: slides) else { return nil }
        return String(slides[r])
    }

    /// 英文字的音節數（估）：母音群數；字尾不發音的 e（不含 -le、-ee）減 1；至少 1
    static func word(_ w: String) -> Int {
        let lower = w.lowercased()
        var n = 0
        var inVowel = false
        for c in lower {
            let v = "aeiouy".contains(c)
            if v && !inVowel { n += 1 }
            inVowel = v
        }
        if n > 1, lower.hasSuffix("e"), !lower.hasSuffix("le"), !lower.hasSuffix("ee") { n -= 1 }
        return max(1, n)
    }

    /// 中文字 1 字 1 音節；英文字照 word；縮寫有全名就數全名，沒有就 1 個字母 1 音節（W 算 3）。數字、符號不算。
    static func count(_ s: String, slides: String) -> Int {
        var n = s.filter(FixText.isCJK).count
        for w in latinRuns(s) {
            if let exp = acronymExpansion(w, slides: slides) {
                n += latinRuns(exp).reduce(0) { $0 + word($1) }
            } else if isAllUpper(w), w.count <= 6 {
                n += w.reduce(0) { $0 + ($1 == "W" ? 3 : 1) }
            } else {
                n += word(w)
            }
        }
        return n
    }

    /// 只檢查 right 核心有 ≥3 個字母英文的改字。回傳判定（nil＝不擋）和兩邊的音節數（不檢查時 nil）。
    static func check(wrong: String, right: String, slides: String) -> (verdict: FixVerdict?, wrong: Int?, right: Int?) {
        let (cw, cr) = Promotion.corePair(wrong, right)
        guard !FixText.latinWords(cr).isEmpty else { return (nil, nil, nil) }
        let sw = count(cw, slides: slides), sr = count(cr, slides: slides)
        return (sr - sw >= extra ? .sylMore : nil, sw, sr)
    }
}

// MARK: - 問題限頻（規格 B6）

struct QuestionGate {
    static let minGap = 60.0, maxShown = 15
    var lastShownAt = -Double.infinity
    /// 問過（顯示過）的 about，正規化後
    var seen: Set<String> = []
    var shown = 0

    /// nil＝放行（並記成問過）；否則是沒顯示的原因。unit＝這批裡編號 q.s 的單位（不在這批給 nil）。
    /// editedWrongs＝這批通過的改字原字（會正規化後比對，互相包含就算）。
    mutating func admit(_ q: HaikuReply.Question, unit: LiveUnit?, at: Double, editedWrongs: Set<String>,
                        chatter: Bool = false) -> String? {
        if chatter { return "閒聊批" }
        guard let unit else { return "s不在新稿" }
        if q.about.isEmpty || !unit.text.contains(q.about) { return "about不在該句" }
        if !(1...80).contains(q.text.count) { return "字數不合" }
        let about = TermPool.norm(q.about)
        if seen.contains(about) { return "已問過" }
        let edited = editedWrongs.map(TermPool.norm)
        if edited.contains(where: { !about.isEmpty && !$0.isEmpty && (about.contains($0) || $0.contains(about)) }) {
            return "是這批改過的字"
        }
        if at - lastShownAt < Self.minGap { return "限頻沒顯示" }
        if shown >= Self.maxShown { return "已達上限" }
        seen.insert(about)
        lastShownAt = at
        shown += 1
        return nil
    }
}

// MARK: - 一場的紀錄（fixes.json）

struct ReviewLog: Codable, Equatable {
    var version = 1
    var model = HaikuPrompt.model
    var effort = HaikuPrompt.effort
    var course: String
    /// 這場用的投影片檔名（SlideDeck.source）
    var slides: String?
    var batches: [ReviewBatch] = []
    var fixes: [FixRecord] = []
    var questions: [QuestionRecord] = []
    var pages: [PageMark] = []
    /// 這場被使用者按掉的原字（續錄要還原，v0.22 的 liveFixOff 不存檔）
    var off: [String] = []
    var stalls: [Stall] = []
    var maxUnitID = 0
    var costUSD = 0.0
    /// 衝突第 2 次被停用的原字（規格 B2 沒有；續錄還原 FixState 要用）
    var disabled: [String] = []

    init(course: String, slides: String? = nil) {
        self.course = course
        self.slides = slides
    }

    /// 續錄用：通過的規則＋升級的規則（去掉被停用、被按掉的；順序和當時加進去的一樣）
    var learnedRules: [LiveFixRule] {
        let blocked = Set(disabled).union(off)
        return fixes.flatMap { ($0.verdict == .passed ? $0.rules : []) + ($0.promoted.map { [$0] } ?? []) }
            .filter { !blocked.contains($0.core) }
    }

    /// 續錄用：還原驗證狀態（同字升級的採用次數從 adopted 的紀錄重算）
    var fixState: FixState {
        var adopt: [String: Int] = [:]
        for f in fixes where f.adopted == true {
            let c = FixValidator.cleaned(wrong: f.wrong, right: f.right)
            let (cw, cr) = Promotion.corePair(c.wrong, c.right)
            adopt[Promotion.key(cw, cr), default: 0] += 1
        }
        return FixState(learned: learnedRules, conflicts: [:], disabled: Set(disabled), retired: [],
                        nextID: (fixes.map(\.id).max() ?? 0) + 1, adopt: adopt)
    }

    /// 這場升級成全場規則的條數
    var promotedCount: Int { fixes.filter { $0.promoted != nil }.count }

    /// 錯誤資料、稿頭用的一行：不放稿的字、不放金鑰
    var summaryLine: String {
        let done = batches.filter { $0.state == .done }.count
        let passed = fixes.filter { $0.verdict == .passed }.count
        let blocked = fixes.count - passed
        var line = "Haiku：\(batches.count) 批（完成 \(done)）、改字通過 \(passed)、擋下 \(blocked)"
            + (promotedCount > 0 ? "、升級全場 \(promotedCount) 條" : "") + "、約 " + String(format: "%.3f", costUSD) + " 美元"
        if let last = batches.last(where: { $0.error != nil })?.error {
            line += "；最後錯誤：" + String(last.prefix(80))
        }
        return line
    }
}

extension ReviewLog {
    /// 少欄位也讀得開（之後加欄位，舊檔照讀）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? HaikuPrompt.model
        effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? HaikuPrompt.effort
        course = try c.decodeIfPresent(String.self, forKey: .course) ?? ""
        slides = try c.decodeIfPresent(String.self, forKey: .slides)
        batches = try c.decodeIfPresent([ReviewBatch].self, forKey: .batches) ?? []
        fixes = try c.decodeIfPresent([FixRecord].self, forKey: .fixes) ?? []
        questions = try c.decodeIfPresent([QuestionRecord].self, forKey: .questions) ?? []
        pages = try c.decodeIfPresent([PageMark].self, forKey: .pages) ?? []
        off = try c.decodeIfPresent([String].self, forKey: .off) ?? []
        stalls = try c.decodeIfPresent([Stall].self, forKey: .stalls) ?? []
        maxUnitID = try c.decodeIfPresent(Int.self, forKey: .maxUnitID) ?? 0
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        disabled = try c.decodeIfPresent([String].self, forKey: .disabled) ?? []
    }
}

// MARK: - 提示詞與請求內容（規格 B3、B4）

/// 任意 JSON 值（schema 先解成這個再編，鍵的順序才固定）。
enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

/// 送 /v1/messages 的內容。Codable＋sortedKeys 編：同一輸入編兩次位元組相同（快取靠這個）。
struct HaikuRequest: Encodable {
    struct CacheControl: Encodable { let type: String; let ttl: String }
    struct SystemBlock: Encodable { let type: String; let text: String; let cache_control: CacheControl? }
    struct Message: Encodable { let role: String; let content: String }
    struct Format: Encodable { let type: String; let schema: JSONValue }
    struct OutputConfig: Encodable { let effort: String; let format: Format }
    let model: String
    let max_tokens: Int
    let system: [SystemBlock]
    let messages: [Message]
    let output_config: OutputConfig
}

/// API 回應裡要用的部分
struct HaikuResponse: Decodable {
    struct Block: Decodable { let type: String; let text: String? }
    let content: [Block]?
    let stop_reason: String?
    let usage: Usage?
}

/// 回覆解析的結果。unreadable 的 reason 不含稿的字。
enum ReplyResult: Equatable {
    case reply(HaikuReply, stopReason: String?, usage: Usage?)
    /// stop_reason＝refusal：整批不套，記一筆
    case refusal(usage: Usage?)
    /// stop_reason＝max_tokens：不套，記一筆，不重送
    case truncated(usage: Usage?)
    /// 解析失敗：重送一次（B4）
    case unreadable(reason: String, usage: Usage?)

    var usage: Usage? {
        switch self {
        case .reply(_, _, let u), .refusal(let u), .truncated(let u), .unreadable(_, let u): return u
        }
    }
}

enum HaikuPrompt {
    static let model = "claude-haiku-5-5"
    static let effort = "low"
    static let maxTokens = 6000
    /// 投影片估算超過這個數，後面的頁不送（規格 A 表第 9 點 (d)）
    static let slideTokenLimit = 60_000

    /// 提示詞（tools/haiku_prompt/system.txt，由 同步提示詞.py 產生，shape_check 逐字比對）
    static let system = HaikuPromptText.system
    /// 結構化輸出的 schema 原文（tools/haiku_prompt/schema.json）
    static let schemaText = HaikuPromptText.schema

    static func schema() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(schemaText.utf8))
    }

    /// 投影片前幾頁的估算加起來不超過 limit（第一頁本身就超過也照送 1 頁）
    static func slidePagesSent(_ deck: SlideDeck, limit: Int = HaikuPrompt.slideTokenLimit) -> Int {
        var total = 0
        for (i, page) in deck.pages.enumerated() {
            total += SlideDeck.estimateTokens([page])
            if total > limit { return max(i, 1) }
        }
        return deck.pages.count
    }

    /// 課程區塊（system 第二個 block，帶 1 小時快取）。一場之內不能變：glossary 用 LiveFix.rules(course:) 的對照表（不含已學、不受 off 影響）。
    static func courseBlock(course: String, glossary: [LiveFixRule], deck: SlideDeck?) -> String {
        let terms = glossary.map { "\($0.wrong)→\($0.right)" }.joined(separator: "、")
        var block = "課名：\(course)\n詞表（左＝稿裡常見的錯，右＝正確）：\(terms)\n"
        if let deck, !deck.pages.isEmpty {
            let pages = deck.pages.prefix(slidePagesSent(deck)).enumerated().map { i, page in
                page.isEmpty ? "[p.\(i + 1)]" : "[p.\(i + 1)]\n\(page)"
            }
            block += "這堂投影片全文（[p.N] 是頁碼）：\n" + pages.joined(separator: "\n")
        } else {
            block += "這堂沒有投影片。"
        }
        return block
    }

    static func userMessage(context: String, units: [LiveUnit]) -> String {
        let ctx = context.isEmpty ? "（無）" : context
        return "前文（只參考，不准改）：\n\(ctx)\n\n新稿：\n" + units.map { "[s\($0.id)] \($0.text)" }.joined(separator: "\n")
    }

    static func request(courseBlock: String, userMessage: String, effort: String = HaikuPrompt.effort,
                        maxTokens: Int = HaikuPrompt.maxTokens) throws -> HaikuRequest {
        let format = try schema()
        return HaikuRequest(
            model: model,
            max_tokens: maxTokens,
            system: [
                .init(type: "text", text: system, cache_control: nil),
                .init(type: "text", text: courseBlock, cache_control: .init(type: "ephemeral", ttl: "1h")),
            ],
            messages: [.init(role: "user", content: userMessage)],
            output_config: .init(effort: effort, format: .init(type: "json_schema", schema: format))
        )
    }

    /// 請求內容（不送 thinking、temperature，也不預填回覆）。標頭在 HaikuClient：x-api-key、anthropic-version 2026-10-21、content-type。
    static func requestBody(courseBlock: String, userMessage: String, effort: String = HaikuPrompt.effort,
                            maxTokens: Int = HaikuPrompt.maxTokens) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(request(courseBlock: courseBlock, userMessage: userMessage, effort: effort, maxTokens: maxTokens))
    }

    /// 先看 stop_reason（refusal、max_tokens 不套），再從 content 找第一個 type=="text" 的區塊解成 HaikuReply。
    static func parseResponse(_ data: Data) -> ReplyResult {
        guard let response = try? JSONDecoder().decode(HaikuResponse.self, from: data) else {
            return .unreadable(reason: "回應不是預期的格式", usage: nil)
        }
        switch response.stop_reason {
        case "refusal": return .refusal(usage: response.usage)
        case "max_tokens": return .truncated(usage: response.usage)
        default: break
        }
        guard let text = response.content?.first(where: { $0.type == "text" })?.text else {
            return .unreadable(reason: "回應裡沒有文字區塊", usage: response.usage)
        }
        guard let reply = parseReply(text) else {
            return .unreadable(reason: "文字區塊不是規定的 JSON", usage: response.usage)
        }
        return .reply(reply, stopReason: response.stop_reason, usage: response.usage)
    }

    static func parseReply(_ text: String) -> HaikuReply? {
        try? JSONDecoder().decode(HaikuReply.self, from: Data(text.utf8))
    }
}
