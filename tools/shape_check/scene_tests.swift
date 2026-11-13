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
    check(block.hasPrefix("\n\n這場使用者改過") && block.hasSuffix("天講法則→天講連鎖法則") ? "對" : block, "對", "參考：一段字接在訊息最後")
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
        check(RecheckPrompt.sources(parsed.content).map { $0.title + "=" + $0.url }.joined(separator: ","), "乙網頁=https://example.com/b", "重查來源：先用引用、去重複")
        let uncited = parsed.content.filter { (($0 as? [String: Any])?["citations"]) == nil }
        check(RecheckPrompt.sources(uncited).map { $0.title + "=" + $0.url }.joined(separator: ","),
              "甲網頁=https://example.com/a,https://example.com/b=https://example.com/b", "重查來源：沒有引用用搜尋結果、只收 http(s)、沒標題用網址")
        check(String(format: "%.4f", RecheckPrompt.cost(usage: parsed.usage, searches: parsed.searches)), "0.0202", "重查花費：token＋每次搜尋 0.01 美元")
        check(RecheckPrompt.searchError(parsed.content) ?? "沒有", "沒有", "重查回應：搜尋沒出錯")
    } else {
        check("解析不了", "解析得了", "重查回應：解析")
    }
    let errorJSON = #"{"content": [{"type": "web_search_tool_result", "tool_use_id": "s", "content": {"type": "web_search_tool_result_error", "error_code": "max_uses_exceeded"}}], "stop_reason": "pause_turn", "usage": {"input_tokens": 10, "output_tokens": 1}}"#
    if let parsed = RecheckPrompt.parse(Data(errorJSON.utf8)) {
        check("\(parsed.stopReason ?? "nil")|\(parsed.searches)|\(RecheckPrompt.searchError(parsed.content) ?? "沒有")|\(RecheckPrompt.sources(parsed.content).count)",
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
}
