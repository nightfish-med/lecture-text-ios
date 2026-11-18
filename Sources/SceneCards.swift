import Foundation

// v0.27.0 純邏輯（只用 Foundation，shape_check 也編；tools/shape_check/scene_tests.swift）：
// 三種場景（上課／討論會／聊天）對應的設定、卡片逐字稿一行一行（點一下改字、Pencil 圈起來重查）、
// 使用者改的字（存進卡片.json、下一批送 Haiku 時當參考）、Pencil 圈到哪幾行、左右欄寬度、
// 「圈起來＝重送」的請求與回覆解析（網路搜尋、來源、只改圈起來的行）、討論會停止後依講者標 A／B。
// 網路與排程在 LiveReviewer.swift，畫面在 LiveCardViews.swift。這個檔不寫 log 字串。

// MARK: - 場景

/// 錄音前選的場景（下一次錄音生效；選檔轉文字的分人人數也照它）
enum RecordScene: String, CaseIterable, Codable {
    /// Whisper 主稿＋每 60 秒一張卡（Haiku），課名照課表、有投影片；不分人
    case lecture
    /// 和上課一樣有卡，沒有課名也送（開始前先提醒告知在場的人）；停止後分人（預設自動人數）
    case discussion
    /// 不送 Haiku、沒有卡；只有逐字稿＋分人（預設 2 人）＋複製
    case chat

    var title: String {
        switch self {
        case .lecture: return "上課"
        case .discussion: return "討論會"
        case .chat: return "聊天"
        }
    }

    /// 選單裡的說明
    var detail: String {
        switch self {
        case .lecture: return "重點卡、照課表、不分人"
        case .discussion: return "重點卡＋停止後分人"
        case .chat: return "不送 Haiku，只轉文字＋分人"
        }
    }

    var symbol: String {
        switch self {
        case .lecture: return "graduationcap"
        case .discussion: return "person.3"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }

    /// 即時模式：1＝Whisper 主稿＋卡片；0＝Apple 即時字（停止後 Apple 定稿）
    var liveMode: Int { self == .chat ? 0 : 1 }
    /// 會不會送 Haiku（聊天永遠不送）
    var usesHaiku: Bool { self != .chat }
    /// 沒有課名也送（中性的課程區塊、沒有投影片）
    var allowsNoCourse: Bool { self == .discussion }
    /// 開始錄音前要先提醒（內容會送 Haiku）
    var confirmsBeforeStart: Bool { self == .discussion }
    /// 錄音中 Pencil 圈起來可以重查
    var allowsRecheck: Bool { self != .chat }
    /// 預設人數：0＝不分人，-1＝自動
    var defaultSpeakers: Int {
        switch self {
        case .lecture: return 0
        case .discussion: return -1
        case .chat: return 2
        }
    }

    /// 這個場景實際的人數：上課一律 0；其他用記住的（沒記過用預設；記成 0 也當預設，免得討論會不分人）
    func speakers(stored: Int?) -> Int {
        guard self != .lecture else { return 0 }
        guard let stored, stored != 0 else { return defaultSpeakers }
        return stored
    }

    /// 開始前的提醒（討論會）
    static let confirmTitle = "討論會的內容會送到 Claude Haiku 整理成重點卡。開始前請先告訴在場的人。"
    /// 討論會沒有課名時送的課程區塊（一場之內不變，快取照樣有效）
    static let neutralCourseBlock = "課名：（討論會，沒有課名）\n詞表（左＝稿裡常見的錯，右＝正確）：\n這堂沒有投影片。"
    /// v0.29.0「非課程（其他場合）」送的課程區塊（一場之內不變；主題不放這裡，每次請求另外附在使用者訊息）。
    /// 字裡保留「沒有課名」：提示詞照這幾個字判斷課名不用管
    static let nonCourseBlock = "課名：（非課程，其他場合，沒有課名）\n詞表（左＝稿裡常見的錯，右＝正確）：\n這場沒有投影片。"

    /// v0.29.0 沒課名時請求裡寫的課名：非課程／討論會
    static func noCourseName(nonCourse: Bool) -> String {
        nonCourse ? "（非課程，其他場合，沒有課名）" : "（討論會，沒有課名）"
    }
}

// MARK: - v0.29.0 非課程的主題（使用者自己打的）

/// 非課程（其他場合）時使用者打的主題（例：讀書會）。存進場的 json、稿頭「主題：…」；每次送卡片、重查、重算都附在使用者訊息
/// （不放進有快取的課程區塊：錄音中改了，下一個請求就用新的）。
enum SessionTopic {
    /// 最多幾個字（太長的截掉）
    static let maxLength = 40

    /// 換行換成空白、去頭尾空白、截到 maxLength；空的＝nil
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let flat: String = text.components(separatedBy: CharacterSet.newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.isEmpty ? nil : String(flat.prefix(maxLength))
    }

    static let head = "使用者說這場的主題："

    /// 卡片使用者訊息後面接的一段（沒有主題＝空字串）；接在改字對照、說明前面
    static func promptBlock(_ topic: String?) -> String {
        guard let topic = clean(topic) else { return "" }
        return "\n\n" + head + topic + "（使用者自己寫的，當這場的背景和改字的證據；不要把這幾個字抄進 expanded）"
    }
}

// MARK: - 使用者改的字、重查改的字

/// 一行的改動。line＝改的時候是第幾行；before＝改之前那行的字；after＝改成的字。
/// by：user＝使用者點一下改的（之後的批次送 Haiku 時當參考）；web＝Pencil 圈起來重查改的。
/// v0.28.0：note＝使用者寫在「跟 AI 說」的話（不進逐字稿，只附在之後送 Haiku 的訊息）。舊的卡片.json 沒有這欄＝nil。
/// 只寫 note、沒改字時 before＝after，套用時跳過（不算改過）。
struct CardEdit: Codable, Equatable {
    var line: Int
    var before: String
    var after: String
    var by: String
    var note: String? = nil

    static let user = "user"
    static let web = "web"

    /// v0.28.0：真的改了字（before≠after）。只寫說明的那筆＝false
    var changesText: Bool { before != after }
    /// v0.28.0：有寫說明（去掉空白後不是空的）
    var hasNote: Bool { !(note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum CardEdits {
    /// v0.28.0：這些改動裡有沒有真的改字（只寫說明的不算）
    static func changesText(_ edits: [CardEdit]?) -> Bool {
        (edits ?? []).contains { $0.changesText }
    }

    /// v0.28.0：要不要照逐字稿重算重點和整理版（有改字或有說明）
    static func needsRefresh(_ edits: [CardEdit]?) -> Bool {
        (edits ?? []).contains { $0.changesText || $0.hasNote }
    }

    /// 兩段字共同的頭尾去掉，剩下中間換掉的那段（old→new）。完全一樣＝兩個都空。
    static func fragment(_ before: String, _ after: String) -> (prefix: String, old: String, new: String, suffix: String) {
        let a = Array(before), b = Array(after)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        return (String(a[0..<p]), String(a[p..<(a.count - s)]), String(b[p..<(b.count - s)]), String(a[(a.count - s)...]))
    }

    /// 依序套用改動。找行的順序：同一行字一樣 → 別行字一樣 → 改的那段（old）在哪一行（同一行優先）→ 找不到就跳過。
    /// 回傳套好的行，和每個改過的行「第一次改之前」的字（畫綠字用）。
    static func apply(lines: [String], edits: [CardEdit]) -> (lines: [String], before: [Int: String]) {
        var out = lines
        var first: [Int: String] = [:]
        for edit in edits {
            // v0.28.0：只寫「跟 AI 說」、沒改字的不動那一行（不算改過、不畫綠字）
            if edit.before == edit.after { continue }
            var target: Int?
            var replaced = edit.after
            if edit.line >= 0, edit.line < out.count, out[edit.line] == edit.before {
                target = edit.line
            } else if let i = out.firstIndex(of: edit.before) {
                target = i
            } else {
                let frag = fragment(edit.before, edit.after)
                if !frag.old.isEmpty {
                    let order = (edit.line >= 0 && edit.line < out.count ? [edit.line] : []) + Array(out.indices)
                    if let i = order.first(where: { out[$0].contains(frag.old) }),
                       let range = out[i].range(of: frag.old) {
                        target = i
                        replaced = out[i].replacingCharacters(in: range, with: frag.new)
                    }
                }
            }
            guard let i = target else { continue }
            if first[i] == nil { first[i] = out[i] }
            out[i] = replaced
        }
        return (out, first)
    }

    /// 送 Haiku 的參考：這場使用者改過的（只取改的那段，最近的 limit 筆、去重複、每段最多 40 字）
    static func promptPairs(_ edits: [CardEdit], limit: Int = 20) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for edit in edits.reversed() where edit.by == CardEdit.user {
            let frag = fragment(edit.before, edit.after)
            var old = frag.old.trimmingCharacters(in: .whitespaces)
            var new = frag.new.trimmingCharacters(in: .whitespaces)
            if old.isEmpty && new.isEmpty { continue }
            if old.isEmpty || new.isEmpty {
                // 純加字或純刪字：帶上前後各兩個字才看得懂
                old = String(frag.prefix.suffix(2)) + frag.old + String(frag.suffix.prefix(2))
                new = String(frag.prefix.suffix(2)) + frag.new + String(frag.suffix.prefix(2))
            }
            let pair = String(old.prefix(40)) + "→" + String(new.prefix(40))
            guard !seen.contains(pair) else { continue }
            seen.insert(pair)
            out.append(pair)
            if out.count >= limit { break }
        }
        return out.reversed()
    }

    /// v0.28.0 送 Haiku 的使用者說明：使用者改的那幾筆裡有寫 note 的（最近的 limit 筆、去重複、換行變空白、每筆最多 100 字），
    /// 後面括號帶那一行的前 20 字，Haiku 才知道是在講哪裡。
    static func promptNotes(_ edits: [CardEdit], limit: Int = 10) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for edit in edits.reversed() where edit.by == CardEdit.user {
            let flat = (edit.note ?? "").replacingOccurrences(of: "\n", with: " ")
            let note = flat.trimmingCharacters(in: .whitespacesAndNewlines)
            if note.isEmpty { continue }
            let short = String(note.prefix(100))
            guard !seen.contains(short) else { continue }
            seen.insert(short)
            let line = edit.after.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(line.isEmpty ? short : short + "（寫在這一行：" + String(line.prefix(20)) + "）")
            if out.count >= limit { break }
        }
        return out.reversed()
    }

    /// v0.28.0 改字對照的說明：只套一模一樣的原字，發音像的不套；改字不代表主題
    static let pairsHead = "這場使用者改過的字（左＝原本聽到的，右＝使用者改成的）。只有這段原稿裡出現和左邊一模一樣的字，才照右邊寫；發音相近但字不同的詞不要套用。這些改字不代表這堂課的主題，主題照課名："
    /// v0.28.0 使用者在「跟 AI 說」寫的話
    static let notesHead = "使用者的說明（照著做，但不要把說明的字抄進 expanded）："

    /// 卡片使用者訊息後面接的一段：改字對照、使用者的說明，各自有才放（都沒有＝空字串）
    static func promptBlock(_ edits: [CardEdit]) -> String {
        let pairs = promptPairs(edits)
        let notes = promptNotes(edits)
        var out = ""
        if !pairs.isEmpty {
            out += "\n\n" + pairsHead + "\n" + pairs.joined(separator: "\n")
        }
        if !notes.isEmpty {
            out += "\n\n" + notesHead + "\n" + notes.joined(separator: "\n")
        }
        return out
    }
}

// MARK: - 卡片逐字稿：一行一行

/// 卡片逐字稿的一行（畫面一行一個 Text）
struct CardLine: Equatable {
    /// 畫面上的字（含使用者改的、重查改的）
    var text: String
    /// Whisper 原本聽到的（編輯畫面灰字參考）
    var original: String
    /// 這行的比對片段（沒有比對＝整行一片 same）
    var pieces: [CardDiff.Piece]
    /// 第一次改之前的字；nil＝沒改過
    var editedFrom: String?
    /// 這行在原稿（去掉標點空白）裡第幾個字到第幾個字（分人對時間用）
    var rawFrom: Int
    var rawTo: Int
}

enum CardLines {
    /// 比對片段照換行切成一行一組（same 片段裡的 \n 是行界）
    static func split(_ pieces: [CardDiff.Piece]) -> [[CardDiff.Piece]] {
        var lines: [[CardDiff.Piece]] = [[]]
        for piece in pieces {
            guard piece.kind == .same, piece.text.contains("\n") else {
                lines[lines.count - 1].append(piece)
                continue
            }
            let parts = piece.text.components(separatedBy: "\n")
            for (k, part) in parts.enumerated() {
                if k > 0 { lines.append([]) }
                if !part.isEmpty {
                    lines[lines.count - 1].append(CardDiff.Piece(kind: .same, text: part, old: "", group: piece.group))
                }
            }
        }
        return lines
    }

    /// 這一行原本聽到的字：same 照抄、換字用原字、刪掉的放回來
    static func original(_ pieces: [CardDiff.Piece]) -> String {
        pieces.map { $0.kind == .same ? $0.text : $0.old }.joined()
    }

    /// 這一行吃掉原稿幾個字（標點空白不算）
    static func rawCount(_ pieces: [CardDiff.Piece]) -> Int {
        pieces.reduce(0) { sum, piece in
            sum + CardDiff.core(piece.kind == .same ? piece.text : piece.old).count
        }
    }

    /// 這張卡畫面上的行。整理到而且有比對＝擴寫一句一行（綠字照比對）；否則原稿一句一行。最後套上改動。
    static func build(_ card: LiveCard, diff: [CardDiff.Piece]?) -> [CardLine] {
        let groups: [[CardDiff.Piece]]
        if card.state == .done, !card.expanded.isEmpty, let diff, !diff.isEmpty {
            groups = split(diff)
        } else {
            let base = card.state == .done && !card.expanded.isEmpty ? card.expanded : card.raw
            let text = CardDiff.lines(base)
            groups = text.isEmpty ? [] : text.components(separatedBy: "\n").map { line in
                line.isEmpty ? [] : [CardDiff.Piece(kind: .same, text: line, old: "", group: -1)]
            }
        }
        var cursor = 0
        var lines: [CardLine] = groups.map { pieces in
            let count = rawCount(pieces)
            let line = CardLine(text: pieces.map(\.text).joined(), original: original(pieces), pieces: pieces,
                                editedFrom: nil, rawFrom: cursor, rawTo: cursor + count)
            cursor += count
            return line
        }
        if let edits = card.edits, !edits.isEmpty {
            let applied = CardEdits.apply(lines: lines.map(\.text), edits: edits)
            for i in lines.indices {
                lines[i].text = applied.lines[i]
                lines[i].editedFrom = applied.before[i]
            }
        }
        return lines
    }

    /// Pencil 圈到哪幾行（只比上下）：每行和筆跡外框重疊超過半行高就算；筆跡比一行還扁（畫底線）重疊就算；都沒有就取離外框中間最近的那行。
    static func hit(_ boxes: [LineBox], top: Double, bottom: Double) -> [Int] {
        let lo = min(top, bottom), hi = max(top, bottom)
        var out: [Int] = []
        for box in boxes {
            let height = max(box.bottom - box.top, 1)
            let shared = min(hi, box.bottom) - max(lo, box.top)
            if shared >= height / 2 || (hi - lo < height && shared > 0) {
                out.append(box.index)
            }
        }
        if out.isEmpty {
            let middle = (lo + hi) / 2
            if let near = boxes.min(by: { abs(($0.top + $0.bottom) / 2 - middle) < abs(($1.top + $1.bottom) / 2 - middle) }) {
                out = [near.index]
            }
        }
        return Array(Set(out)).sorted()
    }

    /// v0.28.0 跨卡圈選：所有卡的行（整個卡片清單的座標）用同一套規則判斷圈到哪幾行，依上下位置排（同高再照卡、行）
    static func hitAcross(_ boxes: [CardLineBox], top: Double, bottom: Double) -> [CardLineRef] {
        let indexed = boxes.enumerated().map { LineBox(index: $0.offset, top: $0.element.top, bottom: $0.element.bottom) }
        let picked = hit(indexed, top: top, bottom: bottom).map { boxes[$0] }
        return picked.sorted { a, b in
            (a.top, a.ref.card, a.ref.line) < (b.top, b.ref.card, b.ref.line)
        }.map(\.ref)
    }
}

// MARK: - v0.29.0 錄音中複製（卡片模式）：到目前為止的全文

/// 錄音中按複製（卡片模式）的內文（稿頭由 Model 照「複製全文」的格式加）。以前只複製整理好的卡的重點＋整理版。
/// 每張卡（依時間）一段：第一行「[mm:ss–mm:ss　p.N]」，下面是逐字稿一句一行：
/// - 整理到的卡：Haiku 改好的字，改過的字後面接［原字］（和非卡片模式的錄音中複製一樣，全形方括號）；
///   被刪掉的原字寫成「［刪：原字］」放在刪掉的位置（單寫［原字］會被看成前一個字的原字）；
///   使用者點一下改過、或重查改過的那一行照改好的字（不標原字：那一行已經和比對的片段對不上）
/// - 還沒整理到、沒整理到的卡：Whisper 原字，時間那行標明
/// 最後接還沒進卡的字（Whisper 原字，前面一行標明）。錄音中斷照錄音位置插一行〔錄音中斷…〕（GapMarks）。都沒有字＝空字串。
enum CardCopy {
    static let waitingNote = "還沒整理，Whisper 原字"
    static let failedNote = "沒整理到，Whisper 原字"
    static let tailHead = "[還沒進卡的字，Whisper 原字]"

    /// 一行：same 照抄、changed 接［原字］（同一組只在最後一片有原字）、deleted 寫［刪：原字］；改過的行照改好的字
    static func marked(_ line: CardLine) -> String {
        if line.editedFrom != nil { return line.text }
        var out = ""
        for piece in line.pieces {
            switch piece.kind {
            case .same:
                out += piece.text
            case .changed:
                out += piece.text
                if !piece.old.isEmpty { out += "［" + piece.old + "］" }
            case .deleted:
                if !piece.old.isEmpty { out += "［刪：" + piece.old + "］" }
            }
        }
        return out
    }

    /// 一張卡一段（時間那行＋一句一行）；沒有字＝空字串
    static func block(_ card: LiveCard, diff: [CardDiff.Piece]?) -> String {
        let rows: [String] = CardLines.build(card, diff: diff).map { (line: CardLine) -> String in marked(line) }
            .filter { (row: String) -> Bool in !row.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !rows.isEmpty else { return "" }
        var head = CardText.range(card)
        if let page = card.page { head += "　p.\(page)" }
        switch card.state {
        case .done: break
        case .waiting: head += "　" + waitingNote
        case .failed: head += "　" + failedNote
        }
        return "[" + head + "]\n" + rows.joined(separator: "\n")
    }

    /// cards＝這一段的卡（續錄前幾段的字由呼叫的人接在前面）；diffs＝審稿器算好的比對；tail＝還沒進卡的 Whisper 字；gaps＝這一段的錄音中斷
    static func live(_ cards: [LiveCard], diffs: [Int: [CardDiff.Piece]], tail: String, gaps: [RecordGap] = []) -> String {
        let sorted: [LiveCard] = cards.sorted { (a: LiveCard, b: LiveCard) -> Bool in a.start < b.start }
        let blocks: [(start: Double, text: String)] = sorted.map { (card: LiveCard) -> (start: Double, text: String) in
            (start: card.start, text: block(card, diff: diffs[card.id]))
        }
        var parts: [String] = GapMarks.insert(blocks, gaps: gaps).filter { (part: String) -> Bool in !part.isEmpty }
        let rest = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty {
            parts.append(tailHead + "\n" + rest)
        }
        return parts.joined(separator: "\n\n")
    }
}

/// 一行在卡片欄裡的上下位置（點）
struct LineBox: Equatable {
    var index: Int
    var top: Double
    var bottom: Double
}

/// v0.28.0 跨卡圈選：一行在整個卡片清單裡的上下位置（點）
struct CardLineBox: Equatable {
    var ref: CardLineRef
    var top: Double
    var bottom: Double
}

// MARK: - 左右欄寬度（寬畫面，拉中間的把手）

enum CardSplit {
    static let gap = 20.0
    static let defaultRight = 300.0
    static let minRight = 220.0
    static let minLeft = 300.0

    /// 右欄寬度。ratio＝右欄佔整寬的比例；0 以下＝沒拉過，用 300 點。夾在兩邊最小寬度之間。
    static func right(total: Double, ratio: Double) -> Double {
        clamp(right: ratio > 0 ? total * ratio : defaultRight, total: total)
    }

    static func clamp(right: Double, total: Double) -> Double {
        let most = total - gap - minLeft
        guard most > minRight else { return minRight }
        return min(max(right, minRight), most)
    }

    static func ratio(right: Double, total: Double) -> Double {
        total > 0 ? clamp(right: right, total: total) / total : 0
    }
}

// MARK: - 圈起來＝重送（Haiku＋網路搜尋）

struct RecheckSource: Codable, Equatable {
    var title: String
    var url: String
}

struct RecheckFix: Codable, Equatable {
    var old: String
    var new: String
}

/// v0.28.0 重查沒把握、但有具體猜測的改法（畫面上一顆「套用」）。applied：nil＝還沒按；true＝套上了；false＝按了但那幾行已經找不到原字
struct RecheckMaybe: Codable, Equatable {
    var old: String
    var new: String
    var applied: Bool? = nil
}

/// v0.28.0 跨卡重查用：哪張卡的第幾行
struct CardLineRef: Hashable {
    var card: Int
    var line: Int
}

/// v0.28.0 跨卡重查：圈到的第一張卡以外的卡（cardID、圈到的行、那張卡的開始秒數，畫面寫「也涵蓋 mm:ss 那張」）
struct RecheckSpan: Codable, Equatable {
    var cardID: Int
    var lines: [Int]
    var start: Double? = nil
}

/// v0.28.0 一次重查裡一張卡的部分：這張卡現在畫面上的全部行、圈到其中哪幾行
struct RecheckPart: Equatable {
    var cardID: Int
    var lines: [String]
    var selected: [Int]
}

/// 一次重查（存在卡片.json）。lines＝圈到的行；asked＝送出去的那幾行字。
struct CardRecheck: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case waiting, done, failed
    }

    var id: Int
    var lines: [Int]
    var asked: String
    var state: State = .waiting
    var conclusion: String? = nil
    var why: String? = nil
    var sources: [RecheckSource]? = nil
    /// 真的改進逐字稿的
    var applied: [RecheckFix]? = nil
    var unsure: String? = nil
    /// 等待中、沒查到的原因（不含稿的字）
    var note: String? = nil
    var costUSD: Double? = nil
    var searches: Int? = nil
    /// v0.28.0：沒把握的猜測（可以按「套用」）。舊的卡片.json 沒有這欄＝nil
    var maybe: [RecheckMaybe]? = nil
    /// v0.28.0：跨卡圈選時，圈到的其他卡（這筆重查掛在圈到的第一張卡上）；nil＝只有這張卡
    var also: [RecheckSpan]? = nil

    /// 這筆重查涉及的卡和行（第一張是掛著的這張）
    func spans(host: Int) -> [(card: Int, lines: [Int])] {
        var out: [(card: Int, lines: [Int])] = [(card: host, lines: lines)]
        for span in also ?? [] {
            out.append((card: span.cardID, lines: span.lines))
        }
        return out
    }
}

/// 重查回覆最後那個 JSON
struct RecheckReply: Equatable {
    var conclusion: String
    var why: String
    var fixes: [RecheckFix]
    var unsure: String
    /// v0.28.0：沒把握但有具體猜測的
    var maybe: [RecheckFix] = []
    /// v0.28.0：Haiku 說真的支持結論的網址；nil＝回覆沒有這欄（舊格式）
    var sources: [String]? = nil

    /// 從全部文字裡找最後一個讀得出來、有 conclusion 或 fixes 的 JSON 物件（前面可以有說明字、```json）
    static func parse(_ text: String) -> RecheckReply? {
        guard let object = lastObject(text, keys: ["conclusion", "fixes"]) else { return nil }
        return make(object)
    }

    /// v0.29.1（重查、參照詞搜尋共用）：從全部文字裡找最後一個讀得出來、至少有 keys 其中一個鍵的 JSON 物件
    static func lastObject(_ text: String, keys: [String]) -> [String: Any]? {
        let chars = Array(text)
        let opens = chars.indices.filter { chars[$0] == "{" }
        for start in opens.reversed() {
            guard let end = balancedEnd(chars, from: start) else { continue }
            let body = String(chars[start...end])
            guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else { continue }
            if keys.contains(where: { (k: String) -> Bool in object[k] != nil }) {
                return object
            }
        }
        return nil
    }

    /// 從 { 開始找配對的 }（字串裡的括號、跳脫字元不算）
    static func balancedEnd(_ chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    private static func string(_ value: Any?) -> String {
        if let s = value as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let list = value as? [Any] {
            return list.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "；")
        }
        return ""
    }

    private static func pairs(_ value: Any?) -> [RecheckFix] {
        let list = value as? [Any] ?? []
        return list.compactMap { item -> RecheckFix? in
            guard let fix = item as? [String: Any] else { return nil }
            let old = string(fix["old"]), new = string(fix["new"])
            return old.isEmpty ? nil : RecheckFix(old: old, new: new)
        }
    }

    /// sources：網址字串的清單（也收 {"url": …}）；沒有這欄＝nil
    private static func urls(_ value: Any?) -> [String]? {
        guard let list = value as? [Any] else { return nil }
        return list.compactMap { item -> String? in
            if let s = item as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let d = item as? [String: Any], let s = d["url"] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            return nil
        }.filter { !$0.isEmpty }
    }

    private static func make(_ object: [String: Any]) -> RecheckReply {
        RecheckReply(conclusion: string(object["conclusion"]), why: string(object["why"]), fixes: pairs(object["fixes"]),
                     unsure: string(object["unsure"]), maybe: pairs(object["maybe"]), sources: urls(object["sources"]))
    }
}

/// 一次回應（可能是 pause_turn 的中間那段）解析出來的東西。content 原樣留著（pause_turn 要原封不動送回去）。
struct RecheckResponse {
    var stopReason: String?
    var content: [Any]
    var usage: Usage?
    var searches: Int
}

enum RecheckPrompt {
    static let maxTokens = 4000
    static let maxContinuations = 2
    /// 每次網路搜尋 0.01 美元（每 1,000 次 10 美元）
    static let searchUSD = 0.01

    static let system = """
    你幫忙核對錄音逐字稿裡可能聽錯的字。使用者用筆圈起幾行 Whisper 逐字稿（語音辨識，常把專有名詞、術語、數字聽成同音字）。
    請用網路搜尋查證圈起來那幾行裡可疑的詞，判斷原本講的應該是什麼。只看圈起來的行，不要改寫句子、不要摘要。
    回答用繁體中文（台灣用語），最後一定要附一個 JSON 物件（整個回答只放這一個，放在最後）：
    {"conclusion": "一句話：這幾行該改成什麼（不用改就說不用改）", "why": "一句話說為什麼", "fixes": [{"old": "逐字稿裡原本的字，要和圈起來的行逐字一樣", "new": "改成的字"}], "maybe": [{"old": "逐字稿裡原本的字", "new": "猜測的字"}], "unsure": "沒把握的原因；沒有就空字串", "sources": ["真的支持結論的網址"]}
    規則：
    - 結論說要改的每一處，都一定要放進 fixes，不能只寫在 conclusion 或 why。
    - 沒把握、但有具體猜測（例如「很可能是某某」）的，放進 maybe，不要放進 fixes，也不要只寫在 unsure。
    - fixes 和 maybe 的 old 要短（只放聽錯的那個詞），一定要在圈起來的行裡逐字找得到；同一處只放其中一邊。
    - unsure 只寫文字說明（哪裡查不到、為什麼沒把握），不要在這裡放改法。
    - sources 只放真的支持結論的網址；沒有就給空陣列。和結論無關的搜尋結果不要列。
    """

    static func webSearchTool() -> [String: Any] {
        [
            "type": "web_search_20250305",
            "name": "web_search",
            "max_uses": 3,
            "user_location": ["type": "approximate", "country": "TW", "timezone": "Asia/Taipei"],
        ]
    }

    /// 使用者訊息：課名（沒有就寫討論會）、這張卡的重點、圈起來的行（不送整份逐字稿）
    /// v0.28.0：重點是固定字樣（聽不清、現場口令）也當沒有重點
    /// v0.29.0：nonCourse＝非課程（沒課名時寫非課程，不寫討論會）；topic＝使用者寫的主題（有才多一行）
    static func userMessage(course: String, key: String, lines: [String], nonCourse: Bool = false, topic: String? = nil) -> String {
        let name = course.isEmpty ? RecordScene.noCourseName(nonCourse: nonCourse) : course
        let point = key.isEmpty || CardText.isPlaceholderKey(key) ? "（還沒有）" : key
        let topicLine: String = SessionTopic.clean(topic).map { (t: String) -> String in "主題（使用者自己寫的）：" + t + "\n" } ?? ""
        return "課名：\(name)\n" + topicLine + "這段的重點：\(point)\n\n圈起來的逐字稿（一行一句）：\n" + lines.joined(separator: "\n")
    }

    /// 請求內容（JSONSerialization 編，pause_turn 時把上一段回應的 content 原封不動放成 assistant）
    /// v0.29.1：system 可換（參照詞搜尋用同一份請求，只換提示詞）
    static func body(userMessage: String, assistant: [Any]?, system: String = RecheckPrompt.system) throws -> Data {
        var messages: [[String: Any]] = [["role": "user", "content": userMessage]]
        if let assistant, !assistant.isEmpty {
            messages.append(["role": "assistant", "content": assistant])
        }
        let object: [String: Any] = [
            "model": HaikuPrompt.model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages,
            "tools": [webSearchTool()],
            "output_config": ["effort": "low"],
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// 回應解析：stop_reason、content（原樣）、usage、這次搜尋了幾次
    static func parse(_ data: Data) -> RecheckResponse? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let content = object["content"] as? [Any] ?? []
        var usage: Usage?
        var searches = 0
        if let raw = object["usage"] as? [String: Any] {
            if let usageData = try? JSONSerialization.data(withJSONObject: raw) {
                usage = try? JSONDecoder().decode(Usage.self, from: usageData)
            }
            if let server = raw["server_tool_use"] as? [String: Any] {
                searches = (server["web_search_requests"] as? Int) ?? Int((server["web_search_requests"] as? Double) ?? 0)
            }
        }
        return RecheckResponse(stopReason: object["stop_reason"] as? String, content: content, usage: usage, searches: searches)
    }

    /// 全部 text 區塊接起來（有引用時文字會被切成好幾塊）
    static func text(_ content: [Any]) -> String {
        content.compactMap { $0 as? [String: Any] }.filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }.joined()
    }

    /// 比對網址用：小寫、去掉最後的 /
    static func urlKey(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// v0.28.0 來源：keep＝回覆 JSON 的 sources（Haiku 說支持結論的網址）。
    /// 有 keep：只留引用或搜尋結果裡、網址在 keep 的（空陣列＝不列；編出來、沒搜到的網址不列）；
    /// 沒有 keep（舊格式）：只用文字裡的引用，不再把全部搜尋結果都列上去（以前會列到和內容無關的網頁）。
    static func sources(_ content: [Any], keep: [String]?, limit: Int = 5) -> [RecheckSource] {
        let blocks = content.compactMap { $0 as? [String: Any] }
        var cited: [RecheckSource] = []
        for block in blocks where (block["type"] as? String) == "text" {
            for citation in (block["citations"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] })
            where (citation["type"] as? String) == "web_search_result_location" {
                if let url = citation["url"] as? String {
                    cited.append(RecheckSource(title: (citation["title"] as? String) ?? "", url: url))
                }
            }
        }
        var found: [RecheckSource] = []
        for block in blocks where (block["type"] as? String) == "web_search_tool_result" {
            // 成功是清單；出錯是一個物件（有 error_code），跳過
            for item in (block["content"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] })
            where (item["type"] as? String) == "web_search_result" {
                if let url = item["url"] as? String {
                    found.append(RecheckSource(title: (item["title"] as? String) ?? "", url: url))
                }
            }
        }
        var pool = cited
        if let keep {
            let wanted = Set(keep.map(urlKey))
            pool = (cited + found).filter { wanted.contains(urlKey($0.url)) }
        }
        var seen = Set<String>()
        var out: [RecheckSource] = []
        for source in pool {
            let lower = source.url.lowercased()
            let k = urlKey(source.url)
            guard lower.hasPrefix("https://") || lower.hasPrefix("http://"), !seen.contains(k) else { continue }
            seen.insert(k)
            let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(RecheckSource(title: title.isEmpty ? source.url : title, url: source.url))
            if out.count >= limit { break }
        }
        return out
    }

    /// 搜尋出錯的代碼（web_search_tool_result 的 content 是物件時）；沒有＝nil
    static func searchError(_ content: [Any]) -> String? {
        for block in content.compactMap({ $0 as? [String: Any] }) where (block["type"] as? String) == "web_search_tool_result" {
            if let error = block["content"] as? [String: Any], let code = error["error_code"] as? String {
                return code
            }
        }
        return nil
    }

    /// 花費：token 照 Haiku 價錢＋搜尋次數 × 0.01
    static func cost(usage: Usage?, searches: Int) -> Double {
        (usage.map(Cost.usd) ?? 0) + Double(searches) * searchUSD
    }

    /// 把改法套進圈起來的行：old 要在圈起來的行裡找得到（依行序找第一行、換第一處）。
    /// v0.28.0：unsure 講到的改法不再丟掉，改放進 maybe（畫面上有「套用」）；回覆的 maybe 只留 old 在圈起來的行裡找得到的，
    /// 找不到的放 lost（畫面寫進「沒把握」的字）。回傳改好的行、要記進卡片的改動、真的套上的改法、可以按套用的猜測、找不到的猜測。
    static func apply(lines: [String], selected: [Int], reply: RecheckReply)
        -> (lines: [String], edits: [CardEdit], applied: [RecheckFix], maybe: [RecheckFix], lost: [RecheckFix]) {
        var out = lines
        var edits: [CardEdit] = []
        var applied: [RecheckFix] = []
        var guesses: [RecheckFix] = []
        let unsure = reply.unsure
        let rows = Array(Set(selected)).sorted().filter { $0 >= 0 && $0 < out.count }
        for fix in reply.fixes {
            let old = fix.old, new = fix.new
            guard !old.isEmpty, old != new else { continue }
            if !unsure.isEmpty, unsure.contains(old) || (!new.isEmpty && unsure.contains(new)) {
                guesses.append(fix)
                continue
            }
            guard let row = rows.first(where: { out[$0].contains(old) }), let range = out[row].range(of: old) else { continue }
            let before = out[row]
            let after = before.replacingCharacters(in: range, with: new)
            out[row] = after
            edits.append(CardEdit(line: row, before: before, after: after, by: CardEdit.web))
            applied.append(fix)
        }
        var maybe: [RecheckFix] = []
        var lost: [RecheckFix] = []
        for fix in guesses + reply.maybe {
            guard !fix.old.isEmpty, fix.old != fix.new else { continue }
            // 同一處已經套上、或已經列過的不重複
            if applied.contains(where: { $0.old == fix.old }) || maybe.contains(fix) || lost.contains(fix) { continue }
            if rows.contains(where: { out[$0].contains(fix.old) }) {
                maybe.append(fix)
            } else {
                lost.append(fix)
            }
        }
        return (out, edits, applied, maybe, lost)
    }

    /// v0.28.0 跨卡：各卡的行接成一份（卡的順序照 parts），圈到的行換成接起來之後的行號；owner[i]＝接起來第 i 行原本是哪張卡第幾行
    static func combine(_ parts: [RecheckPart]) -> (lines: [String], selected: [Int], owner: [CardLineRef]) {
        var lines: [String] = []
        var selected: [Int] = []
        var owner: [CardLineRef] = []
        for part in parts {
            let base = lines.count
            for row in Array(Set(part.selected)).sorted() where row >= 0 && row < part.lines.count {
                selected.append(base + row)
            }
            for (i, text) in part.lines.enumerated() {
                lines.append(text)
                owner.append(CardLineRef(card: part.cardID, line: i))
            }
        }
        return (lines, selected, owner)
    }

    /// v0.28.0 跨卡：接起來那份的改動，行號換回各卡自己的行號，依卡分開（同一張卡照原本順序）；對不到的丟掉
    static func split(_ edits: [CardEdit], owner: [CardLineRef]) -> [Int: [CardEdit]] {
        var out: [Int: [CardEdit]] = [:]
        for edit in edits where edit.line >= 0 && edit.line < owner.count {
            let ref = owner[edit.line]
            var local = edit
            local.line = ref.line
            out[ref.card, default: []].append(local)
        }
        return out
    }

    /// v0.28.0 按「套用」：一個猜測套進圈起來的行（和 fixes 同一套找法），回傳要記進各卡的改動（找不到＝空）
    static func applyMaybe(_ fix: RecheckFix, parts: [RecheckPart]) -> [Int: [CardEdit]] {
        let joined = combine(parts)
        let one = RecheckReply(conclusion: "", why: "", fixes: [fix], unsure: "")
        let result = apply(lines: joined.lines, selected: joined.selected, reply: one)
        return split(result.edits, owner: joined.owner)
    }

    /// v0.28.0 跨卡圈選：圈到的行依卡分組，卡照 order（卡片的時間順序；不在 order 裡的卡不算），每張卡的行去重複、由小到大
    static func group(_ refs: [CardLineRef], order: [Int]) -> [(card: Int, rows: [Int])] {
        var byCard: [Int: Set<Int>] = [:]
        for ref in refs {
            byCard[ref.card, default: []].insert(ref.line)
        }
        var out: [(card: Int, rows: [Int])] = []
        for id in order {
            if let rows = byCard[id], !rows.isEmpty {
                out.append((card: id, rows: rows.sorted()))
            }
        }
        return out
    }

    /// v0.28.0 還在查的重查圈到哪些行（含跨卡的其他卡）：卡片編號 → 行（畫面淡底色）
    static func waitingRows(_ cards: [LiveCard]) -> [Int: Set<Int>] {
        var out: [Int: Set<Int>] = [:]
        for card in cards {
            for item in card.rechecks ?? [] where item.state == .waiting {
                for span in item.spans(host: card.id) {
                    out[span.card, default: []].formUnion(span.lines)
                }
            }
        }
        return out
    }
}

// MARK: - v0.28.0 逐字稿改了之後重算重點、整理版

/// 重算回覆（JSON）
struct CardRefreshReply: Equatable {
    var key: String
    var tidy: String

    /// 容錯：前後多了說明字或 ```json 也讀（第一個 { 到最後一個 }）；key 空＝不算
    static func parse(_ text: String) -> CardRefreshReply? {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return nil }
        let body = String(text[open...close])
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else { return nil }
        let key = ((object["key"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tidy = ((object["tidy"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return CardRefreshReply(key: key, tidy: tidy)
    }
}

/// 重算請求回來的結果。unreadable 的 reason 不含稿的字。
enum CardRefreshResult: Equatable {
    case reply(CardRefreshReply, usage: Usage?)
    case refusal(usage: Usage?)
    case truncated(usage: Usage?)
    case unreadable(reason: String, usage: Usage?)

    var usage: Usage? {
        switch self {
        case .reply(_, let u), .refusal(let u), .truncated(let u), .unreadable(_, let u): return u
        }
    }
}

/// 一張卡的逐字稿被改（使用者改字、留說明、重查改字、按套用）之後，小的 Haiku 呼叫（不上網）照改好的逐字稿重寫這張卡的重點和整理版。
/// 只送課名、這張卡改好的逐字稿、這張卡使用者的說明、原本的重點和整理版；不送投影片。
enum CardRefresh {
    static let maxTokens = 1500
    /// 最後一次改動後等幾秒再送（錄音中）；停止後馬上送
    static let delay = 4.0

    static let system = """
    你在幫一位學生更新上課筆記的一張卡。這張卡的逐字稿剛被修正過（使用者改了字、或查證後改了字），請照修正後的逐字稿重寫這張卡的重點（key）和整理版（tidy），回一個 JSON：{"key": "…", "tidy": "…"}。
    逐字稿是準的。重點和整理版不得和逐字稿矛盾：原本的重點、整理版只是參考，和逐字稿不合的地方一律照逐字稿改（例如逐字稿說「不是某某」，就不能寫成「是某某」）。
    講話的人不一定是老師：可能是學長姐、助教、上台報告的同學或來賓。看不出是誰就寫「講者」或不寫主詞，不要一律寫「老師」。
    課名是使用者自己選的（寫「沒有課名」就不管）。這堂的主題以課名為準，不要因為稿裡某個詞、或使用者改過的某個字，就改判成別的主題。非課程的場合有「這場的主題」時，主題以它為準。
    「使用者的說明」是使用者給你的話：照著做（你這裡不能上網查，查不到就不要假裝查過），但不要把說明的字抄進 key、tidy。
    tidy：2–4 句通順中文，只寫講者真的講到的。整段聽不清，或只是現場口令（喊口號、拍照、點名）、雜聲，就只寫（這段聽不清）或（現場口令），不要編成像真的內容。只有一部分是這樣：只整理有內容的部分。
    key：一句重點，15 字內，只寫這段真的講到的內容。整段聽不清，或只是現場口令、雜聲，key 就寫（這段聽不清）或（現場口令），不要從口令或雜聲編出重點。
    """

    static let schemaText = #"{"type":"object","additionalProperties":false,"required":["key","tidy"],"properties":{"key":{"type":"string"},"tidy":{"type":"string"}}}"#

    /// 放在 system 第二段的課名（很短，不會真的快取）；沒課名寫討論會
    /// v0.29.0：nonCourse＝非課程（沒課名時寫非課程）
    static func courseBlock(course: String, nonCourse: Bool = false) -> String {
        "課名：" + (course.isEmpty ? RecordScene.noCourseName(nonCourse: nonCourse) : course)
    }

    /// 使用者訊息：改好的逐字稿（一句一行）、使用者的說明（有才放）、原本的重點和整理版（固定字樣照寫，讓它知道原本是聽不清）
    /// v0.29.0：topic＝非課程時使用者寫的主題（有才放在最前面；主題錄音中可以改，所以不放 system）
    static func userMessage(transcript: [String], notes: [String], key: String, tidy: String, topic: String? = nil) -> String {
        var text: String = SessionTopic.clean(topic).map { (t: String) -> String in "這場的主題（使用者自己寫的）：" + t + "\n\n" } ?? ""
        text += "這張卡修正後的逐字稿（一句一行，這是準的）：\n" + transcript.joined(separator: "\n")
        if !notes.isEmpty {
            text += "\n\n使用者的說明（照著做，但不要抄進 key、tidy）：\n" + notes.joined(separator: "\n")
        }
        text += "\n\n原本的重點（只參考，和逐字稿不合就改）：" + (key.isEmpty ? "（沒有）" : key)
        text += "\n原本的整理版（只參考，和逐字稿不合就改）：" + (tidy.isEmpty ? "（沒有）" : tidy)
        return text
    }

    static func requestBody(courseBlock: String, userMessage: String) throws -> Data {
        try HaikuPrompt.requestBody(courseBlock: courseBlock, userMessage: userMessage, maxTokens: maxTokens,
                                    system: system, schemaText: schemaText)
    }

    /// 先看 stop_reason（refusal、max_tokens 不重送），再從 content 找第一個 type=="text" 的區塊
    static func parseResponse(_ data: Data) -> CardRefreshResult {
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
        guard let reply = CardRefreshReply.parse(text) else {
            return .unreadable(reason: "文字區塊不是規定的 JSON", usage: response.usage)
        }
        return .reply(reply, usage: response.usage)
    }
}

// MARK: - 討論會停止後分人（卡片的行 → 時間 → 講者）

/// 一行字和它大約的時間（錄音秒數，含續錄位移）
struct SpeakerLine: Equatable {
    var text: String
    var start: Double
    var end: Double
}

enum CardSpeakers {
    private static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)

    /// 一張卡的行配上時間：用這張卡的單位（Whisper 的字和時間）照原稿字數比例換算；沒有單位就在卡的開始、結束之間平均分。
    static func times(lines: [CardLine], units: [TimedPiece], start: Double, end: Double) -> [SpeakerLine] {
        let total = lines.last?.rawTo ?? 0
        let timed = units.filter { $0.start >= 0 && $0.end >= $0.start }
        let counts = timed.map { CardDiff.core($0.text).count }
        let unitTotal = counts.reduce(0, +)
        func at(_ k: Int) -> Double {
            guard total > 0 else { return start }
            let f = Double(min(max(k, 0), total)) / Double(total)
            guard unitTotal > 0 else { return start + (end - start) * f }
            let target = f * Double(unitTotal)
            var cum = 0.0
            for (i, unit) in timed.enumerated() {
                let n = Double(counts[i])
                if n > 0, target <= cum + n {
                    return unit.start + (unit.end - unit.start) * ((target - cum) / n)
                }
                cum += n
            }
            return timed.last?.end ?? end
        }
        return lines.map { line in
            SpeakerLine(text: line.text, start: at(line.rawFrom), end: max(at(line.rawFrom), at(line.rawTo)))
        }
    }

    private static func speaker(of line: SpeakerLine, turns: [SpeakerTurn]) -> String? {
        var seconds: [String: Double] = [:]
        for turn in turns {
            let shared = min(line.end, turn.end) - max(line.start, turn.start)
            if shared > 0 { seconds[turn.speaker, default: 0] += shared }
        }
        if let best = seconds.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key {
            return best
        }
        // 沒重疊（或這行沒時間長度）：用時間最近的那段
        let at = (line.start + line.end) / 2
        func distance(_ turn: SpeakerTurn) -> Double {
            at < turn.start ? turn.start - at : (at > turn.end ? at - turn.end : 0)
        }
        return turns.min { distance($0) < distance($1) }?.speaker
    }

    /// 每張卡（一組行）依講者分段：同一個人連續的行接成一段「A：…」，換人或換卡就換段；段落之間空一行（和 SpeakerLabeler 同格式）。
    /// 沒有講者段落＝不標，names 空。
    static func label(_ cards: [[SpeakerLine]], turns: [SpeakerTurn]) -> (text: String, names: [String]) {
        let nonEmpty = cards.map { $0.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty } }.filter { !$0.isEmpty }
        guard !turns.isEmpty else {
            return (nonEmpty.map { $0.map(\.text).joined() }.joined(separator: "\n\n"), [])
        }
        var names: [String: String] = [:]
        var order: [String] = []
        var paragraphs: [String] = []
        for card in nonEmpty {
            var current: String?
            var buffer = ""
            for line in card {
                var name = current ?? letters[0]
                if let raw = speaker(of: line, turns: turns) {
                    if names[raw] == nil {
                        let letter = order.count < letters.count ? letters[order.count] : "講者\(order.count + 1)"
                        names[raw] = letter
                        order.append(letter)
                    }
                    name = names[raw] ?? name
                }
                if let current, current != name, !buffer.isEmpty {
                    paragraphs.append("\(current)：\(buffer)")
                    buffer = ""
                }
                current = name
                buffer += line.text
            }
            if let current, !buffer.isEmpty {
                paragraphs.append("\(current)：\(buffer)")
            }
        }
        return (paragraphs.joined(separator: "\n\n"), order)
    }
}
