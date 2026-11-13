import Foundation

// v0.26.0 即時模式 1「每批一張卡」的純邏輯（只用 Foundation，shape_check 也編）：
// 卡片資料、送 Haiku 的使用者訊息與請求、回覆解析（容錯）、原稿 vs 擴寫的逐字比對、一句一行、複製與整理版的字。
// 網路與排程在 LiveReviewer.swift，畫面在 Views.swift。這個檔不寫 log 字串（卡片的字只進「… 卡片.json」）。

/// 一批（約 60 秒）一張卡。id＝批次編號；raw＝送出的 Whisper 原稿；expanded＝Haiku 擴寫式校正後的全文。
struct LiveCard: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        /// 已排進批次，還沒回來
        case waiting
        /// 整理到了
        case done
        /// 沒整理到（重試用完、400、拒絕、超長、解析失敗）：只放原稿
        case failed
    }

    let id: Int
    var start: Double
    var end: Double
    var raw: String
    var state: State = .waiting
    var page: Int? = nil
    var key = ""
    var tidy = ""
    var unsure: [String] = []
    var expanded = ""
    /// 這張卡各次請求加起來的美元
    var costUSD = 0.0
    /// 沒整理到、或擴寫沒採用的原因（不含稿的字）
    var note: String? = nil
    /// v0.27.0：使用者點一下改的行、Pencil 重查改的行（依序套用）。舊的卡片.json 沒有這欄，所以是 Optional
    var edits: [CardEdit]? = nil
    /// v0.27.0：Pencil 圈起來重查（Haiku＋網路搜尋）的結果
    var rechecks: [CardRecheck]? = nil

    /// 逐字稿用的字：整理到就用擴寫，否則原稿；v0.27.0 再套上改過的行（一句一行套完接回去）
    var transcriptText: String {
        let base = state == .done && !expanded.isEmpty ? expanded : raw
        guard let edits, !edits.isEmpty else { return base }
        let lines = CardDiff.lines(base).components(separatedBy: "\n")
        return CardEdits.apply(lines: lines, edits: edits).lines.joined()
    }
}

/// 卡片的回覆（JSON）。欄位缺了用預設；expanded 空或缺＝整份不算。
struct CardReply: Equatable {
    var page: Int?
    var key: String
    var tidy: String
    var unsure: [String]
    var expanded: String

    private struct Loose: Decodable {
        var page: Int?
        var key = ""
        var tidy = ""
        var unsure: [String] = []
        var expanded = ""

        enum CodingKeys: String, CodingKey { case page, key, tidy, unsure, expanded }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let n = try? c.decodeIfPresent(Int.self, forKey: .page) {
                page = n
            } else if let d = try? c.decodeIfPresent(Double.self, forKey: .page) {
                page = d.isFinite ? Int(d) : nil
            } else if let s = try? c.decodeIfPresent(String.self, forKey: .page) {
                page = Int(s.filter { $0.isASCII && $0.isNumber })
            } else {
                page = nil
            }
            key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? ""
            tidy = (try? c.decodeIfPresent(String.self, forKey: .tidy)) ?? ""
            if let list = try? c.decodeIfPresent([String].self, forKey: .unsure) {
                unsure = list
            } else if let one = try? c.decodeIfPresent(String.self, forKey: .unsure) {
                unsure = one.components(separatedBy: CharacterSet(charactersIn: "、,，;；\n"))
            } else {
                unsure = []
            }
            expanded = (try? c.decodeIfPresent(String.self, forKey: .expanded)) ?? ""
        }
    }

    /// 容錯：前後多了說明字或 ```json 也讀（取第一個 { 到最後一個 }）；page 是 0、null、讀不出來＝nil；unsure 最多 2 個。
    static func parse(_ text: String) -> CardReply? {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return nil }
        let body = String(text[open...close])
        guard let loose = try? JSONDecoder().decode(Loose.self, from: Data(body.utf8)) else { return nil }
        let expanded = loose.expanded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expanded.isEmpty else { return nil }
        let unsure = loose.unsure.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return CardReply(
            page: loose.page.flatMap { $0 > 0 ? $0 : nil },
            key: loose.key.trimmingCharacters(in: .whitespacesAndNewlines),
            tidy: loose.tidy.trimmingCharacters(in: .whitespacesAndNewlines),
            unsure: Array(unsure.prefix(2)),
            expanded: expanded
        )
    }
}

/// 卡片請求回來的結果。unreadable 的 reason 不含稿的字。
enum CardResult: Equatable {
    case reply(CardReply, usage: Usage?)
    case refusal(usage: Usage?)
    case truncated(usage: Usage?)
    case unreadable(reason: String, usage: Usage?)

    var usage: Usage? {
        switch self {
        case .reply(_, let u), .refusal(let u), .truncated(let u), .unreadable(_, let u): return u
        }
    }
}

enum CardPrompt {
    /// 提示詞（tools/haiku_prompt/card.txt，由 同步提示詞.py 產生）
    static let system = HaikuPromptText.card
    /// 結構化輸出的 schema（tools/haiku_prompt/card_schema.json）
    static let schemaText = HaikuPromptText.cardSchema
    /// 擴寫全文比改字長很多（一分鐘約 300–600 字），上限放寬
    static let maxTokens = 8000
    /// 擴寫的字（不算標點空白）少於原稿這個比例＝像摘要，不採用擴寫（卡片照樣顯示重點、整理版）
    static let minKeepRatio = 0.6

    /// 使用者訊息：前文（上一段的原稿）＋這段原稿（Whisper）＋ Apple 同一段（有才附）。不帶 [s編號]，免得編號混進擴寫。
    /// v0.27.0：userEdits＝這場使用者改過的（CardEdits.promptBlock，接在使用者訊息最後；不放進有快取的課程區塊）
    static func userMessage(context: String, raw: String, reference: String, referenceName: String, userEdits: String = "") -> String {
        let ctx = context.isEmpty ? "（無）" : context
        var text = "前文（只參考，不要整理、不要寫進 expanded）：\n\(ctx)\n\n這段原稿（Whisper，要整理的就是這段）：\n\(raw)"
        if !reference.isEmpty {
            text += "\n\n\(referenceName) 同一段（另一個辨識器，只當證據）：\n\(reference)"
        }
        return text + userEdits
    }

    static func requestBody(courseBlock: String, userMessage: String) throws -> Data {
        try HaikuPrompt.requestBody(courseBlock: courseBlock, userMessage: userMessage, maxTokens: maxTokens,
                                    system: system, schemaText: schemaText)
    }

    /// 先看 stop_reason（refusal、max_tokens 不重送），再從 content 找第一個 type=="text" 的區塊（前面可能有 thinking）。
    static func parseResponse(_ data: Data) -> CardResult {
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
        guard let reply = CardReply.parse(text) else {
            return .unreadable(reason: "文字區塊不是規定的 JSON", usage: response.usage)
        }
        return .reply(reply, usage: response.usage)
    }

    /// 程式把關：頁碼要在投影片範圍內（pageCount＝送出的頁數；0＝沒有投影片，頁碼一律不收）；
    /// 擴寫明顯比原稿短（像摘要）就不採用，逐字稿用原稿。回傳整理好的卡片欄位和原因。
    static func accept(_ reply: CardReply, raw: String, pageCount: Int) -> (reply: CardReply, note: String?) {
        var out = reply
        if let page = reply.page, !(pageCount > 0 && (1...pageCount).contains(page)) {
            out.page = nil
        }
        let before = CardDiff.core(raw).count
        let after = CardDiff.core(reply.expanded).count
        if before > 0, Double(after) < Double(before) * minKeepRatio {
            out.expanded = raw
            return (out, "擴寫比原稿短太多（\(after)／\(before) 字），逐字稿用原稿")
        }
        return (out, nil)
    }
}

// MARK: - 原稿 vs 擴寫：逐字比對

/// 逐字 LCS。標點、空白不算字（增減都不標）。結果是擴寫全文（已一句一行）切成的片段：
/// same＝原樣；changed＝新加或換掉的字（old＝被換掉的原字，只放在同一組的最後一片）；deleted＝純刪除（text 空、old＝被刪的字）。
enum CardDiff {
    enum Kind: String, Equatable {
        case same, changed, deleted
    }

    struct Piece: Equatable {
        var kind: Kind
        var text: String
        var old: String
        var group: Int
    }

    static let enders: Set<Character> = ["。", "？", "！", "?", "!"]
    static let closers: Set<Character> = ["」", "』", "）", ")", "”", "’", "\"", "】"]
    /// 太長不比（避免一次算太大的表）：原稿字數 × 擴寫字數
    static let maxCells = 6_000_000

    static func neutral(_ c: Character) -> Bool {
        c.isWhitespace || c.isPunctuation
    }

    /// 去掉標點、空白後的字
    static func core(_ text: String) -> [Character] {
        text.filter { !neutral($0) }.map { $0 }
    }

    /// 一句一行：原本的換行先拿掉，。？！?! 後面（連同後面的 」』）等）換行；句尾在最後就不換。
    static func lines(_ text: String) -> String {
        let chars = Array(text.filter { $0 != "\n" && $0 != "\r" && $0 != "\r\n" })
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            out.append(c)
            i += 1
            guard enders.contains(c) else { continue }
            while i < chars.count, closers.contains(chars[i]) {
                out.append(chars[i])
                i += 1
            }
            var k = i
            while k < chars.count, chars[k] == " " { k += 1 }
            if k < chars.count {
                out.append("\n")
                i = k
            }
        }
        return out
    }

    /// raw：送出的原稿；expanded：擴寫全文（這裡先做一句一行）。回傳的片段依序接起來＝lines(expanded)。
    static func pieces(raw: String, expanded: String) -> [Piece] {
        let a = core(raw)
        let b = Array(lines(expanded))
        let bk = b.indices.filter { !neutral(b[$0]) }
        let bb = bk.map { b[$0] }
        let n = a.count, m = bb.count, w = m + 1
        guard (n + 1) * w <= maxCells else {
            return b.isEmpty ? [] : [Piece(kind: .same, text: String(b), old: "", group: -1)]
        }
        var table = [Int32](repeating: 0, count: (n + 1) * w)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    let here = i * w + j
                    let below = here + w
                    if a[i] == bb[j] {
                        table[here] = table[below + 1] + 1
                    } else {
                        table[here] = max(table[below], table[here + 1])
                    }
                }
            }
        }
        var label = [Int](repeating: -1, count: b.count)
        var deletions: [Int: (group: Int, text: String)] = [:]
        var olds: [Int: String] = [:]
        var hunkDeleted = ""
        var hunkInserted: [Int] = []
        var groups = 0
        func flush(at position: Int) {
            if !hunkInserted.isEmpty {
                for index in hunkInserted { label[index] = groups }
                olds[groups] = hunkDeleted
                groups += 1
            } else if !hunkDeleted.isEmpty {
                deletions[position] = (groups, hunkDeleted)
                groups += 1
            }
            hunkDeleted = ""
            hunkInserted = []
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == bb[j] {
                flush(at: bk[j])
                i += 1
                j += 1
            } else if i < n, j >= m || table[i * w + w + j] >= table[i * w + j + 1] {
                hunkDeleted.append(a[i])
                i += 1
            } else {
                hunkInserted.append(bk[j])
                j += 1
            }
        }
        flush(at: b.count)

        var out: [Piece] = []
        func add(_ kind: Kind, _ ch: Character, _ group: Int) {
            if let last = out.last, last.kind == kind, last.group == group, kind != .deleted {
                out[out.count - 1].text.append(ch)
            } else {
                out.append(Piece(kind: kind, text: String(ch), old: "", group: group))
            }
        }
        for p in 0...b.count {
            if let d = deletions[p] {
                out.append(Piece(kind: .deleted, text: "", old: d.text, group: d.group))
            }
            guard p < b.count else { break }
            let g = label[p]
            add(g >= 0 ? .changed : .same, b[p], g)
        }
        var lastOfGroup: [Int: Int] = [:]
        for (k, piece) in out.enumerated() where piece.kind == .changed {
            lastOfGroup[piece.group] = k
        }
        for (g, k) in lastOfGroup {
            out[k].old = olds[g] ?? ""
        }
        return out
    }

    /// 測試、除錯用：same 原樣、changed 寫 [新|舊]、deleted 寫 {-舊}
    static func describe(_ pieces: [Piece]) -> String {
        pieces.map { piece -> String in
            switch piece.kind {
            case .same: return piece.text
            case .changed: return "[" + piece.text + (piece.old.isEmpty ? "" : "|" + piece.old) + "]"
            case .deleted: return "{-" + piece.old + "}"
            }
        }.joined()
    }

    /// 改了幾處（換字＋純加字＋純刪除；標點不算）
    static func changeCount(_ pieces: [Piece]) -> Int {
        Set(pieces.filter { $0.kind != .same }.map(\.group)).count
    }
}

// MARK: - 給人看的字（複製、整理版、逐字稿）

enum CardText {
    /// v0.26.2：送 Haiku 網路錯、等著再送的卡上那行小字
    static let retryNote = "網路不通，等一下再送"
    /// v0.26.3：錄音剛開始、還沒有任何字時的提示
    static let listening = "聽著…第一句通常 10–15 秒後出現"

    /// mm:ss（一小時以上 h:mm:ss），時間範圍用
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func range(_ card: LiveCard) -> String {
        clock(card.start) + "–" + clock(card.end)
    }

    /// 錄音中按複製：每張卡「[p.N] 重點」＋整理版（沒頁碼不寫 [p.N]；沒整理到的卡不放）
    static func copy(_ cards: [LiveCard]) -> String {
        cards.filter { $0.state == .done }.map { card -> String in
            let head = (card.page.map { "[p.\($0)] " } ?? "") + card.key
            return [head, card.tidy].filter { !$0.isEmpty }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// v0.26.1 分享到別的 App（例如分割畫面旁邊的 Gemini）：「[p.N] 重點」、整理版、原稿（擴寫，一句一行）、不確定的詞
    static func share(_ card: LiveCard) -> String {
        var parts: [String] = []
        let head = ((card.page.map { "[p.\($0)] " } ?? "") + card.key).trimmingCharacters(in: .whitespaces)
        if !head.isEmpty { parts.append(head) }
        if !card.tidy.isEmpty { parts.append(card.tidy) }
        let body = card.transcriptText
        if !body.isEmpty { parts.append("原稿：\n" + CardDiff.lines(body)) }
        if !card.unsure.isEmpty { parts.append("不確定：" + card.unsure.joined(separator: "、")) }
        return parts.joined(separator: "\n\n")
    }

    /// 匯出的整理版：每張卡一段（時間、頁碼、重點、整理版、不確定的詞）；沒整理到的寫一行
    static func tidyFile(_ cards: [LiveCard]) -> String {
        cards.map { card -> String in
            var head = range(card)
            if let page = card.page { head += "　p.\(page)" }
            guard card.state == .done else { return head + "\n（沒整理到）" }
            var lines = [head]
            if !card.key.isEmpty { lines.append("重點：" + card.key) }
            if !card.tidy.isEmpty { lines.append(card.tidy) }
            if !card.unsure.isEmpty { lines.append("不確定：" + card.unsure.joined(separator: "、")) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n"
    }

    /// 停止後的逐字稿：各卡（依時間）的擴寫接起來，一張卡一段；沒整理到的用原稿；還沒進卡的原稿（tail）接在最後
    static func transcript(_ cards: [LiveCard], tail: String = "") -> String {
        let parts = cards.sorted { $0.start < $1.start }.map { $0.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines) }
            + [tail.trimmingCharacters(in: .whitespacesAndNewlines)]
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// 狀態列頁碼：時間最晚、有頁碼的那張卡
    static func latestPage(_ cards: [LiveCard]) -> Int? {
        cards.filter { $0.page != nil }.max { $0.start < $1.start }?.page
    }
}
