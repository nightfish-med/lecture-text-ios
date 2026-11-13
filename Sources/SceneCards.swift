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
}

// MARK: - 使用者改的字、重查改的字

/// 一行的改動。line＝改的時候是第幾行；before＝改之前那行的字；after＝改成的字。
/// by：user＝使用者點一下改的（之後的批次送 Haiku 時當參考）；web＝Pencil 圈起來重查改的。
struct CardEdit: Codable, Equatable {
    var line: Int
    var before: String
    var after: String
    var by: String

    static let user = "user"
    static let web = "web"
}

enum CardEdits {
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

    /// 卡片使用者訊息後面接的一段（沒有改過＝空字串）
    static func promptBlock(_ edits: [CardEdit]) -> String {
        let pairs = promptPairs(edits)
        guard !pairs.isEmpty else { return "" }
        return "\n\n這場使用者改過（左＝原本聽到的，右＝使用者改成的；同樣的字照這樣寫）：\n" + pairs.joined(separator: "\n")
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
}

/// 一行在卡片欄裡的上下位置（點）
struct LineBox: Equatable {
    var index: Int
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
}

/// 重查回覆最後那個 JSON
struct RecheckReply: Equatable {
    var conclusion: String
    var why: String
    var fixes: [RecheckFix]
    var unsure: String

    /// 從全部文字裡找最後一個讀得出來、有 conclusion 或 fixes 的 JSON 物件（前面可以有說明字、```json）
    static func parse(_ text: String) -> RecheckReply? {
        let chars = Array(text)
        let opens = chars.indices.filter { chars[$0] == "{" }
        for start in opens.reversed() {
            guard let end = balancedEnd(chars, from: start) else { continue }
            let body = String(chars[start...end])
            guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
                  object["conclusion"] != nil || object["fixes"] != nil else { continue }
            return make(object)
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

    private static func make(_ object: [String: Any]) -> RecheckReply {
        let list = object["fixes"] as? [Any] ?? []
        let fixes = list.compactMap { item -> RecheckFix? in
            guard let fix = item as? [String: Any] else { return nil }
            let old = string(fix["old"]), new = string(fix["new"])
            return old.isEmpty ? nil : RecheckFix(old: old, new: new)
        }
        return RecheckReply(conclusion: string(object["conclusion"]), why: string(object["why"]), fixes: fixes,
                            unsure: string(object["unsure"]))
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
    {"conclusion": "一句話：這幾行該改成什麼（不用改就說不用改）", "why": "一句話說為什麼", "fixes": [{"old": "逐字稿裡原本的字，要和圈起來的行逐字一樣", "new": "改成的字"}], "unsure": "沒把握的地方；都有把握就空字串"}
    fixes 只放有把握的改法，old 要短（只放聽錯的那個詞），一定要在圈起來的行裡找得到；沒把握的不要放進 fixes，寫在 unsure。
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
    static func userMessage(course: String, key: String, lines: [String]) -> String {
        let name = course.isEmpty ? "（討論會，沒有課名）" : course
        let point = key.isEmpty ? "（還沒有）" : key
        return "課名：\(name)\n這段的重點：\(point)\n\n圈起來的逐字稿（一行一句）：\n" + lines.joined(separator: "\n")
    }

    /// 請求內容（JSONSerialization 編，pause_turn 時把上一段回應的 content 原封不動放成 assistant）
    static func body(userMessage: String, assistant: [Any]?) throws -> Data {
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

    /// 來源：先用文字裡的引用（web_search_result_location），沒有再用搜尋結果；只收 http(s)、去重複、最多 limit 個
    static func sources(_ content: [Any], limit: Int = 5) -> [RecheckSource] {
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
        var seen = Set<String>()
        var out: [RecheckSource] = []
        for source in (cited.isEmpty ? found : cited) {
            let lower = source.url.lowercased()
            guard lower.hasPrefix("https://") || lower.hasPrefix("http://"), !seen.contains(source.url) else { continue }
            seen.insert(source.url)
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

    /// 把改法套進圈起來的行：old 要在圈起來的行裡找得到（依行序找第一行、換第一處）；unsure 講到的字不套。
    /// 回傳改好的行、要記進卡片的改動、真的套上的改法。
    static func apply(lines: [String], selected: [Int], reply: RecheckReply) -> (lines: [String], edits: [CardEdit], applied: [RecheckFix]) {
        var out = lines
        var edits: [CardEdit] = []
        var applied: [RecheckFix] = []
        let unsure = reply.unsure
        let rows = Array(Set(selected)).sorted().filter { $0 >= 0 && $0 < out.count }
        for fix in reply.fixes {
            let old = fix.old, new = fix.new
            guard !old.isEmpty, old != new else { continue }
            if !unsure.isEmpty, unsure.contains(old) || (!new.isEmpty && unsure.contains(new)) { continue }
            guard let row = rows.first(where: { out[$0].contains(old) }), let range = out[row].range(of: old) else { continue }
            let before = out[row]
            let after = before.replacingCharacters(in: range, with: new)
            out[row] = after
            edits.append(CardEdit(line: row, before: before, after: after, by: CardEdit.web))
            applied.append(fix)
        }
        return (out, edits, applied)
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
