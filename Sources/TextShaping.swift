import Foundation

/// 一小段字和它在聲音裡的時間。之後分人要靠這個對回去；不知道時間時是 -1。
struct TimedPiece: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
}

/// 語音引擎的繁體有一對多轉錯（里面→裏麵、只→隻、表→錶）。
/// 只修這一類，例子來自真機稿。專有名詞聽錯不在這裡修，原文另存。
enum TextCleanup {
    private static let words: [(String, String)] = [
        ("裏", "裡"),
        // 面
        ("裡麵", "裡面"), ("外麵", "外面"), ("前麵", "前面"), ("後麵", "後面"), ("上麵", "上面"), ("下麵", "下面"),
        ("方麵", "方面"), ("表麵", "表面"), ("顏麵", "顏面"), ("全麵", "全面"), ("對麵", "對面"),
        ("側麵", "側面"), ("正麵", "正面"), ("反麵", "反面"), ("平麵", "平面"), ("畫麵", "畫面"), ("層麵", "層面"),
        ("場麵", "場面"), ("當麵", "當面"), ("見麵", "見面"), ("麵對", "面對"), ("麵前", "面前"), ("一麵", "一面"),
        ("兩麵", "兩面"), ("這麵", "這面"), ("那麵", "那面"), ("麵積", "面積"), ("麵臨", "面臨"), ("麵向", "面向"),
        // 其他實際看到的
        ("控製", "控制"), ("克製", "克制"), ("限製", "限制"), ("機製", "機制"), ("體製", "體制"),
        ("復雜", "複雜"), ("重復", "重複"), ("復製", "複製"), ("反復", "反覆"),
        ("想象", "想像"), ("沖動", "衝動"), ("呎度", "尺度"), ("巖", "岩"), ("鉆", "鑽"),
        ("係統", "系統"), ("母係", "母系"), ("父係", "父系"), ("係列", "系列"), ("體係", "體系"),
        ("發佈", "發布"),
        ("迴來", "回來"), ("迴到", "回到"), ("迴頭", "回頭"), ("迴想", "回想"), ("迴推", "回推"), ("迴答", "回答"),
    ]
    /// 隻前面是數量才留（兩隻手、這隻鳥），其他都是「只」。
    private static let onlyPattern = try? NSRegularExpression(pattern: "(?<![一二兩三四五六七八九十百千幾這那每多好數0-9])隻")
    /// 錶只有手錶這類才留，其他都是「表」。逐詞列不完（例如「他錶這個」）。
    private static let tablePattern = try? NSRegularExpression(pattern: "(?<![手腕鐘懷電水碼鬧名])錶(?![帶店])")
    /// 引擎會在標點前多一個空白：「一樣 ，然後」。
    private static let spacePattern = try? NSRegularExpression(pattern: "\\s+([，。？！、；：])")

    private static func replace(_ pattern: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let pattern else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    static func fix(_ source: String) -> String {
        var text = replace(tablePattern, in: source, with: "表")
        for (wrong, right) in words {
            text = text.replacingOccurrences(of: wrong, with: right)
        }
        text = replace(onlyPattern, in: text, with: "只")
        return replace(spacePattern, in: text, with: "$1")
    }
}

/// 把引擎給的片段排成段落。時間標記不幫助理解、卡在句首反而干擾；要好的分段。
/// 時間不放進稿裡，只存在「時間.json」。
/// 同一段內句子接著寫；停頓夠久或段落夠長才空一行（【我推論】門檻，還沒用真稿校過）。
struct LineBuilder {
    static let paragraphPauseSeconds = 1.5
    static let minimumParagraphCharacters = 20
    static let longParagraphCharacters = 110
    static let hardLimitCharacters = 180
    private static let enders: Set<Character> = ["。", "？", "！", "?", "!"]
    private static let punctuation: Set<Character> = ["。", "？", "！", "?", "!", "，", "、", "；", "：", ",", " "]

    private var done = ""
    private var current = ""
    private var lastEnd: Double?

    var text: String { done + shown(current) }

    private func shown(_ paragraph: String) -> String {
        TextCleanup.fix(paragraph).trimmingCharacters(in: .whitespaces)
    }

    mutating func add(_ pieces: [TimedPiece]) {
        for piece in pieces {
            let startsWithPunctuation = piece.text.first.map { Self.punctuation.contains($0) } ?? true
            if !startsWithPunctuation {
                let gap = piece.start >= 0 ? lastEnd.map { piece.start - $0 } ?? 0 : 0
                if (gap >= Self.paragraphPauseSeconds && current.count >= Self.minimumParagraphCharacters)
                    || current.count >= Self.hardLimitCharacters {
                    closeParagraph()
                }
            }
            for character in piece.text {
                if character.isNewline { continue }
                if current.isEmpty && character == " " { continue }
                current.append(character)
                if Self.enders.contains(character), current.count >= Self.longParagraphCharacters {
                    closeParagraph()
                }
            }
            if piece.end >= 0 {
                lastEnd = piece.end
            }
        }
    }

    private mutating func closeParagraph() {
        let paragraph = shown(current)
        if !paragraph.isEmpty {
            done += paragraph + "\n\n"
        }
        current = ""
    }
}

/// 分人的結果：這段時間是誰。
struct SpeakerTurn: Codable, Equatable {
    var speaker: String
    var start: Double
    var end: Double
}

/// 把字貼上講者。好的分段和標示講者，稿才讀得懂。
/// 一個字一個字貼會跳來跳去，所以以「一小句」為單位（標點或停 0.4 秒，【我推論】門檻），看這一小句和誰重疊最久。
enum SpeakerLabeler {
    static let clausePauseSeconds = 0.4
    private static let clauseEnders: Set<Character> = ["。", "？", "！", "?", "!", "，", ",", "、", "；"]
    private static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)

    private static func clauses(of pieces: [TimedPiece]) -> [[TimedPiece]] {
        var result: [[TimedPiece]] = []
        var current: [TimedPiece] = []
        for piece in pieces {
            if let last = current.last, last.end >= 0, piece.start >= 0, piece.start - last.end >= clausePauseSeconds {
                result.append(current)
                current = []
            }
            current.append(piece)
            let trimmed = piece.text.trimmingCharacters(in: .whitespaces)
            if let end = trimmed.last, clauseEnders.contains(end) {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func speaker(of clause: [TimedPiece], turns: [SpeakerTurn]) -> String? {
        var seconds: [String: Double] = [:]
        for piece in clause where piece.start >= 0 && piece.end >= 0 {
            for turn in turns {
                let shared = min(piece.end, turn.end) - max(piece.start, turn.start)
                if shared > 0 { seconds[turn.speaker, default: 0] += shared }
            }
        }
        // 同秒數時固定取名字小的，結果才不會每次不同
        return seconds.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// 這一小句完全沒重疊（模型當成沒人講話）時，用時間最近的那段。
    private static func nearest(to clause: [TimedPiece], turns: [SpeakerTurn]) -> String? {
        guard let at = clause.first(where: { $0.start >= 0 })?.start else { return nil }
        func distance(_ turn: SpeakerTurn) -> Double {
            at < turn.start ? turn.start - at : (at > turn.end ? at - turn.end : 0)
        }
        return turns.min { distance($0) < distance($1) }?.speaker
    }

    static func label(pieces: [TimedPiece], turns: [SpeakerTurn]) -> (text: String, names: [String]) {
        guard !turns.isEmpty else {
            var plain = LineBuilder()
            plain.add(pieces)
            return (plain.text, [])
        }
        var names: [String: String] = [:]
        var order: [String] = []
        var output: [String] = []
        var builder = LineBuilder()
        var currentName: String?

        func flush() {
            guard let currentName else { return }
            for paragraph in builder.text.components(separatedBy: "\n\n") where !paragraph.isEmpty {
                output.append("\(currentName)：\(paragraph)")
            }
        }

        for clause in clauses(of: pieces) {
            let raw = speaker(of: clause, turns: turns) ?? nearest(to: clause, turns: turns)
            var name = currentName
            if let raw {
                if names[raw] == nil {
                    let letter = order.count < letters.count ? letters[order.count] : "講者\(order.count + 1)"
                    names[raw] = letter
                    order.append(letter)
                }
                name = names[raw]
            }
            // 開頭就沒時間的字：跟下一個有時間的人，這裡先給 A
            if name == nil {
                names["?"] = letters[0]
                order.append(letters[0])
                name = letters[0]
            }
            if name != currentName {
                flush()
                builder = LineBuilder()
                currentName = name
            }
            builder.add(clause)
        }
        flush()
        return (output.joined(separator: "\n\n"), order)
    }
}

/// 校正：模型只回「哪個詞可能該是哪個」。手機校正只標註：程式在字後面加〔…？〕，原字一個都不動。
struct TextEdit: Codable, Equatable {
    var wrong: String
    var right: String
}

enum TextFixer {
    /// 只留講者標籤以外真的有的。單一個字不收（他→她 會標滿整份）；同音錯字字數一定相同，字數不同就是刪字或改寫，不收。
    static func clean(_ raw: [TextEdit], in text: String) -> [TextEdit] {
        let body = TextMarker.body(of: text)
        var seen = Set<String>()
        var out: [TextEdit] = []
        for edit in raw {
            let wrong = edit.wrong.trimmingCharacters(in: .whitespacesAndNewlines)
            let right = edit.right.trimmingCharacters(in: .whitespacesAndNewlines)
            guard wrong.count >= 2, wrong.count == right.count, wrong != right, !seen.contains(wrong), body.contains(wrong) else { continue }
            seen.insert(wrong)
            out.append(TextEdit(wrong: wrong, right: right))
        }
        return out
    }

    /// 長的先換，換過的不再被短的碰到。
    static func apply(_ edits: [TextEdit], to text: String) -> String {
        let ordered = edits.sorted { $0.wrong.count > $1.wrong.count }
        var result = ""
        var rest = Substring(text)
        outer: while !rest.isEmpty {
            for edit in ordered where rest.hasPrefix(edit.wrong) {
                result += edit.right
                rest = rest.dropFirst(edit.wrong.count)
                continue outer
            }
            result.append(rest.removeFirst())
        }
        return result
    }

    /// 模型回的字裡找 JSON：前後可能多說話或包程式碼框。
    static func parse(_ answer: String) -> [TextEdit] {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end else { return [] }
        struct Reply: Decodable { let edits: [TextEdit] }
        let data = Data(answer[start...end].utf8)
        return (try? JSONDecoder().decode(Reply.self, from: data))?.edits ?? []
    }
}

/// 校正切塊。記住每塊是原稿的哪幾行，標註才不會跑到模型沒看過的地方。
struct TextBlock: Equatable {
    var text: String
    var lines: [Int]
}

enum TextBlocks {
    static func split(_ text: String, limit: Int) -> [TextBlock] {
        var result: [TextBlock] = []
        var current = ""
        var lines: [Int] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() where !line.isEmpty {
            if !current.isEmpty, current.count + line.count > limit {
                result.append(TextBlock(text: current, lines: lines))
                current = ""
                lines = []
            }
            current += line + "\n"
            lines.append(index)
        }
        if !current.isEmpty {
            result.append(TextBlock(text: current, lines: lines))
        }
        return result
    }
}

/// 這一塊的模型建議。
struct BlockHints: Equatable {
    var lines: [Int]
    var edits: [TextEdit]
}

/// 只標註，不改稿：行首的講者標籤（A：、講者27：）碰不到；原字留著，後面加〔…〕，拿掉括號就是原稿。
enum TextMarker {
    private static let labelPattern = try? NSRegularExpression(pattern: "^(?:[A-Z]|講者[0-9]+)：")

    private static func labelEnd(_ line: String) -> String.Index {
        guard let pattern = labelPattern,
              let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range, in: line) else { return line.startIndex }
        return range.upperBound
    }

    /// 拿掉每行行首的講者標籤。
    static func body(of text: String) -> String {
        text.components(separatedBy: "\n")
            .map { String($0[labelEnd($0)...]) }
            .joined(separator: "\n")
    }

    /// only 是 nil 就標全部行。
    static func mark(_ edits: [TextEdit], in text: String, onLines only: Set<Int>? = nil) -> String {
        guard !edits.isEmpty else { return text }
        return text.components(separatedBy: "\n").enumerated().map { index, line -> String in
            if let only, !only.contains(index) { return line }
            let end = labelEnd(line)
            return String(line[..<end]) + TextFixer.apply(edits, to: String(line[end...]))
        }.joined(separator: "\n")
    }

    /// 離線校正：每塊的建議只標在那一塊，都加問號，因為只有模型的猜測。
    static func mark(hints: [BlockHints], in text: String) -> String {
        hints.reduce(text) { current, hint in
            let edits = hint.edits.map { TextEdit(wrong: $0.wrong, right: "\($0.wrong)〔\($0.right)？〕") }
            return mark(edits, in: current, onLines: Set(hint.lines))
        }
    }

    /// 把標註拿掉，測試用來確認原字沒動。
    static func strip(_ text: String) -> String {
        text.replacingOccurrences(of: "〔[^〕]*〕", with: "", options: .regularExpression)
    }
}

/// 定稿的保底。按停止後，完整的即時稿已存好；定稿跑到一半的片段不准蓋掉它，畫面和「最近一次」都留即時稿，直到定稿完整跑完。
struct FinalGuard<Run> {
    private(set) var draft: Run?

    var mayUpdateLast: Bool { draft == nil }

    mutating func begin(draft: Run?) {
        self.draft = draft
    }

    mutating func finish() {
        draft = nil
    }

    /// 定稿被打斷時要留的那份；nil 表示沒有保底，留手上有的。
    mutating func interrupt() -> Run? {
        defer { draft = nil }
        return draft
    }
}

/// FluidAudio 回報的各段秒數。
struct SpeakerTiming: Equatable {
    /// 模型載入與編譯（第一次含下載）、讀聲音。
    var load: Double
    var segment: Double
    var embed: Double
    /// 分群與收尾。
    var cluster: Double
}

/// 分人那一行。總秒數容易被誤以為很慢：把載入、計算、App 在背景分開講。
enum SpeakerReport {
    static func line(count: Int, forced: Bool, wall: Double, timing: SpeakerTiming?, background: Double) -> String {
        var text = String(format: "分人：%d 人，共 %.0f 秒", count, wall)
        if let timing {
            text += String(format: "（載入 %.0f、切段 %.0f、聲紋 %.0f、分群 %.0f）", timing.load, timing.segment, timing.embed, timing.cluster)
        }
        if background >= 1 {
            text += String(format: "；其中 %.0f 秒 App 在背景，切到別的 App 會暫停", background)
        }
        if forced {
            text += "。指定人數就一定分成這麼多群，其實只有一人講也會被拆"
        }
        return text + "。只看聲音，可能分錯"
    }
}

/// 智慧校正：蘋果 AI 挑詞，查維基百科，只標註不改字。
struct TermPick: Codable, Equatable {
    var written: [String]
    var guess: String
}

struct WikiHit: Equatable {
    var title: String
    var snippet: String
}

/// status：found（維基有這個詞）、judge（維基有提到，但不是專頁）、none（沒查到，不代表寫錯）、held（像私人姓名，程式擋下沒送）。
/// 「查到」只代表這個詞存在，不代表稿裡講的就是它：模型猜錯一個真實存在的人名，一樣會查到。
struct TermNote: Codable, Equatable {
    var written: [String]
    var right: String
    var status: String
    var url: String?
}

enum TermCheck {
    static let maxPicks = 30

    static func parse(_ answer: String) -> [TermPick] {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end else { return [] }
        struct Reply: Decodable { let groups: [TermPick] }
        return (try? JSONDecoder().decode(Reply.self, from: Data(answer[start...end].utf8)))?.groups ?? []
    }

    /// 只留稿裡真的有的寫法；同一個猜測併一組；只有一種寫法且和猜的一樣就是沒聽錯，不用查。
    static func clean(_ raw: [TermPick], in text: String) -> [TermPick] {
        let body = TextMarker.body(of: text)
        var order: [String] = []
        var merged: [String: [String]] = [:]
        for pick in raw {
            let guess = pick.guess.trimmingCharacters(in: .whitespacesAndNewlines)
            guard guess.count >= 2 else { continue }
            let written = pick.written.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 2 && body.contains($0) }
            guard !written.isEmpty else { continue }
            if merged[guess] == nil {
                order.append(guess)
                merged[guess] = []
            }
            for word in written where !(merged[guess] ?? []).contains(word) {
                merged[guess, default: []].append(word)
            }
        }
        return order.compactMap { guess -> TermPick? in
            guard let written = merged[guess], written != [guess] else { return nil }
            return TermPick(written: written.filter { $0 != guess }, guess: guess)
        }
        .prefix(maxPicks)
        .map { $0 }
    }

    private static func simplified(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    }

    static func pageURL(_ title: String) -> String {
        let path = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        return "https://zh.wikipedia.org/wiki/\(path)"
    }

    /// 標題就是這個詞（繁簡都算）→ found；內文片段提到 → judge；都沒有 → none。維基搜尋會回很多無關的頁，所以不能看有沒有結果。
    static func judge(guess: String, hits rawHits: [WikiHit]) -> (status: String, url: String?) {
        let simple = simplified(guess)
        // 維基摘要把命中的字包在 <span> 裡，不拿掉就比不到（雲端實測：有專頁的人名被判沒查到）
        let hits = rawHits.map { WikiHit(title: $0.title, snippet: $0.snippet.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)) }
        if let hit = hits.first(where: { $0.title == guess || simplified($0.title) == simple }) {
            return ("found", pageURL(hit.title))
        }
        if let hit = hits.first(where: { $0.snippet.contains(guess) || simplified($0.snippet).contains(simple) }) {
            return ("judge", pageURL(hit.title))
        }
        return ("none", nil)
    }

    /// 字不改，在錯字後面加小括號：牛盾〔牛頓〕；只是有提到的加問號；沒查到不標。
    static func annotate(_ notes: [TermNote], in text: String) -> String {
        var edits: [TextEdit] = []
        for note in notes where note.status != "none" {
            let mark = note.status == "judge" ? "〔\(note.right)？〕" : "〔\(note.right)〕"
            edits += note.written.map { TextEdit(wrong: $0, right: $0 + mark) }
        }
        return TextMarker.mark(edits, in: text)
    }
}

/// 送維基前的程式關卡。原則：第三人的內容不離開。提示詞叫模型不要挑私人姓名，但模型可能不聽，所以送出前程式再濾一次。
/// 只擋得住「看得出來」的，擋不住的：沒有姓氏的兩字名（只叫名字）、四字以上的姓名、單字外文名、非姓名的私事。
/// 寧可多擋：三字中文歷史人物也會被擋，畫面列「沒送查」。
enum PrivacyGate {
    static let maxHanCharacters = 12
    static let maxOtherCharacters = 40
    static let maxLengthChange = 3

    private static let surnames = Set("陳林黃張李王吳劉蔡楊許鄭謝郭洪曾邱廖賴周徐蘇葉莊呂江何蕭羅高潘簡朱鍾彭游詹胡施沈余趙盧梁顏柯孫魏翁戴范宋方鄧杜傅侯曹薛丁卓阮馬董溫唐藍石蔣古紀姚連馮歐程湯田康姜白汪鄒尤巫鐘黎涂龔嚴韓袁金童陸夏柳凃邵尹易錢俞史崔賀毛于段雷倪常武孔葛")
    private static let doubleSurnames = ["歐陽", "司馬", "上官", "諸葛", "東方", "皇甫", "尉遲", "公孫", "慕容", "令狐", "司徒", "司空", "夏侯", "張簡", "范姜"]
    private static let nicknames = Set("小阿老")
    /// 姓氏開頭但是學術用語常見的結尾（高血壓、白血球、方程式），這些不當人名。
    private static let termEndings = Set("症炎素體酸酶學球壓病菌瘤腺癌藥劑器系區省縣市院黨式型性率法論障族")
    private static let afterCues = ["老師", "同學", "學長", "學姐", "學弟", "學妹", "阿姨", "叔叔", "伯伯", "舅舅", "姑姑", "嬸嬸", "先生", "小姐", "太太", "醫師", "醫生", "教授", "助教", "主任", "院長", "爸", "媽", "哥", "姐", "弟", "妹"]
    private static let beforeCues = ["朋友", "同學", "室友", "老師", "學長", "學姐", "學弟", "學妹", "我媽", "我爸", "我哥", "我姐", "我弟", "我妹"]
    private static let latinName = try? NSRegularExpression(pattern: "^[A-Z][a-z]+( [A-Z][a-z]+)+$")

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x2FFFF).contains($0.value) }
    }

    /// 像一個詞，不像一句話：沒有標點，不太長，和稿裡的寫法長度差不多。模型把一整句塞進 guess 也送不出去。
    static func termShaped(_ guess: String, written: [String]) -> Bool {
        let allowed = guess.allSatisfy { isHan($0) || $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "·" }
        guard allowed, guess.count <= maxOtherCharacters else { return false }
        let hanCount = guess.filter { isHan($0) }.count
        guard hanCount <= maxHanCharacters else { return false }
        if hanCount > 0, guess.contains(" ") { return false }
        return written.contains { abs($0.count - guess.count) <= maxLengthChange }
    }

    static func nameShaped(_ word: String) -> Bool {
        if word.allSatisfy({ isHan($0) }) {
            if doubleSurnames.contains(where: { word.hasPrefix($0) }), (3...4).contains(word.count) { return true }
            guard (2...3).contains(word.count), let first = word.first, let last = word.last else { return false }
            if termEndings.contains(last) { return false }
            return surnames.contains(first) || nicknames.contains(first)
        }
        guard let pattern = latinName else { return false }
        return pattern.firstMatch(in: word, range: NSRange(word.startIndex..., in: word)) != nil
    }

    /// 稿裡這個詞緊貼著稱呼（王小明老師、我朋友阿華），就當成身邊的人。
    static func mentionedAsPerson(_ word: String, in text: String) -> Bool {
        afterCues.contains { text.contains(word + $0) } || beforeCues.contains { text.contains($0 + word) }
    }

    static func allows(_ pick: TermPick, transcript: String) -> Bool {
        guard termShaped(pick.guess, written: pick.written), !nameShaped(pick.guess) else { return false }
        return !([pick.guess] + pick.written).contains { mentionedAsPerson($0, in: transcript) }
    }

    static func split(_ picks: [TermPick], transcript: String) -> (allowed: [TermPick], held: [TermPick]) {
        var allowed: [TermPick] = []
        var held: [TermPick] = []
        for pick in picks {
            if allows(pick, transcript: transcript) {
                allowed.append(pick)
            } else {
                held.append(pick)
            }
        }
        return (allowed, held)
    }
}

/// 續錄：同一場停了又接著錄（結果畫面左下角的麥克風＝接著這一場錄）。
/// 新的一段另存一個錄音檔，不去改原本的檔：續錄中途出事，第一段還是完整的。
/// 字接在原稿後面，中間一行分隔；時間加上前面幾段的長度，時間.json 才是整場的時間。
/// 分人每段各自分（不重分整場），所以不同段的 A、B 不一定是同一人。
enum PartJoin {
    static func divider(part: Int, offset: Double) -> String {
        "——續錄第 \(part) 段，從 \(formatStamp(offset)) 起——"
    }

    /// 原稿（去掉結尾空白）＋分隔行。新的字接在它後面。
    static func head(base: String, part: Int, offset: Double) -> String {
        var trimmed = base
        while let last = trimmed.last, last.isNewline || last == " " {
            trimmed.removeLast()
        }
        return trimmed + "\n\n" + divider(part: part, offset: offset) + "\n\n"
    }

    /// 拆成「原稿＋分隔行」和「這次新加的」。對不上（不該發生）就整份當新的，重組時一個字都不會掉。
    static func split(_ text: String, head: String) -> (head: String, body: String) {
        guard !head.isEmpty, text.hasPrefix(head) else { return ("", text) }
        return (head, String(text.dropFirst(head.count)))
    }

    /// 沒有時間的片段（-1）保持 -1。
    static func shift(_ pieces: [TimedPiece], by offset: Double) -> [TimedPiece] {
        guard offset != 0 else { return pieces }
        return pieces.map {
            TimedPiece(
                text: $0.text,
                start: $0.start >= 0 ? $0.start + offset : $0.start,
                end: $0.end >= 0 ? $0.end + offset : $0.end
            )
        }
    }

    /// 續錄那段的講者代號加上段號，存進分人.json 時才不會和第一段的同名代號混在一起。
    static func shift(_ turns: [SpeakerTurn], by offset: Double, part: Int?) -> [SpeakerTurn] {
        let prefix = part.map { "第\($0)段-" } ?? ""
        return turns.map { SpeakerTurn(speaker: prefix + $0.speaker, start: $0.start + offset, end: $0.end + offset) }
    }

    static func merge(_ old: [String]?, _ new: [String]) -> [String] {
        var result = old ?? []
        for name in new where !result.contains(name) {
            result.append(name)
        }
        return result
    }

    /// 畫面上的說明：續錄那段的接在原本的後面，標第幾段。
    static func note(_ old: String?, part: Int?, _ new: String?) -> String? {
        guard let new, !new.isEmpty else { return old }
        guard let part else { return new }
        let line = "第 \(part) 段：\(new)"
        guard let old, !old.isEmpty else { return line }
        return old + "\n" + line
    }
}

// MARK: v0.14 稿上的句子對回錄音時間

/// 稿上的一句。location、length 是畫面文字裡的位置（UTF-16，UITextView 用這個）。
struct Sentence: Equatable {
    var location: Int
    var length: Int
    /// 從稿頭數第幾個非空白字。分段、換行改了也不變，標記存這個。
    var content: Int
    /// 錄音裡從第幾秒開始（整場的時間，續錄的第 2 段接著算，和時間.json 一樣）；對不到是 nil。
    var start: Double?
    /// 續錄的分隔行
    var isDivider = false

    var end: Int { location + length }
}

/// 稿裡的〔…〕標註（校正標的可疑字），右欄列出來，點了跳到那句。
struct SuspectNote: Equatable {
    var sentence: Int
    var label: String
}

/// 點一句從那裡播、點兩下標記：要知道畫面上每一句在錄音的第幾秒。
/// 畫面上的稿＝時間.json 的字（修過錯字）＋講者標籤＋〔…〕標註＋續錄分隔行，順序和時間.json 一樣。
/// 所以拿掉標籤、標註、分隔行、空白後，一個字一個字對回時間.json；對不上（跨片段修字、少字）就往前找幾個字重新對齊。
/// 句子：句號、問號、驚嘆號或換行結束（標註括號裡的？不算）。
struct TranscriptMap {
    private(set) var sentences: [Sentence] = []
    private(set) var suspects: [SuspectNote] = []
    /// 照多長的字建的（UTF-16）；和畫面上的字長度不同就是還沒更新，不畫底色。
    private(set) var utf16Count = 0
    private var byTime: [(start: Double, index: Int)] = []

    static let empty = TranscriptMap()

    private init() {}

    private static let enders: Set<Character> = ["。", "？", "！", "?", "!"]
    private static let closers: Set<Character> = ["」", "』", "）", ")", "”", "\""]
    private static let labelPattern = try? NSRegularExpression(pattern: "^(?:[A-Z]|講者[0-9]+)：")
    static let dividerPrefix = "——續錄第"
    /// 對不上時最多往前找幾個字
    private static let window = 16

    init(text: String, pieces: [TimedPiece]) {
        let built = Self.build(text: text, pieces: pieces)
        let list = built.sentences
        sentences = list
        suspects = built.suspects
        utf16Count = text.utf16.count
        byTime = list.indices
            .compactMap { index -> (start: Double, index: Int)? in
                guard !list[index].isDivider, let start = list[index].start else { return nil }
                return (start, index)
            }
            .sorted { $0.start == $1.start ? $0.index < $1.index : $0.start < $1.start }
    }

    private static func code(_ character: Character) -> Int {
        character.unicodeScalars.reduce(0) { $0 &* 1_000_003 &+ Int($1.value) }
    }

    private static func build(text: String, pieces: [TimedPiece]) -> (sentences: [Sentence], suspects: [SuspectNote]) {
        // 時間.json：沒時間的片段（-1）借前一個有時間的，開頭的借後一個
        var times: [Double?] = pieces.map { $0.start >= 0 ? $0.start : nil }
        var carry: Double?
        for k in times.indices {
            if let t = times[k] { carry = t } else { times[k] = carry }
        }
        carry = nil
        for k in times.indices.reversed() {
            if let t = times[k] { carry = t } else { times[k] = carry }
        }
        var raw: [Int] = []
        var rawTime: [Double?] = []
        for (k, piece) in pieces.enumerated() {
            for character in TextCleanup.fix(piece.text) where !character.isWhitespace {
                raw.append(code(character))
                rawTime.append(times[k])
            }
        }

        // 畫面上的字：切句，記下哪些字要對回時間.json
        var sentences: [Sentence] = []
        var suspects: [SuspectNote] = []
        var display: [Int] = []
        var displaySentence: [Int] = []
        var content = 0
        var lineStart = 0
        for line in text.components(separatedBy: "\n") {
            let lineLength = line.utf16.count
            defer { lineStart += lineLength + 1 }
            if line.allSatisfy({ $0.isWhitespace }) { continue }
            if line.hasPrefix(dividerPrefix) {
                sentences.append(Sentence(location: lineStart, length: lineLength, content: content, start: nil, isDivider: true))
                content += line.filter { !$0.isWhitespace }.count
                continue
            }
            var labelLength = 0
            if let pattern = labelPattern,
               let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: lineLength)) {
                labelLength = match.range.length
            }
            var current: Sentence?
            var pendingEnd = false
            var inBracket = false
            var bracket = ""
            var position = lineStart
            for character in line {
                let width = character.utf16.count
                defer { position += width }
                if character.isWhitespace { continue }
                if pendingEnd, !inBracket, !closers.contains(character) {
                    if let done = current { sentences.append(done) }
                    current = nil
                    pendingEnd = false
                }
                if current == nil {
                    current = Sentence(location: position, length: 0, content: content, start: nil)
                }
                let sentenceStart = current?.location ?? position
                current?.length = position + width - sentenceStart
                content += 1
                let inLabel = position - lineStart < labelLength
                if inLabel {
                    continue
                }
                if inBracket {
                    bracket.append(character)
                    if character == "〕" {
                        inBracket = false
                        suspects.append(SuspectNote(sentence: sentences.count, label: bracket))
                    }
                    continue
                }
                if character == "〔" {
                    inBracket = true
                    bracket = "〔"
                    continue
                }
                display.append(code(character))
                displaySentence.append(sentences.count)
                if enders.contains(character) {
                    pendingEnd = true
                }
            }
            if let done = current { sentences.append(done) }
        }

        // 一個字一個字對；對不上就在前後 window 個字內找下一段連續三個字相同的地方
        let n = display.count
        let m = raw.count
        var mapped = [Int?](repeating: nil, count: n)
        func agrees(_ x: Int, _ y: Int) -> Bool {
            let length = min(3, n - x, m - y)
            guard length >= 1, length >= min(2, n - x) else { return false }
            for t in 0..<length where display[x + t] != raw[y + t] {
                return false
            }
            return true
        }
        var i = 0
        var j = 0
        while i < n, j < m {
            if display[i] == raw[j] {
                mapped[i] = j
                i += 1
                j += 1
                continue
            }
            var found: (a: Int, b: Int)?
            search: for total in 1...(2 * window) {
                for a in 0...min(total, window) {
                    let b = total - a
                    if b > window { continue }
                    if agrees(i + a, j + b) {
                        found = (a, b)
                        break search
                    }
                }
            }
            if let found {
                for k in 0..<found.a {
                    mapped[i + k] = min(j + k, m - 1)
                }
                i += found.a
                j += found.b
            } else {
                mapped[i] = j
                i += 1
                j += 1
            }
        }
        var alignable = Set<Int>()
        for index in 0..<n {
            let s = displaySentence[index]
            guard s >= 0, s < sentences.count else { continue }
            alignable.insert(s)
            if sentences[s].start == nil, let r = mapped[index], let t = rawTime[r] {
                sentences[s].start = t
            }
        }
        // 只有標籤或標註、沒有字可對的句子：用前一句的時間；分隔行用下一句的時間（續錄那段的開頭）
        var previous: Double?
        for k in sentences.indices where !sentences[k].isDivider {
            if sentences[k].start == nil, !alignable.contains(k) {
                sentences[k].start = previous
            }
            if let t = sentences[k].start { previous = t }
        }
        var next: Double?
        for k in sentences.indices.reversed() {
            if sentences[k].isDivider {
                sentences[k].start = next
            } else if let t = sentences[k].start {
                next = t
            }
        }
        return (sentences, suspects)
    }

    /// 畫面上第 offset 個 UTF-16 位置是哪一句（點下去的地方）。落在兩句中間的空白是 nil。
    func sentence(atUTF16 offset: Int) -> Int? {
        var low = 0
        var high = sentences.count - 1
        var found = -1
        while low <= high {
            let middle = (low + high) / 2
            if sentences[middle].location <= offset {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard found >= 0, offset <= sentences[found].end else { return nil }
        return found
    }

    /// 和 UTF-16 位置 low…high 有重疊的句子（Pencil 畫過的範圍）。
    func sentences(from low: Int, to high: Int) -> [Int] {
        var first = 0
        var last = sentences.count
        while first < last {
            let middle = (first + last) / 2
            if sentences[middle].end < low {
                first = middle + 1
            } else {
                last = middle
            }
        }
        var result: [Int] = []
        var index = first
        while index < sentences.count, sentences[index].location <= high {
            result.append(index)
            index += 1
        }
        return result
    }

    /// 標記存的位置（第幾個非空白字）在哪一句。
    func sentence(containingContent index: Int) -> Int? {
        var low = 0
        var high = sentences.count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if sentences[middle].content <= index {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    /// 播到第 t 秒時是哪一句：開始時間不晚於 t 的最後一句。
    func sentence(atTime t: Double) -> Int? {
        var low = 0
        var high = byTime.count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if byTime[middle].start <= t + 0.05 {
                found = byTime[middle].index
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found ?? byTime.first?.index
    }
}

/// 點兩下或 Pencil 標的句子，每場存一個「標記.json」，匯出時一起帶。
/// at 是那句從稿頭數第幾個非空白字（分段改了也對得回來）；text、start 是給人和別的 AI 看的。
struct SentenceMark: Codable, Equatable {
    var at: Int
    var text: String
    var start: Double?
    /// 「點兩下」或「Pencil」
    var by: String
    /// 標的時間 yyyyMMdd-HHmmss
    var made: String
}

/// 稿頭的時長。
func formatStamp(_ seconds: Double) -> String {
    // 不是數字或太大時 Int(...) 會閃退，先擋
    guard seconds.isFinite, seconds < 1e9 else { return "?" }
    let total = max(0, Int(seconds))
    if total >= 3600 {
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
    return String(format: "%02d:%02d", total / 60, total % 60)
}
