import Foundation

// v0.27.0 Sources/SceneCards.swift：場景設定、點一下改字（改動的套法、送 Haiku 的參考）、一句一行與原字、
// Pencil 圈到哪幾行、左右欄寬度、圈起來重查（請求、回應、來源、只改圈到的行）、討論會停止後依講者分段。
// 句子全是自己編的合成句；期望值是照演算法手算的。main.swift 只呼叫 sceneTests(check)。

func sceneTests(_ check: @escaping (String, String, String) -> Void) {
    // ---- 場景
    check("\(RecordScene.lecture.liveMode)\(RecordScene.discussion.liveMode)\(RecordScene.chat.liveMode)", "110", "場景：上課、討論會是卡片模式，聊天不是")
    check("\(RecordScene.lecture.usesHaiku)|\(RecordScene.discussion.usesHaiku)|\(RecordScene.chat.usesHaiku)", "true|true|false", "場景：聊天不送 Haiku")
    check("\(RecordScene.lecture.allowsNoCourse)|\(RecordScene.discussion.allowsNoCourse)", "false|true", "場景：只有討論會沒課名也送")
    check("\(RecordScene.discussion.confirmsBeforeStart)|\(RecordScene.lecture.confirmsBeforeStart)|\(RecordScene.chat.confirmsBeforeStart)", "true|false|false", "場景：討論會開始前提醒")
    check("\(RecordScene.lecture.allowsRecheck)|\(RecordScene.chat.allowsRecheck)", "true|false", "場景：聊天不能圈起來重查")
    check("\(RecordScene.discussion.speakers(stored: nil))|\(RecordScene.discussion.speakers(stored: 0))|\(RecordScene.discussion.speakers(stored: 4))", "-1|-1|4", "場景人數：討論會預設自動，記成 0 也當自動")
    check("\(RecordScene.chat.speakers(stored: nil))|\(RecordScene.chat.speakers(stored: 3))|\(RecordScene.lecture.speakers(stored: 5))", "2|3|0", "場景人數：聊天預設 2 人、上課一律不分人")
    check(RecordScene(rawValue: "discussion")?.title ?? "nil", "討論會", "場景：存的字讀得回來")

    // ---- 改的那段（共同頭尾去掉）
    func frag(_ a: String, _ b: String) -> String {
        let f = CardEdits.fragment(a, b)
        return "\(f.prefix)|\(f.old)|\(f.new)|\(f.suffix)"
    }
    check(frag("這叫做練習法則", "這叫做連鎖法則"), "這叫做|練習|連鎖|法則", "改的那段：換字")
    check(frag("一樣", "一樣"), "一樣|||", "改的那段：沒改")
    check(frag("今天講法則", "今天講連鎖法則"), "今天講||連鎖|法則", "改的那段：純加字")
    check(frag("那那個我們", "那個我們"), "那|那||個我們", "改的那段：純刪字")
    check(frag("aaa", "aa"), "aa|a||", "改的那段：重複字頭尾不重疊")

    // ---- 套用改動
    func edit(_ line: Int, _ before: String, _ after: String, _ by: String = CardEdit.user) -> CardEdit {
        CardEdit(line: line, before: before, after: after, by: by)
    }
    func show(_ r: (lines: [String], before: [Int: String])) -> String {
        r.lines.joined(separator: "/") + " #" + r.before.keys.sorted().map { "\($0):\(r.before[$0] ?? "")" }.joined(separator: ",")
    }
    check(show(CardEdits.apply(lines: ["甲句。", "乙句練習。"], edits: [edit(1, "乙句練習。", "乙句連鎖。")])),
          "甲句。/乙句連鎖。 #1:乙句練習。", "改動：同一行字一樣就換")
    check(show(CardEdits.apply(lines: ["新的一句。", "甲句。", "乙句練習。"], edits: [edit(1, "乙句練習。", "乙句連鎖。")])),
          "新的一句。/甲句。/乙句連鎖。 #2:乙句練習。", "改動：行號移了，找字一樣的那行")
    check(show(CardEdits.apply(lines: ["乙句，練習法則。"], edits: [edit(0, "乙句練習法則", "乙句連鎖法則")])),
          "乙句，連鎖法則。 #0:乙句，練習法則。", "改動：整理好後字變了（加了標點），改的那段照樣套")
    check(show(CardEdits.apply(lines: ["完全不同。"], edits: [edit(0, "原本的字", "改過的字")])),
          "完全不同。 #", "改動：找不到就跳過")
    check(show(CardEdits.apply(lines: ["甲乙丙。"], edits: [edit(0, "甲乙丙。", "甲丁丙。"), edit(0, "甲丁丙。", "甲丁戊。")])),
          "甲丁戊。 #0:甲乙丙。", "改動：同一行改兩次，綠字從第一次之前算")

    // ---- 送 Haiku 的參考
    let edits = [edit(0, "這叫做練習法則。", "這叫做連鎖法則。"), edit(1, "網路查的字", "網路改的字", CardEdit.web),
                 edit(2, "再講一次練習法則。", "再講一次連鎖法則。"), edit(3, "今天講法則", "今天講連鎖法則")]
    check(CardEdits.promptPairs(edits).joined(separator: "、"), "練習→連鎖、天講法則→天講連鎖法則", "參考：只收使用者改的、去重複、純加字帶前後字")
    check(CardEdits.promptBlock([]), "", "參考：沒改過＝空字串")
    let block = CardEdits.promptBlock(edits)
    let blockWant: String = ["\n\n", CardEdits.pairsHead, "\n練習→連鎖\n天講法則→天講連鎖法則"].joined()
    check(block, blockWant, "參考：一段字接在訊息最後（沒有說明就沒有說明段）")
    let pairsHead: String = CardEdits.pairsHead
    let pairsHeadOK: Bool = pairsHead.contains("一模一樣") && pairsHead.contains("發音相近") && pairsHead.contains("不代表這堂課的主題")
    check(pairsHeadOK ? "對" : pairsHead, "對", "參考：改字只套一模一樣的原字、發音像的不套、不代表主題")

    // ---- v0.28.0 跟 AI 說（note）：不進逐字稿，只附在之後的批次
    func noted(_ line: Int, _ before: String, _ after: String, _ note: String?, _ by: String = CardEdit.user) -> CardEdit {
        CardEdit(line: line, before: before, after: after, by: by, note: note)
    }
    let onlyNote = [noted(0, "今天講幾何。", "今天講幾何。", "這堂是解析幾何，不是代數")]
    check("\(CardEdits.promptPairs(onlyNote).count)", "0", "說明：只寫說明沒改字＝沒有改字對照")
    let onlyNoteWant: String = ["\n\n", CardEdits.notesHead, "\n這堂是解析幾何，不是代數（寫在這一行：今天講幾何。）"].joined()
    check(CardEdits.promptBlock(onlyNote), onlyNoteWant, "說明：只寫說明也送，帶那一行的字")
    let mixed = [noted(0, "這叫做練習法則。", "這叫做連鎖法則。", "查一下連鎖法則\n的定義"), noted(1, "甲句。", "甲句。", "  "),
                 noted(2, "乙句。", "乙句。", "查一下連鎖法則 的定義"), noted(3, "網路查的字", "網路改的字", "網路的說明", CardEdit.web)]
    let mixedWant: String = ["\n\n", CardEdits.pairsHead, "\n練習→連鎖\n\n", CardEdits.notesHead, "\n查一下連鎖法則 的定義（寫在這一行：乙句。）"].joined()
    check(CardEdits.promptBlock(mixed), mixedWant, "說明：改字段在前、說明段在後；換行變空白、空白說明不算、重複只留一筆、重查的不算")
    let longLine = String(repeating: "丙", count: 30)
    let longNotes: [String] = CardEdits.promptNotes([noted(0, longLine, longLine, String(repeating: "丁", count: 120))])
    let longGot: String = longNotes.first ?? "沒有"
    let longWant: String = [String(repeating: "丁", count: 100), "（寫在這一行：", String(repeating: "丙", count: 20), "）"].joined()
    check(longGot, longWant, "說明：最多 100 字、行只帶前 20 字")
    let oldEdit = #"{"line":2,"before":"甲句。","after":"乙句。","by":"user"}"#
    let decodedEdit: CardEdit? = try? JSONDecoder().decode(CardEdit.self, from: Data(oldEdit.utf8))
    var decodedEditText = "讀不進來"
    if let e = decodedEdit {
        let noteText: String = e.note ?? "nil"
        decodedEditText = "\(e.line)|\(e.after)|" + noteText
    }
    check(decodedEditText, "2|乙句。|nil", "舊卡片.json：沒有 note 欄照樣讀得進來")
    var stored = LiveCard(id: 7, start: 0, end: 1, raw: "甲句。")
    stored.edits = [noted(0, "甲句。", "甲句。", "這段是自我介紹")]
    let storedData = try? JSONEncoder().encode(stored)
    let reread = storedData.flatMap { try? JSONDecoder().decode(LiveCard.self, from: $0) }
    check(reread == stored ? "一樣" : "不一樣", "一樣", "卡片.json：說明存得進去也讀得回來")
    let message = CardPrompt.userMessage(context: "", raw: "這段原稿", reference: "", referenceName: "Apple", userEdits: block)
    check(message.hasSuffix(block) && message.contains("這段原稿") ? "對" : message, "對", "卡片訊息：使用者改過的接在最後")
    check(CardPrompt.userMessage(context: "", raw: "這段", reference: "", referenceName: "Apple")
          == CardPrompt.userMessage(context: "", raw: "這段", reference: "", referenceName: "Apple", userEdits: "") ? "一樣" : "不一樣",
          "一樣", "卡片訊息：沒有改過時和以前一樣")

    // ---- 一句一行、原字、原稿字數
    let raw = "好那我們今天上課要講練習法則那麼他的意思是"
    let expanded = "好，那我們今天上課要講連鎖法則。那麼它的意思是？"
    var card = LiveCard(id: 3, start: 10, end: 24, raw: raw)
    card.state = .done
    card.expanded = expanded
    let diff = CardDiff.pieces(raw: raw, expanded: expanded)
    let lines = CardLines.build(card, diff: diff)
    check(lines.map(\.text).joined(separator: "/"), "好，那我們今天上課要講連鎖法則。/那麼它的意思是？", "卡片的行：擴寫一句一行")
    check(lines.map(\.original).joined(separator: "/"), "好，那我們今天上課要講練習法則。/那麼他的意思是？", "卡片的行：原本聽到的字")
    check(lines.map { "\($0.rawFrom)-\($0.rawTo)" }.joined(separator: ","), "0-14,14-21", "卡片的行：每行吃原稿幾個字")
    check(CardLines.split(diff).map { CardDiff.describe($0) }.joined(separator: "/"), "好，那我們今天上課要講[連鎖|練習]法則。/那麼[它|他]的意思是？", "卡片的行：片段照換行切")
    var edited = card
    edited.edits = [edit(1, "那麼它的意思是？", "那麼它的意義是？")]
    let editedLines = CardLines.build(edited, diff: diff)
    check(editedLines.map(\.text).joined(separator: "/") + "|" + (editedLines[1].editedFrom ?? "nil") + "|" + (editedLines[0].editedFrom ?? "nil"),
          "好，那我們今天上課要講連鎖法則。/那麼它的意義是？|那麼它的意思是？|nil", "卡片的行：使用者改的行")
    check(edited.transcriptText, "好，那我們今天上課要講連鎖法則。那麼它的意義是？", "逐字稿：用改過的字")
    check(CardText.share(edited).contains("那麼它的意義是？") ? "有" : "沒有", "有", "分享：用改過的字")
    check(CardText.transcript([edited]), "好，那我們今天上課要講連鎖法則。那麼它的意義是？", "停止後逐字稿：用改過的字")
    var memo = card
    memo.edits = [noted(1, "那麼它的意思是？", "那麼它的意思是？", "這裡的意思是定義")]
    let memoLines = CardLines.build(memo, diff: diff)
    check(memoLines.map(\.text).joined(separator: "/") + "|" + (memoLines[1].editedFrom ?? "nil"),
          "好，那我們今天上課要講連鎖法則。/那麼它的意思是？|nil", "說明：只寫說明的行字不變、不算改過")
    check(memo.transcriptText, "好，那我們今天上課要講連鎖法則。那麼它的意思是？", "說明：只寫說明不動逐字稿")
    var both = card
    both.edits = [noted(1, "那麼它的意思是？", "那麼它的意義是？", "說明不要進稿")]
    check(both.transcriptText, "好，那我們今天上課要講連鎖法則。那麼它的意義是？", "說明：改字照樣進逐字稿")
    let exported = CardText.transcript([both]) + CardText.share(both) + CardText.tidyFile([both])
    check(exported.contains("說明不要進稿") ? "有" : "沒有", "沒有", "說明：不進逐字稿、分享、整理版")

    // ---- v0.28.0 重點是固定字樣（聽不清、現場口令）
    let keySamples: [String] = ["（這段聽不清）", " （現場口令） ", "連鎖法則", "（", "（）", "連鎖法則（複習）"]
    let keyShades: [String] = keySamples.map { (key: String) -> String in CardText.isPlaceholderKey(key) ? "淡" : "一般" }
    check(keyShades.joined(separator: "/"), "淡/淡/一般/一般/一般/一般", "重點：整句包在全形括號裡才淡化")
    let cardWords: [String] = ["講者", "不要一律寫「老師」", "（現場口令）", "（這段聽不清）", "以課名為準", "原樣保留原字", "不要刪"]
    let cardMissing: [String] = cardWords.filter { (word: String) -> Bool in !CardPrompt.system.contains(word) }
    check(cardMissing.joined(separator: "、"), "", "卡片提示詞：講者不一律寫老師、口令不編重點、主題照課名、沒證據不改字不刪詞")
    var failed = LiveCard(id: 4, start: 0, end: 5, raw: "第一句。第二句")
    failed.state = .failed
    check(CardLines.build(failed, diff: nil).map { $0.text + "=" + $0.original }.joined(separator: "/"), "第一句。=第一句。/第二句=第二句", "卡片的行：沒整理到用原稿")
    check("\(CardLines.build(LiveCard(id: 5, start: 0, end: 1, raw: ""), diff: nil).count)", "0", "卡片的行：沒有字＝沒有行")

    // ---- Pencil 圈到哪幾行
    let boxes = [LineBox(index: 0, top: 0, bottom: 20), LineBox(index: 1, top: 22, bottom: 42), LineBox(index: 2, top: 44, bottom: 64)]
    func hit(_ top: Double, _ bottom: Double) -> String {
        CardLines.hit(boxes, top: top, bottom: bottom).map(String.init).joined(separator: ",")
    }
    check(hit(18, 50), "1", "圈行：重疊超過半行高才算")
    check(hit(-5, 70), "0,1,2", "圈行：整段圈起來")
    check(hit(40, 43), "1", "圈行：畫底線（比一行扁）碰到就算")
    check(hit(43, 40), "1", "圈行：上下顛倒也一樣")
    check(hit(100, 110), "2", "圈行：都沒碰到取最近的一行")
    check(CardLines.hit([], top: 0, bottom: 10).isEmpty ? "空" : "有", "空", "圈行：沒有行")

    // ---- 左右欄寬度
    check(String(format: "%.0f|%.0f|%.0f|%.0f|%.0f", CardSplit.right(total: 1000, ratio: 0), CardSplit.right(total: 1000, ratio: 0.5),
                 CardSplit.right(total: 1000, ratio: 0.9), CardSplit.right(total: 1000, ratio: 0.1), CardSplit.right(total: 500, ratio: 0.5)),
          "300|500|680|220|220", "左右欄：預設 300、拉的比例、兩邊夾最小寬度")
    check(String(format: "%.2f|%.2f", CardSplit.ratio(right: 400, total: 1000), CardSplit.ratio(right: 50, total: 1000)), "0.40|0.22", "左右欄：記的比例（先夾）")

    // ---- 重查：回覆最後的 JSON
    func reply(_ text: String) -> String {
        guard let r = RecheckReply.parse(text) else { return "讀不出" }
        return "\(r.conclusion)|\(r.why)|\(r.fixes.map { $0.old + ">" + $0.new }.joined(separator: ","))|\(r.unsure)"
    }
    let normal = #"{"conclusion": "改成連鎖法則", "why": "教科書都叫連鎖法則", "fixes": [{"old": "練習法則", "new": "連鎖法則"}], "unsure": ""}"#
    check(reply("查了一下，應該是連鎖法則。\n```json\n" + normal + "\n```"), "改成連鎖法則|教科書都叫連鎖法則|練習法則>連鎖法則|", "重查回覆：前面有說明字、包 ```json")
    check(reply(#"先看 {"a": 1}，結論："# + normal), "改成連鎖法則|教科書都叫連鎖法則|練習法則>連鎖法則|", "重查回覆：前面有別的 JSON，取最後有 conclusion 的")
    check(reply(#"{"conclusion": "用 {x} 表示", "why": "引號裡有 \"括號\" }", "fixes": [], "unsure": ["甲", "乙"]}"#), #"用 {x} 表示|引號裡有 "括號" }||甲；乙"#, "重查回覆：字串裡的括號、跳脫引號不算；unsure 是清單")
    check(reply(#"{"conclusion": "不用改", "fixes": [{"old": "", "new": "空的"}, {"old": "甲", "new": "乙"}]}"#), "不用改||甲>乙|", "重查回覆：old 空的不算、缺欄位用空字串")
    check(reply("我查不到"), "讀不出", "重查回覆：沒有 JSON")
    check(reply(#"{"conclusion": "壞掉"#), "讀不出", "重查回覆：JSON 沒收尾")

    // ---- 重查：只改圈到的行
    let rows = ["今天講練習法則。", "練習很重要。", "第三行練習。"]
    let r1 = RecheckReply(conclusion: "", why: "", fixes: [RecheckFix(old: "練習法則", new: "連鎖法則"), RecheckFix(old: "第三行", new: "第三列"),
                                                           RecheckFix(old: "很重要", new: "很要緊"), RecheckFix(old: "甲", new: "甲")],
                          unsure: "很重要那句不確定")
    let applied = RecheckPrompt.apply(lines: rows, selected: [1, 0, 0], reply: r1)
    check(applied.lines.joined(separator: "/"), "今天講連鎖法則。/練習很重要。/第三行練習。", "重查套用：只改圈到的行、沒把握講到的不改")
    check(applied.maybe.map { $0.old + ">" + $0.new }.joined(separator: ","), "很重要>很要緊", "重查套用：v0.28.0 沒把握講到的改法不丟掉，變成可以按套用的猜測")
    check(applied.applied.map { $0.old + ">" + $0.new }.joined(separator: ","), "練習法則>連鎖法則", "重查套用：真的套上的")
    check(applied.edits.map { "\($0.line):\($0.before)>\($0.after):\($0.by)" }.joined(separator: ","), "0:今天講練習法則。>今天講連鎖法則。:web", "重查套用：記成 web 改動")
    let r2 = RecheckReply(conclusion: "", why: "", fixes: [RecheckFix(old: "練習", new: "連鎖")], unsure: "")
    check(RecheckPrompt.apply(lines: rows, selected: [1, 2], reply: r2).lines.joined(separator: "/"), "今天講練習法則。/連鎖很重要。/第三行練習。", "重查套用：同一個字只換圈到的第一行第一處")
    check(RecheckPrompt.apply(lines: rows, selected: [7], reply: r2).applied.count == 0 ? "沒改" : "改了", "沒改", "重查套用：行號超出不改")

    // ---- 重查：請求
    if let body = try? RecheckPrompt.body(userMessage: "圈起來的字", assistant: nil),
       let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
       let tools = object["tools"] as? [[String: Any]], let tool = tools.first,
       let messages = object["messages"] as? [[String: Any]] {
        let location = tool["user_location"] as? [String: Any] ?? [:]
        check("\(object["model"] ?? "")|\(tool["type"] ?? "")|\(tool["name"] ?? "")|\(tool["max_uses"] ?? "")|\(location["country"] ?? "")|\(location["timezone"] ?? "")|\(messages.count)",
              "claude-haiku-5-5|web_search_20250305|web_search|3|TW|Asia/Taipei|1", "重查請求：Haiku 5.5＋網路搜尋（最多 3 次、台灣）")
        let config = object["output_config"] as? [String: Any] ?? [:]
        check(config["format"] == nil ? "沒有" : "有", "沒有", "重查請求：不用結構化輸出（和引用不能一起用）")
    } else {
        check("編不出來", "編得出來", "重查請求：編得出來")
    }
    let paused: [Any] = [["type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": ["query": "連鎖法則"]]]
    if let body = try? RecheckPrompt.body(userMessage: "圈起來的字", assistant: paused),
       let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
       let messages = object["messages"] as? [[String: Any]], messages.count == 2,
       let content = messages[1]["content"] as? [[String: Any]] {
        check("\(messages[1]["role"] ?? "")|\(content.first?["id"] ?? "")", "assistant|srvtoolu_1", "重查請求：pause_turn 時上一段原封不動當 assistant")
    } else {
        check("不對", "對", "重查請求：pause_turn 接著送")
    }
    let msg = RecheckPrompt.userMessage(course: "", key: "", lines: ["甲句", "乙句"])
    check(msg.contains("討論會") && msg.hasSuffix("甲句\n乙句") ? "對" : msg, "對", "重查訊息：沒課名寫討論會、只放圈到的行")

    // ---- 重查：回應、來源、花費
    let responseJSON = #"""
    {"content": [
      {"type": "thinking", "thinking": "", "signature": "x"},
      {"type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": {"query": "連鎖法則"}},
      {"type": "web_search_tool_result", "tool_use_id": "srvtoolu_1", "content": [
        {"type": "web_search_result", "url": "https://example.com/a", "title": "甲網頁", "encrypted_content": "e1"},
        {"type": "web_search_result", "url": "https://example.com/b", "title": "", "encrypted_content": "e2"},
        {"type": "web_search_result", "url": "ftp://example.com/c", "title": "丙", "encrypted_content": "e3"}
      ]},
      {"type": "text", "text": "查到了。"},
      {"type": "text", "text": "教科書寫連鎖法則", "citations": [
        {"type": "web_search_result_location", "url": "https://example.com/b", "title": "乙網頁", "cited_text": "…", "encrypted_index": "i"},
        {"type": "web_search_result_location", "url": "https://example.com/b", "title": "乙網頁", "cited_text": "…", "encrypted_index": "j"}
      ]},
      {"type": "text", "text": "。\n{\"conclusion\": \"改成連鎖法則\", \"why\": \"教科書\", \"fixes\": [], \"unsure\": \"\"}"}
    ],
    "stop_reason": "end_turn",
    "usage": {"input_tokens": 1000, "output_tokens": 200, "server_tool_use": {"web_search_requests": 2}}}
    """#
    if let parsed = RecheckPrompt.parse(Data(responseJSON.utf8)) {
        let text = RecheckPrompt.text(parsed.content)
        check("\(parsed.stopReason ?? "nil")|\(parsed.searches)|\(parsed.usage?.input_tokens ?? -1)|\(parsed.content.count)", "end_turn|2|1000|6", "重查回應：停止原因、搜尋次數、用量、區塊原樣留著")
        check(text.hasPrefix("查到了。教科書寫連鎖法則。") ? "接起來" : text, "接起來", "重查回應：文字區塊接起來")
        check(RecheckReply.parse(text)?.conclusion ?? "讀不出", "改成連鎖法則", "重查回應：被引用切開的文字照樣讀到 JSON")
        check(RecheckPrompt.sources(parsed.content, keep: nil).map { $0.title + "=" + $0.url }.joined(separator: ","), "乙網頁=https://example.com/b", "重查來源：舊格式用引用、去重複")
        let uncited = parsed.content.filter { (($0 as? [String: Any])?["citations"]) == nil }
        check(RecheckPrompt.sources(uncited, keep: nil).map { $0.title + "=" + $0.url }.joined(separator: ","),
              "", "重查來源：v0.28.0 沒有引用、也沒有 sources 欄就不列（不再列全部搜尋結果）")
        check(RecheckPrompt.sources(parsed.content, keep: ["https://EXAMPLE.com/a/"]).map { $0.title + "=" + $0.url }.joined(separator: ","),
              "甲網頁=https://example.com/a", "重查來源：只留 sources 欄說的網址（大小寫、結尾斜線不管）")
        check(RecheckPrompt.sources(parsed.content, keep: ["https://example.com/b"]).map { $0.title + "=" + $0.url }.joined(separator: ","),
              "乙網頁=https://example.com/b", "重查來源：引用和搜尋結果同一個網址只列一次（用引用的標題）")
        check("\(RecheckPrompt.sources(parsed.content, keep: []).count)|\(RecheckPrompt.sources(parsed.content, keep: ["https://example.com/made-up"]).count)",
              "0|0", "重查來源：sources 空的＝不列；沒搜到的網址不列")
        check(String(format: "%.4f", RecheckPrompt.cost(usage: parsed.usage, searches: parsed.searches)), "0.0202", "重查花費：token＋每次搜尋 0.01 美元")
        check(RecheckPrompt.searchError(parsed.content) ?? "沒有", "沒有", "重查回應：搜尋沒出錯")
    } else {
        check("解析不了", "解析得了", "重查回應：解析")
    }
    let errorJSON = #"{"content": [{"type": "web_search_tool_result", "tool_use_id": "s", "content": {"type": "web_search_tool_result_error", "error_code": "max_uses_exceeded"}}], "stop_reason": "pause_turn", "usage": {"input_tokens": 10, "output_tokens": 1}}"#
    if let parsed = RecheckPrompt.parse(Data(errorJSON.utf8)) {
        check("\(parsed.stopReason ?? "nil")|\(parsed.searches)|\(RecheckPrompt.searchError(parsed.content) ?? "沒有")|\(RecheckPrompt.sources(parsed.content, keep: nil).count)",
              "pause_turn|0|max_uses_exceeded|0", "重查回應：搜尋出錯是物件、沒有 server_tool_use 算 0 次")
    } else {
        check("解析不了", "解析得了", "重查回應：出錯也解析得了")
    }
    check(RecheckPrompt.parse(Data("不是 JSON".utf8)) == nil ? "nil" : "有", "nil", "重查回應：不是 JSON")

    // ---- 討論會停止後分人
    let units = [TimedPiece(text: "好那我們今天上課要講練習法則", start: 10, end: 17), TimedPiece(text: "那麼他的意思是", start: 17, end: 24)]
    let timed = CardSpeakers.times(lines: lines, units: units, start: 10, end: 24)
    check(timed.map { String(format: "%.0f-%.0f", $0.start, $0.end) }.joined(separator: ","), "10-17,17-24", "分人：行的時間照單位的字數換算")
    let even = CardSpeakers.times(lines: lines, units: [], start: 0, end: 21)
    check(even.map { String(format: "%.0f-%.0f", $0.start, $0.end) }.joined(separator: ","), "0-14,14-21", "分人：沒有單位就平均分")
    func sl(_ text: String, _ start: Double, _ end: Double) -> SpeakerLine { SpeakerLine(text: text, start: start, end: end) }
    let twoTurns = [SpeakerTurn(speaker: "S1", start: 9, end: 17.5), SpeakerTurn(speaker: "S2", start: 17.5, end: 25)]
    let labeled = CardSpeakers.label([[sl("甲。", 10, 17), sl("乙。", 17, 24)]], turns: twoTurns)
    check(labeled.text + "|" + labeled.names.joined(separator: ","), "A：甲。\n\nB：乙。|A,B", "分人：每行照時間標講者")
    let same = CardSpeakers.label([[sl("甲。", 10, 12), sl("乙。", 12, 14)], [sl("丙。", 14, 16)], [sl("丁。", 20, 22)]], turns: twoTurns)
    check(same.text, "A：甲。乙。\n\nA：丙。\n\nB：丁。", "分人：同一人連續的行接一段、換卡換段")
    let gap = CardSpeakers.label([[sl("甲。", 30, 31)]], turns: twoTurns)
    check(gap.text, "A：甲。", "分人：沒重疊用最近的那段（第一個出現的叫 A）")
    let none = CardSpeakers.label([[sl("甲。", 10, 12), sl("乙。", 12, 14)], [sl("  ", 14, 15)]], turns: [])
    check(none.text + "|" + "\(none.names.count)", "甲。乙。|0", "分人：沒有講者段落不標")

    v28Tests(check)
}

// v0.28.0：重算重點、重查的猜測（maybe）與來源、跨卡的行對應、舊 JSON 相容。例子全是編的。
private func v28Tests(_ check: @escaping (String, String, String) -> Void) {
    // 比對用的字（拆成有型別的小函式，免得一行運算式太長、編譯器推不出型別）
    func fixText(_ list: [RecheckFix]) -> String {
        let items: [String] = list.map { (fix: RecheckFix) -> String in fix.old + ">" + fix.new }
        return items.joined(separator: ",")
    }
    func refText(_ list: [CardLineRef]) -> String {
        let items: [String] = list.map { (ref: CardLineRef) -> String in "\(ref.card).\(ref.line)" }
        return items.joined(separator: ",")
    }
    func rowsText(_ rows: [Int]) -> String {
        let items: [String] = rows.map { (row: Int) -> String in String(row) }
        return items.joined(separator: "+")
    }
    func byCardText(_ byCard: [Int: [CardEdit]]) -> String {
        var parts: [String] = []
        for k in byCard.keys.sorted() {
            let list: [CardEdit] = byCard[k] ?? []
            let items: [String] = list.map { (e: CardEdit) -> String in "\(e.line)=\(e.after)" }
            parts.append("\(k):" + items.joined(separator: ","))
        }
        return parts.joined(separator: " ")
    }
    func firstEditText(_ byCard: [Int: [CardEdit]], card: Int, _ show: (CardEdit) -> String) -> String {
        let keys: [String] = byCard.keys.sorted().map { (k: Int) -> String in String(k) }
        let list: [CardEdit] = byCard[card] ?? []
        let first: String = list.first.map(show) ?? "沒有"
        return keys.joined(separator: ",") + "|" + first
    }

    // ---- 只有說明的改動不算改字；要不要重算
    let noteOnly = [CardEdit(line: 0, before: "甲句。", after: "甲句。", by: CardEdit.user, note: "這段是自我介紹")]
    let blankNote = [CardEdit(line: 0, before: "甲句。", after: "甲句。", by: CardEdit.user, note: "  ")]
    let realEdit = [CardEdit(line: 0, before: "甲句。", after: "乙句。", by: CardEdit.user)]
    check("\(CardEdits.changesText(noteOnly))|\(CardEdits.changesText(realEdit))|\(CardEdits.changesText(nil))", "false|true|false",
          "改字：只寫說明的那筆不算改過字")
    check("\(CardEdits.needsRefresh(noteOnly))|\(CardEdits.needsRefresh(blankNote))|\(CardEdits.needsRefresh(realEdit))|\(CardEdits.needsRefresh([]))",
          "true|false|true|false", "重算：改了字或寫了說明才重算，空白說明不算")

    // ---- 重算重點：回覆解析
    func refreshed(_ text: String) -> String {
        guard let r = CardRefreshReply.parse(text) else { return "讀不出" }
        return r.key + "|" + r.tidy
    }
    check(refreshed(#"{"key": "報告的人不是甲", "tidy": "講者說今天報告的不是甲。"}"#), "報告的人不是甲|講者說今天報告的不是甲。", "重算回覆：一般")
    check(refreshed("好的：\n```json\n{\"key\": \" 連鎖法則 \", \"tidy\": \"\"}\n```"), "連鎖法則|", "重算回覆：前後有字、去空白、整理版可以空")
    check(refreshed(#"{"key": "", "tidy": "有字"}"#), "讀不出", "重算回覆：重點空的不算")
    check(refreshed("沒有 JSON"), "讀不出", "重算回覆：沒有 JSON")
    let okResponse = #"{"content": [{"type": "text", "text": "{\"key\": \"解析幾何的向量\", \"tidy\": \"講者介紹向量。\"}"}], "stop_reason": "end_turn", "usage": {"input_tokens": 1200, "output_tokens": 100}}"#
    if case .reply(let r, let usage) = CardRefresh.parseResponse(Data(okResponse.utf8)) {
        let usd: Double = usage.map(Cost.usd) ?? -1
        let got: String = [r.key, r.tidy, String(format: "%.5f", usd)].joined(separator: "|")
        check(got, "解析幾何的向量|講者介紹向量。|0.00017", "重算回應：解出重點、整理版、花費")
    } else {
        check("沒解出", "解出", "重算回應：解析")
    }
    let cutResponse = #"{"content": [], "stop_reason": "max_tokens", "usage": {"input_tokens": 1, "output_tokens": 1}}"#
    if case .truncated = CardRefresh.parseResponse(Data(cutResponse.utf8)) {
        check("超長", "超長", "重算回應：超過長度上限不套")
    } else {
        check("不是超長", "超長", "重算回應：超過長度上限不套")
    }
    if case .unreadable = CardRefresh.parseResponse(Data("不是 JSON".utf8)) {
        check("讀不出", "讀不出", "重算回應：不是 JSON")
    } else {
        check("讀得出", "讀不出", "重算回應：不是 JSON")
    }

    // ---- 重算重點：訊息、提示詞、請求
    let refreshMessage = CardRefresh.userMessage(transcript: ["今天報告的人不是甲。", "是乙。"], notes: ["這堂是解析幾何"], key: "報告的人是甲", tidy: "")
    let messageWords: [String] = ["今天報告的人不是甲。\n是乙。", "這堂是解析幾何", "報告的人是甲", "原本的整理版（只參考，和逐字稿不合就改）：（沒有）"]
    let messageOK: Bool = messageWords.allSatisfy { (word: String) -> Bool in refreshMessage.contains(word) }
    check(messageOK ? "對" : refreshMessage, "對", "重算訊息：改好的逐字稿一句一行、說明、原本的重點和整理版")
    let noNotesMessage: String = CardRefresh.userMessage(transcript: ["甲。"], notes: [], key: "", tidy: "")
    check(noNotesMessage.contains("使用者的說明") ? "有" : "沒有", "沒有", "重算訊息：沒說明就沒有說明段")
    let refreshWords: [String] = ["逐字稿是準的", "不得和逐字稿矛盾", "不要一律寫「老師」", "（這段聽不清）", "（現場口令）", "15 字內", "以課名為準", "不能上網查"]
    let refreshMissing: [String] = refreshWords.filter { (word: String) -> Bool in !CardRefresh.system.contains(word) }
    check(refreshMissing.joined(separator: "、"), "", "重算提示詞：逐字稿為準、不得矛盾、其餘規則和卡片一樣")
    let courseBlocks: String = CardRefresh.courseBlock(course: "") + "/" + CardRefresh.courseBlock(course: "解析幾何")
    check(courseBlocks, "課名：（討論會，沒有課名）/課名：解析幾何", "重算課名：沒課名寫討論會")

    // ---- v0.29.0 非課程（其他場合）、使用者寫的主題
    let nonCourseRefresh: String = CardRefresh.courseBlock(course: "", nonCourse: true)
    check(nonCourseRefresh, "課名：（非課程，其他場合，沒有課名）", "非課程：重算課名寫非課程、不寫討論會")
    let nonCourseRecheck: String = RecheckPrompt.userMessage(course: "", key: "", lines: ["甲句"], nonCourse: true, topic: "社團分享會")
    let nonCourseRecheckOK: Bool = nonCourseRecheck.hasPrefix("課名：（非課程，其他場合，沒有課名）\n主題（使用者自己寫的）：社團分享會\n這段的重點：")
        && !nonCourseRecheck.contains("討論會")
    check(nonCourseRecheckOK ? "對" : nonCourseRecheck, "對", "非課程：重查訊息寫非課程、多一行主題")
    let nonCourseBlockOK: Bool = RecordScene.nonCourseBlock.contains("沒有課名") && !RecordScene.nonCourseBlock.contains("討論會")
    check(nonCourseBlockOK ? "對" : RecordScene.nonCourseBlock, "對", "非課程：課程區塊留「沒有課名」、不寫討論會")
    let topicA: String = SessionTopic.clean("  社團\n分享會 ") ?? "nil"
    let topicB: String = SessionTopic.clean(" \n ") ?? "nil"
    let topicC: String = SessionTopic.clean(nil) ?? "nil"
    let topicD: Int = SessionTopic.clean(String(repeating: "甲", count: 50))?.count ?? 0
    check([topicA, topicB, topicC, String(topicD)].joined(separator: "|"), "社團 分享會|nil|nil|40", "主題：換行變空白、空的算沒寫、最多 40 字")
    let topicBlock: String = SessionTopic.promptBlock("社團分享會")
    check(topicBlock.hasPrefix("\n\n使用者說這場的主題：社團分享會") ? "對" : topicBlock, "對", "主題：卡片訊息多一段")
    check(SessionTopic.promptBlock("  "), "", "主題：沒寫就不放")
    let topicCardMessage: String = CardPrompt.userMessage(context: "", raw: "這段", reference: "", referenceName: "Apple",
                                                          userEdits: SessionTopic.promptBlock("社團分享會"))
    check(topicCardMessage.hasSuffix("不要把這幾個字抄進 expanded）") ? "對" : topicCardMessage, "對", "主題：接在卡片使用者訊息最後（不進課程區塊）")
    let topicRefresh: String = CardRefresh.userMessage(transcript: ["甲。"], notes: [], key: "", tidy: "", topic: "社團分享會")
    check(topicRefresh.hasPrefix("這場的主題（使用者自己寫的）：社團分享會\n\n這張卡修正後的逐字稿") ? "對" : topicRefresh, "對", "主題：重算訊息放最前面")
    let topicPromptWords: [String] = ["使用者說這場的主題", "主題以它為準", "使用者說的主題，或上下文"]
    let topicPromptMissing: [String] = topicPromptWords.filter { (word: String) -> Bool in !CardPrompt.system.contains(word) }
    check(topicPromptMissing.joined(separator: "、"), "", "主題：卡片提示詞講明非課程以主題為準、主題算改字的證據")

    // ---- v0.29.0 錄音中複製（卡片模式）：到目前為止的全文（比對片段手寫，期望值確定）
    var copyDone = LiveCard(id: 1, start: 0, end: 60, raw: "今天講像量那個我們開始。")
    copyDone.state = .done
    copyDone.expanded = "今天講向量。我們開始。"
    copyDone.page = 2
    let copyDiff: [CardDiff.Piece] = [
        CardDiff.Piece(kind: .same, text: "今天講", old: "", group: -1),
        CardDiff.Piece(kind: .changed, text: "向", old: "像", group: 0),
        CardDiff.Piece(kind: .same, text: "量。\n", old: "", group: -1),
        CardDiff.Piece(kind: .deleted, text: "", old: "那個", group: 1),
        CardDiff.Piece(kind: .same, text: "我們開始。", old: "", group: -1),
    ]
    let copyDoneBlock: String = CardCopy.block(copyDone, diff: copyDiff)
    check(copyDoneBlock, "[00:00–01:00　p.2]\n今天講向［像］量。\n［刪：那個］我們開始。", "錄音中複製：改字［原字］、刪掉的寫［刪：原字］、時間和頁碼一行")
    var copyEdited = LiveCard(id: 2, start: 60, end: 120, raw: "甲具。乙句。")
    copyEdited.state = .done
    copyEdited.expanded = "甲句。乙句。"
    copyEdited.edits = [CardEdit(line: 0, before: "甲句。", after: "甲狗。", by: CardEdit.user)]
    let editedDiff: [CardDiff.Piece] = [
        CardDiff.Piece(kind: .same, text: "甲", old: "", group: -1),
        CardDiff.Piece(kind: .changed, text: "句", old: "具", group: 0),
        CardDiff.Piece(kind: .same, text: "。\n乙句。", old: "", group: -1),
    ]
    let copyEditedBlock: String = CardCopy.block(copyEdited, diff: editedDiff)
    check(copyEditedBlock, "[01:00–02:00]\n甲狗。\n乙句。", "錄音中複製：使用者改過的行照改好的字、不標原字")
    let copyWaiting = LiveCard(id: 3, start: 120, end: 180, raw: "還在等的字。")
    var copyFailed = LiveCard(id: 4, start: 180, end: 240, raw: "")
    copyFailed.state = .failed
    let copyDiffs: [Int: [CardDiff.Piece]] = [1: copyDiff, 2: editedDiff]
    let copyAll: String = CardCopy.live([copyWaiting, copyEdited, copyFailed, copyDone], diffs: copyDiffs, tail: "  最後幾句 ")
    let copyWantParts: [String] = [copyDoneBlock, copyEditedBlock, "[02:00–03:00　還沒整理，Whisper 原字]\n還在等的字。", "[還沒進卡的字，Whisper 原字]\n最後幾句"]
    let copyWant: String = copyWantParts.joined(separator: "\n\n")
    check(copyAll, copyWant, "錄音中複製：依時間排、還沒整理的用 Whisper 原字、沒字的卡不放、最後接還沒進卡的字")
    let copyEmpty: String = CardCopy.live([], diffs: [:], tail: " \n ")
    check(copyEmpty, "", "錄音中複製：都沒有字＝空的")
    if let body = try? CardRefresh.requestBody(courseBlock: "課名：解析幾何", userMessage: "稿"),
       let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
        let config: [String: Any] = object["output_config"] as? [String: Any] ?? [:]
        let format: [String: Any] = config["format"] as? [String: Any] ?? [:]
        let model: String = (object["model"] as? String) ?? ""
        let maxTokens: String = (object["max_tokens"] as? Int).map { (n: Int) -> String in String(n) } ?? ""
        let noTools: Bool = object["tools"] == nil
        let formatType: String = (format["type"] as? String) ?? ""
        check([model, maxTokens, String(noTools), formatType].joined(separator: "|"),
              "claude-haiku-5-5|1500|true|json_schema", "重算請求：Haiku、不帶網路搜尋、結構化輸出")
    } else {
        check("編不出來", "編得出來", "重算請求：編得出來")
    }

    // ---- 重查：maybe、sources 的解析
    let guessReply = RecheckReply.parse(#"{"conclusion": "很可能是乙博士", "why": "查到同名的人", "fixes": [], "maybe": [{"old": "甲伯士", "new": "乙博士"}, {"old": "", "new": "空"}], "unsure": "不確定是不是同一人", "sources": ["https://example.com/a", {"url": "https://example.com/b"}, 3]}"#)
    var guessText = "讀不出"
    if let g = guessReply {
        let sourceList: [String] = g.sources ?? ["nil"]
        guessText = fixText(g.maybe) + "|" + sourceList.joined(separator: ",")
    }
    check(guessText, "甲伯士>乙博士|https://example.com/a,https://example.com/b", "重查回覆：maybe（old 空的不算）、sources（字串或 url 物件）")
    let oldStyle = RecheckReply.parse(#"{"conclusion": "改成連鎖法則", "why": "", "fixes": [{"old": "練習法則", "new": "連鎖法則"}], "unsure": ""}"#)
    var oldStyleText = "讀不出"
    if let o = oldStyle {
        let sourceMark: String = o.sources == nil ? "nil" : "有"
        oldStyleText = "\(o.maybe.count)|" + sourceMark
    }
    check(oldStyleText, "0|nil", "重查回覆：舊格式沒有 maybe、sources 照讀")
    let placeholderMessage: String = RecheckPrompt.userMessage(course: "解析幾何", key: "（這段聽不清）", lines: ["甲"])
    check(placeholderMessage.contains("這段的重點：（還沒有）") ? "對" : "不對", "對", "重查訊息：固定字樣的重點當沒有重點")
    let recheckWords: [String] = ["一定要放進 fixes", "放進 maybe", "只放真的支持結論的網址"]
    let recheckMissing: [String] = recheckWords.filter { (word: String) -> Bool in !RecheckPrompt.system.contains(word) }
    check(recheckMissing.joined(separator: "、"), "", "重查提示詞：該改的一定放 fixes、猜測放 maybe、來源只列支持結論的")

    // ---- 重查：猜測（maybe）的整理
    let guessRows = ["今天請到甲伯士來演講。", "他以前是院長。", "沒圈的丙字。"]
    let guessFixes = RecheckReply(conclusion: "", why: "", fixes: [RecheckFix(old: "院長", new: "前院長")], unsure: "院長的年份查不到",
                                  maybe: [RecheckFix(old: "甲伯士", new: "乙博士"), RecheckFix(old: "丙字", new: "丁字"), RecheckFix(old: "甲伯士", new: "乙博士")])
    let guessed = RecheckPrompt.apply(lines: guessRows, selected: [0, 1], reply: guessFixes)
    let guessedText: String = [guessed.lines.joined(separator: "/"), fixText(guessed.maybe), fixText(guessed.lost)].joined(separator: "#")
    check(guessedText, "今天請到甲伯士來演講。/他以前是院長。/沒圈的丙字。#院長>前院長,甲伯士>乙博士#丙字>丁字",
          "重查套用：沒把握講到的改法變猜測、猜測只留圈到的行找得到的、去重複")
    let both = RecheckPrompt.apply(lines: guessRows, selected: [0], reply: RecheckReply(conclusion: "", why: "", fixes: [RecheckFix(old: "甲伯士", new: "乙博士")],
                                                                                       unsure: "", maybe: [RecheckFix(old: "甲伯士", new: "丙博士")]))
    check("\(both.applied.count)|\(both.maybe.count)|\(both.lost.count)", "1|0|0", "重查套用：已經套上的同一處不再列猜測")

    // ---- 跨卡：行接起來、改動對回各卡
    let parts = [RecheckPart(cardID: 3, lines: ["甲卡一。", "甲卡二講到乙博", "甲卡三。"], selected: [2, 1, 1]),
                 RecheckPart(cardID: 4, lines: ["士的事。", "乙卡二。"], selected: [0, 5])]
    let joined = RecheckPrompt.combine(parts)
    let joinedText: String = "\(joined.selected)|" + refText(joined.owner)
    check(joinedText, "[1, 2, 3]|3.0,3.1,3.2,4.0,4.1", "跨卡：行照卡的順序接起來、圈到的行換成接起來的行號（重複、超出的不算）")
    let joinedEdits = [CardEdit(line: 3, before: "士的事。", after: "士的事情。", by: CardEdit.web),
                       CardEdit(line: 1, before: "甲卡二講到乙博", after: "甲卡二講到丙博", by: CardEdit.web),
                       CardEdit(line: 9, before: "多的", after: "多的字", by: CardEdit.web)]
    let split = RecheckPrompt.split(joinedEdits, owner: joined.owner)
    check(byCardText(split), "3:1=甲卡二講到丙博 4:0=士的事情。", "跨卡：改動的行號對回各卡自己的行號、對不到的丟掉")
    let crossReply = RecheckReply(conclusion: "", why: "", fixes: [RecheckFix(old: "乙卡二", new: "丙卡二"), RecheckFix(old: "甲卡三", new: "丁卡三")], unsure: "")
    let crossApplied = RecheckPrompt.apply(lines: joined.lines, selected: joined.selected, reply: crossReply)
    let crossSplit = RecheckPrompt.split(crossApplied.edits, owner: joined.owner)
    let crossText: String = firstEditText(crossSplit, card: 3) { (e: CardEdit) -> String in "\(e.line):\(e.after)" }
    check(crossText, "3|2:丁卡三。", "跨卡：只改圈到的行（第二張卡沒圈的那行不改）")

    // ---- 按「套用」
    let tapParts: [RecheckPart] = [RecheckPart(cardID: 3, lines: ["甲卡一。"], selected: [0]), RecheckPart(cardID: 4, lines: ["士的事。", "乙卡二。"], selected: [1])]
    let tapped = RecheckPrompt.applyMaybe(RecheckFix(old: "乙卡二", new: "丙卡二"), parts: tapParts)
    let tappedText: String = firstEditText(tapped, card: 4) { (e: CardEdit) -> String in "\(e.line):\(e.before)>\(e.after):\(e.by)" }
    check(tappedText, "4|1:乙卡二。>丙卡二。:web", "套用猜測：套在那張卡那一行、記成 web 改動（綠字）")
    check(RecheckPrompt.applyMaybe(RecheckFix(old: "找不到", new: "別的"), parts: parts).isEmpty ? "空" : "有", "空", "套用猜測：原字已經找不到＝不改")

    // ---- 舊 JSON 相容、新欄位存得進去
    let oldRecheck = #"{"id": 2, "lines": [0], "asked": "甲句", "state": "done", "conclusion": "不用改"}"#
    let decodedRecheck: CardRecheck? = try? JSONDecoder().decode(CardRecheck.self, from: Data(oldRecheck.utf8))
    var decodedRecheckText = "讀不進來"
    if let d = decodedRecheck {
        let conclusion: String = d.conclusion ?? ""
        let maybeMark: String = d.maybe == nil ? "nil" : "有"
        decodedRecheckText = "\(d.id)|\(conclusion)|" + maybeMark
    }
    check(decodedRecheckText, "2|不用改|nil", "舊卡片.json：重查沒有 maybe 照讀")
    let oldCard = #"{"id": 9, "start": 0, "end": 60, "raw": "甲句。", "state": "done", "key": "甲", "tidy": "甲。", "unsure": [], "expanded": "甲句。", "costUSD": 0, "rechecks": [{"id": 1, "lines": [0], "asked": "甲句。", "state": "done"}]}"#
    let decodedCard: LiveCard? = try? JSONDecoder().decode(LiveCard.self, from: Data(oldCard.utf8))
    var decodedCardText = "讀不進來"
    if let d = decodedCard {
        let count: Int = d.rechecks?.count ?? -1
        let maybeMark: String = d.rechecks?.first?.maybe == nil ? "nil" : "有"
        decodedCardText = "\(d.id)|\(d.key)|\(count)|" + maybeMark
    }
    check(decodedCardText, "9|甲|1|nil", "舊卡片.json：整張卡照讀")
    var item = CardRecheck(id: 5, lines: [1], asked: "乙句")
    item.maybe = [RecheckMaybe(old: "甲", new: "乙", applied: true), RecheckMaybe(old: "丙", new: "丁")]
    let itemData: Data? = try? JSONEncoder().encode(item)
    let reread: CardRecheck? = itemData.flatMap { try? JSONDecoder().decode(CardRecheck.self, from: $0) }
    check(reread == item ? "一樣" : "不一樣", "一樣", "卡片.json：猜測和已套用存得進去也讀得回來")

    // ---- 跨卡圈選：圈到哪幾行（整張清單的座標）
    func box(_ card: Int, _ line: Int, _ top: Double) -> CardLineBox {
        CardLineBox(ref: CardLineRef(card: card, line: line), top: top, bottom: top + 20)
    }
    let listBoxes = [box(4, 0, 100), box(3, 1, 22), box(3, 0, 0), box(4, 1, 122), box(3, 2, 44)]
    func across(_ top: Double, _ bottom: Double) -> String {
        refText(CardLines.hitAcross(listBoxes, top: top, bottom: bottom))
    }
    check(across(30, 115), "3.1,3.2,4.0", "跨卡圈行：一筆跨過兩張卡，照上下排")
    check(across(-5, 70), "3.0,3.1,3.2", "跨卡圈行：只在一張卡內和以前一樣")
    check(across(300, 310), "4.1", "跨卡圈行：都沒碰到取最近的一行")
    check(CardLines.hitAcross([], top: 0, bottom: 10).isEmpty ? "空" : "有", "空", "跨卡圈行：沒有行")

    // ---- 跨卡圈選：分組、掛在第一張卡、還在查的行
    let refs = [CardLineRef(card: 4, line: 0), CardLineRef(card: 3, line: 2), CardLineRef(card: 3, line: 1), CardLineRef(card: 3, line: 2),
                CardLineRef(card: 8, line: 0)]
    let groups: [(card: Int, rows: [Int])] = RecheckPrompt.group(refs, order: [3, 4, 5])
    let groupItems: [String] = groups.map { (g: (card: Int, rows: [Int])) -> String in "\(g.card):" + rowsText(g.rows) }
    check(groupItems.joined(separator: " "), "3:1+2 4:0", "跨卡分組：照卡的時間順序、行去重複排好、不在清單的卡不算")
    var span = CardRecheck(id: 6, lines: [1, 2], asked: "甲卡二\n甲卡三\n士的事")
    span.also = [RecheckSpan(cardID: 4, lines: [0], start: 125)]
    let spans: [(card: Int, lines: [Int])] = span.spans(host: 3)
    let spanItems: [String] = spans.map { (s: (card: Int, lines: [Int])) -> String in "\(s.card):" + rowsText(s.lines) }
    check(spanItems.joined(separator: " "), "3:1+2 4:0", "跨卡重查：涉及的卡＝掛著的這張＋also")
    var host = LiveCard(id: 3, start: 60, end: 120, raw: "甲。")
    var doneSpan = span
    doneSpan.id = 7
    doneSpan.state = .done
    doneSpan.lines = [0]
    doneSpan.also = [RecheckSpan(cardID: 4, lines: [1])]
    host.rechecks = [span, doneSpan]
    let waiting = RecheckPrompt.waitingRows([host, LiveCard(id: 4, start: 120, end: 180, raw: "乙。")])
    let waitingItems: [String] = waiting.keys.sorted().map { (k: Int) -> String in
        let rows: [Int] = (waiting[k] ?? []).sorted()
        return "\(k):" + rowsText(rows)
    }
    check(waitingItems.joined(separator: " "), "3:1+2 4:0", "跨卡重查：還在查的行（含別張卡）淡底色，查完的不算")
    let firstStart: Double = span.also?.first?.start ?? 0
    check(CardText.clock(firstStart), "02:05", "跨卡重查：涵蓋的卡寫開始時間")
    let spanData: Data? = try? JSONEncoder().encode(span)
    let spanBack: CardRecheck? = spanData.flatMap { try? JSONDecoder().decode(CardRecheck.self, from: $0) }
    check(spanBack == span ? "一樣" : "不一樣", "一樣", "卡片.json：跨卡的 also 存得進去也讀得回來")
    var alsoMark = "讀不進來"
    if let d = decodedRecheck {
        alsoMark = d.also == nil ? "nil" : "有"
    }
    check(alsoMark, "nil", "舊卡片.json：重查沒有 also 照讀")

    // ---- v0.29.1 非課程：參照詞搜尋（詞、句子全是編的）
    func refShow(_ d: RefDecision) -> String {
        switch d {
        case .wait: return "wait"
        case .checked: return "checked"
        case .search(let why): return "search:" + why
        case .stopped(let why): return "stopped:" + why
        }
    }
    func refList(_ terms: [RefTerm]) -> String {
        terms.map { (t: RefTerm) -> String in t.term + ":" + t.note }.joined(separator: "/")
    }

    // 回覆解析
    let refReplyText: String = "查到了。\n```json\n{\"about\": \"一場談甲乙丙書店的分享\", \"terms\": [{\"term\": \"甲乙丙書店\", \"note\": \"書店名\"}, {\"term\": \"  \", \"note\": \"空的不算\"}, {\"term\": \"丁戊法則\", \"note\": \"術語\", \"replaces\": \"丁午法則\"}]}\n```"
    let refReply: RefSearchReply? = RefSearchReply.parse(refReplyText)
    let refReplyTerms: String = refReply.map { (r: RefSearchReply) -> String in refList(r.terms) } ?? "nil"
    let refReplyAbout: String = refReply?.about ?? "nil"
    let refReplyReplaced: String = (refReply?.replaced ?? []).joined(separator: "/")
    check(refReplyTerms + "|" + refReplyAbout + "|" + refReplyReplaced, "甲乙丙書店:書店名/丁戊法則:術語|一場談甲乙丙書店的分享|丁午法則",
          "參照詞回覆：讀最後的 JSON、空的詞不算、更正記下舊寫法")
    check(RefSearchReply.parse("沒有 JSON") == nil ? "nil" : "有", "nil", "參照詞回覆：沒有 JSON＝讀不出")
    let longNote: String = String(repeating: "說", count: 40)
    let longReplyText: String = "{\"terms\": [{\"term\": \"庚辛\", \"note\": \"" + longNote + "\"}]}"
    let longReplyNote: Int = RefSearchReply.parse(longReplyText)?.terms.first?.note.count ?? -1
    let longReplyAbout: String = RefSearchReply.parse(longReplyText)?.about ?? "nil"
    check("\(longReplyNote)|" + longReplyAbout, "24|", "參照詞回覆：說明截到 24 字、沒有 about 給空字串")

    // 合併：新的在前、同一個詞新的蓋掉舊的（不分大小寫、空白）、被更正的舊寫法拿掉、最多 30 個
    let refOld: [RefTerm] = [RefTerm(term: "Kappa 站", note: "舊"), RefTerm(term: "乙丙", note: "b"), RefTerm(term: "丁午法則", note: "x")]
    let refNew: [RefTerm] = [RefTerm(term: "kappa站", note: "新"), RefTerm(term: "丁戊法則", note: "術語")]
    let refMerged: [RefTerm] = RefSearch.merge(refOld, refNew, replaced: ["丁午法則"])
    check(refList(refMerged), "kappa站:新/丁戊法則:術語/乙丙:b", "參照詞合併：新的在前、同詞新的蓋掉舊的、更正的舊寫法拿掉")
    let manyOld: [RefTerm] = (1...25).map { (i: Int) -> RefTerm in RefTerm(term: "舊詞\(i)", note: "") }
    let manyNew: [RefTerm] = (1...10).map { (i: Int) -> RefTerm in RefTerm(term: "新詞\(i)", note: "") }
    let manyMerged: [RefTerm] = RefSearch.merge(manyOld, manyNew)
    let manyFirst: String = manyMerged.first?.term ?? "nil"
    let manyLast: String = manyMerged.last?.term ?? "nil"
    check("\(manyMerged.count)|" + manyFirst + "|" + manyLast, "30|新詞1|舊詞20", "參照詞合併：最多 30 個、太多丟最舊的")
    let dupNew: [RefTerm] = [RefTerm(term: "壬癸", note: "一"), RefTerm(term: "壬 癸", note: "二")]
    check(refList(RefSearch.merge([], dupNew)), "壬癸:一", "參照詞合併：同一次回覆重複的只留第一個")

    // 最近那段稿一個參照詞都沒出現才重新搜尋
    let filler: String = String(repeating: "甲", count: 300)
    let shortWindow: String = String(repeating: "甲", count: 299)
    let kappa: [RefTerm] = [RefTerm(term: "Kappa站", note: "")]
    let staleShort: Bool = RefSearch.stale(terms: [], window: shortWindow)
    let staleEmpty: Bool = RefSearch.stale(terms: [], window: filler)
    let staleHit: Bool = RefSearch.stale(terms: kappa, window: filler + "KAPPA站")
    let staleMiss: Bool = RefSearch.stale(terms: kappa, window: filler)
    check("\(staleShort)|\(staleEmpty)|\(staleHit)|\(staleMiss)", "false|true|false|true",
          "參照詞：最近那段不到 300 字不算、沒參照詞且字夠就搜、出現一個（不分大小寫）就不搜、都沒出現才搜")

    // 輪數、花費、失敗的上限
    let capNone: String = RefSearch.capReason(rounds: 2, failures: 2, spentUSD: 0.19) ?? "nil"
    let capRounds: String = RefSearch.capReason(rounds: 3, failures: 0, spentUSD: 0) ?? "nil"
    let capCost: String = RefSearch.capReason(rounds: 1, failures: 0, spentUSD: 0.20) ?? "nil"
    let capFail: String = RefSearch.capReason(rounds: 0, failures: 3, spentUSD: 0) ?? "nil"
    check(capNone, "nil", "參照詞上限：2 輪、0.19 美元、失敗 2 次還可以搜")
    check(capRounds + "|" + capCost + "|" + capFail, "這場搜尋 3 輪到上限|這場搜尋花費到上限 0.20 美元|連續沒查到 3 次", "參照詞上限：3 輪、0.20 美元、失敗 3 次")

    // 每秒的決定
    var refReads = 0
    let longText: (all: String, window: String) = (all: String(repeating: "甲", count: 120), window: filler)
    let shortText: (all: String, window: String) = (all: String(repeating: "甲", count: 50), window: "")
    let d1: RefDecision = RefSearch.decide(now: 299, lastCheck: nil, rounds: 0, failures: 0, spentUSD: 0, topicChanged: false, terms: [],
                                           readTexts: { refReads += 1; return longText })
    check(refShow(d1) + "|\(refReads)", "wait|0", "參照詞決定：不到 5 分鐘不搜、也不讀稿")
    let d2: RefDecision = RefSearch.decide(now: 300, lastCheck: nil, rounds: 0, failures: 0, spentUSD: 0, topicChanged: false, terms: [],
                                           readTexts: { longText })
    let d3: RefDecision = RefSearch.decide(now: 900, lastCheck: nil, rounds: 0, failures: 0, spentUSD: 0, topicChanged: false, terms: [],
                                           readTexts: { shortText })
    check(refShow(d2) + "|" + refShow(d3), "search:錄音 5 分鐘|wait", "參照詞決定：5 分鐘有字就搜第一次，字太少先等")
    let d4: RefDecision = RefSearch.decide(now: 899, lastCheck: 300, rounds: 1, failures: 0, spentUSD: 0.03, topicChanged: false, terms: kappa,
                                           readTexts: { longText })
    let d5: RefDecision = RefSearch.decide(now: 900, lastCheck: 300, rounds: 1, failures: 0, spentUSD: 0.03, topicChanged: false, terms: kappa,
                                           readTexts: { longText })
    let hitText: (all: String, window: String) = (all: "", window: filler + "kappa站")
    let d6: RefDecision = RefSearch.decide(now: 900, lastCheck: 300, rounds: 1, failures: 0, spentUSD: 0.03, topicChanged: false, terms: kappa,
                                           readTexts: { hitText })
    check(refShow(d4) + "|" + refShow(d5) + "|" + refShow(d6), "wait|search:最近 10 分鐘的稿沒講到參照詞|checked",
          "參照詞決定：600 秒後才看、沒講到參照詞就重搜、講到就只記檢查時間")
    let d7: RefDecision = RefSearch.decide(now: 310, lastCheck: 300, rounds: 1, failures: 0, spentUSD: 0.03, topicChanged: true, terms: kappa,
                                           readTexts: { hitText })
    let d8: RefDecision = RefSearch.decide(now: 310, lastCheck: 300, rounds: 0, failures: 1, spentUSD: 0, topicChanged: true, terms: [],
                                           readTexts: { hitText })
    check(refShow(d7) + "|" + refShow(d8), "search:改了主題|wait", "參照詞決定：搜過之後改主題就搜一次（還沒搜成過不算）")
    let d9: RefDecision = RefSearch.decide(now: 2000, lastCheck: 300, rounds: 3, failures: 0, spentUSD: 0.05, topicChanged: true, terms: [],
                                           readTexts: { longText })
    let d10: RefDecision = RefSearch.decide(now: 2000, lastCheck: 300, rounds: 1, failures: 0, spentUSD: 0.21, topicChanged: false, terms: [],
                                            readTexts: { longText })
    check(refShow(d9) + "|" + refShow(d10), "stopped:這場搜尋 3 輪到上限|stopped:這場搜尋花費到上限 0.20 美元", "參照詞決定：3 輪或 0.20 美元就不再搜")

    // 送出去的稿：全部卡＋還沒進卡的字；最近那段以最後一個字往回 600 秒
    let refCardA = LiveCard(id: 1, start: 0, end: 60, raw: "甲甲")
    var refCardB = LiveCard(id: 2, start: 700, end: 760, raw: "乙午")
    refCardB.state = .done
    refCardB.expanded = "乙乙"
    let refTail: [LiveUnit] = [LiveUnit(id: 9, text: "丙", start: 770, end: 775, offsetStart: 0, offsetEnd: 1)]
    let refTexts: (all: String, window: String) = RefSearch.texts(cards: [refCardB, refCardA], tail: refTail)
    check(refTexts.all + "#" + refTexts.window, "甲甲\n乙乙\n丙#乙乙\n丙", "參照詞的稿：卡照時間、整理到的用改好的字、最近那段只到 600 秒前")
    let bigCard = LiveCard(id: 3, start: 0, end: 60, raw: String(repeating: "甲", count: 7000))
    let bigTexts: (all: String, window: String) = RefSearch.texts(cards: [bigCard], tail: [])
    check("\(bigTexts.all.count)", "6000", "參照詞的稿：最多送最後 6000 字")

    // 訊息：參照詞和主題、改字對照、說明各自一段
    let book: [RefTerm] = [RefTerm(term: "甲乙丙書店", note: "書店名")]
    check(RefSearch.promptBlock([], about: nil), "", "參照詞：沒有就不放")
    let refBlock: String = RefSearch.promptBlock(book, about: "一場分享")
    let refBlockOK: Bool = refBlock.hasPrefix("\n\n網路查到的參照詞") && refBlock.hasSuffix("\n這場大概在講（搜尋整理的）：一場分享\n甲乙丙書店（書店名）")
    check(refBlockOK ? "對" : refBlock, "對", "參照詞：卡片訊息多一段（搜尋整理的一句＋一詞一行）")
    let refCardMessage: String = CardPrompt.userMessage(context: "", raw: "這段", reference: "", referenceName: "Apple",
                                                        userEdits: SessionTopic.promptBlock("社團分享會") + refBlock)
    let topicAt: Int = refCardMessage.range(of: "使用者說這場的主題")?.lowerBound.utf16Offset(in: refCardMessage) ?? -1
    let refAt: Int = refCardMessage.range(of: "網路查到的參照詞")?.lowerBound.utf16Offset(in: refCardMessage) ?? -1
    check(topicAt >= 0 && refAt > topicAt ? "對" : refCardMessage, "對", "參照詞：接在主題後面，主題和參照詞分開兩段")
    let refRecheck: String = RecheckPrompt.userMessage(course: "", key: "", lines: ["甲句"], nonCourse: true, topic: "社團分享會", references: book)
    check(refRecheck.contains("社團分享會\n網路查到的參照詞（之前搜尋整理的，只當參考）：甲乙丙書店（書店名）\n這段的重點：") ? "對" : refRecheck, "對",
          "參照詞：重查訊息多一行（主題後面）")
    let refRefresh: String = CardRefresh.userMessage(transcript: ["甲。"], notes: [], key: "", tidy: "", topic: "社團分享會", references: book)
    check(refRefresh.hasPrefix("這場的主題（使用者自己寫的）：社團分享會\n\n網路查到的參照詞（之前搜尋整理的，只當參考）：甲乙丙書店（書店名）\n\n這張卡修正後的逐字稿") ? "對" : refRefresh,
          "對", "參照詞：重算訊息多一行（主題後面）")
    let searchMessage: String = RefSearch.userMessage(transcript: "稿", topic: "社團分享會", known: book)
    let searchMessageOK: Bool = searchMessage.hasPrefix("主題（使用者自己寫的）：社團分享會\n\n已經找到的參照詞")
        && searchMessage.contains("甲乙丙書店（書店名）") && searchMessage.hasSuffix("只用來查）：\n稿")
    check(searchMessageOK ? "對" : searchMessage, "對", "參照詞搜尋訊息：主題、已經找到的（叫它不要再列）、稿")
    let firstSearch: String = RefSearch.userMessage(transcript: "稿", topic: nil, known: [])
    check(firstSearch.contains("已經找到") || firstSearch.contains("主題") ? firstSearch : "對", "對", "參照詞搜尋訊息：第一次沒有已知、沒主題就不放")
    let refSystemWords: [String] = ["不要猜", "最多 30 個", "replaces", "已經找到的參照詞"]
    let refSystemMissing: [String] = refSystemWords.filter { (word: String) -> Bool in !RefSearch.system.contains(word) }
    check(refSystemMissing.joined(separator: "、"), "", "參照詞搜尋提示詞：查不到不列、最多 30 個、已知的不再列")
    let cardRefMissing: Bool = !CardPrompt.system.contains("網路查到的參照詞")
    check(cardRefMissing ? "沒有" : "有", "有", "卡片提示詞：講明參照詞只當參考")

    // 請求：和重查同一份（Haiku＋網路搜尋最多 3 次），只換 system
    if let body = try? RecheckPrompt.body(userMessage: "稿", assistant: nil, system: RefSearch.system),
       let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
       let tools = object["tools"] as? [[String: Any]], let tool = tools.first {
        let systemSame: Bool = (object["system"] as? String) == RefSearch.system
        check("\(systemSame)|\(tool["name"] ?? "")|\(tool["max_uses"] ?? "")", "true|web_search|3", "參照詞請求：和重查同一份請求、只換提示詞")
    } else {
        check("編不出來", "編得出來", "參照詞請求：編得出來")
    }

    // Pencil 重查改進逐字稿的字也收進參照詞（不另外搜尋）
    let fromFixes: [RefTerm] = RefSearch.fromRecheck([RecheckFix(old: "丁午", new: "丁戊法則"), RecheckFix(old: "乙", new: "  "),
                                                      RecheckFix(old: "丙", new: String(repeating: "丙", count: 31))])
    check(refList(fromFixes), "丁戊法則:Pencil 重查確認", "參照詞：重查改的字收進來（空的、太長的不收）")
    let staleRecheckOnly: Bool = RefSearch.stale(terms: fromFixes, window: filler + "丁戊法則")
    check("\(staleRecheckOnly)", "true", "參照詞：重查收進來的詞出現不算（話題換了照樣重搜）")

    // 狀態列
    let fragBusy: String = RefSearch.statusFragment(count: 3, rounds: 1, busy: true)
    let fragNone: String = RefSearch.statusFragment(count: 0, rounds: 0, busy: false)
    let fragSome: String = RefSearch.statusFragment(count: 5, rounds: 1, busy: false)
    check(fragBusy + "|" + fragNone + "|" + fragSome, "・參照詞搜尋中||・參照詞 5 個", "參照詞狀態列：搜尋中、還沒搜不寫、找到幾個")

    // 改字紀錄：存得進去、舊檔讀得開；摘要一行只寫個數、花費另計
    var refLog = ReviewLog(course: "")
    refLog.costUSD = 0.5
    refLog.refTerms = book + [RefTerm(term: "丁戊法則", note: "術語")]
    refLog.refAbout = "一場分享"
    refLog.refRounds = 1
    refLog.refCostUSD = 0.04
    refLog.refLastCheck = 300
    let refLogData: Data? = try? JSONEncoder().encode(refLog)
    let refLogBack: ReviewLog? = refLogData.flatMap { (d: Data) -> ReviewLog? in try? JSONDecoder().decode(ReviewLog.self, from: d) }
    check(refLogBack == refLog ? "一樣" : "不一樣", "一樣", "改字紀錄：參照詞、輪數、花費、檢查時間存得進去也讀得回來")
    let oldLog: ReviewLog? = try? JSONDecoder().decode(ReviewLog.self, from: Data("{\"course\": \"\"}".utf8))
    let oldTermsNil: Bool = oldLog != nil && oldLog?.refTerms == nil
    let oldRoundsNil: Bool = oldLog != nil && oldLog?.refRounds == nil
    let oldCostNil: Bool = oldLog != nil && oldLog?.refCostUSD == nil
    let oldLogRef: String = "\(oldTermsNil)|\(oldRoundsNil)|\(oldCostNil)"
    check(oldLogRef, "true|true|true", "舊改字紀錄：沒有參照詞欄位照讀")
    let refSummary: String = refLog.summaryLine
    let refSummaryOK: Bool = refSummary.contains("約 0.500 美元") && refSummary.contains("參照詞 2 個（搜尋 1 輪、約 0.040 美元另計）")
        && !refSummary.contains("甲乙丙書店") && !refSummary.contains("一場分享")
    check(refSummaryOK ? "對" : refSummary, "對", "改字紀錄摘要：參照詞只寫個數、輪數、花費另計，不寫詞")
}
