import Foundation

// v0.26.0 Sources/LiveCards.swift：即時模式 1 每批一張卡的純邏輯——原稿 vs 擴寫逐字比對、一句一行、回覆解析、程式把關、複製與整理版的字。
// 比對、一句一行的期望值先用 Python 照同一套演算法（LCS、平手先刪）跑同樣的輸入算出來（不是看 Swift 的結果回填）。
// 句子全是自己編的合成句。main.swift 只呼叫 cardsTests(check)。

func cardsTests(_ check: @escaping (String, String, String) -> Void) {
    func diff(_ raw: String, _ expanded: String) -> String {
        CardDiff.describe(CardDiff.pieces(raw: raw, expanded: expanded))
    }

    // ---- 逐字比對：標點、空白不算改動
    check(diff("今天我們來看導數的定義", "今天，我們來看導數的定義。"), "今天，我們來看導數的定義。", "卡片比對：只加標點不標")
    check(diff("先算f的導數再乘上g的導數", "先算 f 的導數，再乘上 g 的導數。"), "先算 f 的導數，再乘上 g 的導數。", "卡片比對：加空白、標點不標")
    check(diff("一樣的句子。", "一樣的句子。"), "一樣的句子。", "卡片比對：整段相同")
    // ---- 純插入
    check(diff("這個函數連續", "這個函數是連續的"), "這個函數[是]連續[的]", "卡片比對：純插入（綠字、沒有原字）")
    check(diff("", "只有新的"), "[只有新的]", "卡片比對：原稿空、全部是新加的")
    // ---- 純刪除
    check(diff("那個那個我們先看例題", "那個我們先看例題"), "那個{-那個}我們先看例題", "卡片比對：純刪除（小紅點，原字放在點上）")
    check(diff("只有舊的", ""), "{-只有舊的}", "卡片比對：擴寫空、全部刪掉")
    // ---- 換字
    check(diff("這叫做練習法則", "這叫做連鎖法則"), "這叫做[連鎖|練習]法則", "卡片比對：換字（原字跟著綠字）")
    check(diff("好那我們今天上課要講練習法則那麼他的意思是", "好，那我們今天上課要講連鎖法則。那麼它的意思是？"),
          "好，那我們今天上課要講[連鎖|練習]法則。\n那麼[它|他]的意思是？", "卡片比對：一段裡兩處換字＋補標點＋一句一行")
    check(diff("嗯嗯對所以答案是二", "對，所以答案是 2。"), "{-嗯嗯}對，所以答案是 [2|二]。", "卡片比對：刪語助詞＋數字改寫")
    let pieces = CardDiff.pieces(raw: "好那我們今天上課要講練習法則那麼他的意思是", expanded: "好，那我們今天上課要講連鎖法則。那麼它的意思是？")
    check(pieces.map(\.text).joined(), CardDiff.lines("好，那我們今天上課要講連鎖法則。那麼它的意思是？"), "卡片比對：片段接起來＝一句一行後的擴寫")
    check("\(CardDiff.changeCount(pieces))", "2", "卡片比對：改了幾處")
    check("\(CardDiff.changeCount(CardDiff.pieces(raw: "今天我們來看", expanded: "今天，我們來看。")))", "0", "卡片比對：只有標點＝0 處")

    // ---- 一句一行
    check(CardDiff.lines("第一句。第二句？第三句！還有「引號。」最後"), "第一句。\n第二句？\n第三句！\n還有「引號。」\n最後", "一句一行：。？！後換行，引號跟著上一句")
    check(CardDiff.lines("甲。\n\n乙"), "甲。\n乙", "一句一行：原本的空行拿掉")
    check(CardDiff.lines("結尾。"), "結尾。", "一句一行：句尾在最後不多換行")
    check(CardDiff.lines("Is it ok? Yes!  next"), "Is it ok?\nYes!\nnext", "一句一行：英文問號驚嘆號，下一行前面的空白拿掉")
    check(CardDiff.lines("沒有句號"), "沒有句號", "一句一行：沒有句尾不動")

    // ---- 回覆解析（容錯）
    func show(_ r: CardReply?) -> String {
        guard let r else { return "讀不出" }
        return "\(r.page.map { "\($0)" } ?? "nil")|\(r.key)|\(r.tidy)|\(r.unsure.joined(separator: ","))|\(r.expanded)"
    }
    let normal = #"{"page":12,"key":"連鎖法則","tidy":"老師說明連鎖法則。","unsure":["練習→連鎖"],"expanded":"今天講連鎖法則。"}"#
    check(show(CardReply.parse(normal)), "12|連鎖法則|老師說明連鎖法則。|練習→連鎖|今天講連鎖法則。", "卡片解析：正常")
    check(show(CardReply.parse("```json\n" + normal + "\n```")), "12|連鎖法則|老師說明連鎖法則。|練習→連鎖|今天講連鎖法則。", "卡片解析：多包了 ```json")
    check(show(CardReply.parse("好的，結果如下：\n" + normal + "\n以上。")), "12|連鎖法則|老師說明連鎖法則。|練習→連鎖|今天講連鎖法則。", "卡片解析：前後多了說明字")
    check(show(CardReply.parse(#"{"expanded":"只有全文。"}"#)), "nil||||只有全文。", "卡片解析：缺欄位用預設")
    check(show(CardReply.parse(#"{"page":null,"key":"重點","tidy":"","unsure":[],"expanded":"全文"}"#)), "nil|重點|||全文", "卡片解析：page 是 null")
    check(show(CardReply.parse(#"{"page":0,"key":"","tidy":"","unsure":[],"expanded":"全文"}"#)), "nil||||全文", "卡片解析：page 是 0＝看不出來")
    check(show(CardReply.parse(#"{"page":"7","key":"","tidy":"","unsure":"甲→乙、丙→丁、戊→己","expanded":"全文"}"#)), "7|||甲→乙,丙→丁|全文", "卡片解析：page 是字串、unsure 是一串字、最多 2 個")
    check(show(CardReply.parse(#"{"page":3,"key":"重點","tidy":"整理"}"#)), "讀不出", "卡片解析：缺 expanded 不算")
    check(show(CardReply.parse(#"{"page":3,"key":"重點","tidy":"整理","unsure":[],"expanded":"   "}"#)), "讀不出", "卡片解析：expanded 空白不算")
    check(show(CardReply.parse(#"{"page": 3, "key": "#)), "讀不出", "卡片解析：JSON 壞掉")
    check(show(CardReply.parse("我沒辦法處理這段")), "讀不出", "卡片解析：沒有 JSON")

    // ---- API 回應：前面有 thinking 區塊、stop_reason
    func response(_ text: String, stop: String) -> Data {
        let inner = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
        return Data(#"{"content":[{"type":"thinking","thinking":"…"},{"type":"text","text":\#(inner)}],"stop_reason":"\#(stop)","usage":{"input_tokens":100,"output_tokens":50}}"#.utf8)
    }
    if case .reply(let reply, let usage) = CardPrompt.parseResponse(response(normal, stop: "end_turn")) {
        check("\(reply.page ?? 0) \(usage?.output_tokens ?? 0)", "12 50", "卡片回應：跳過 thinking 讀文字區塊")
    } else {
        check("沒讀到", "讀到", "卡片回應：跳過 thinking 讀文字區塊")
    }
    check(CardPrompt.parseResponse(response(normal, stop: "max_tokens")) == .truncated(usage: Usage(input_tokens: 100, output_tokens: 50)) ? "超長" : "不對", "超長", "卡片回應：max_tokens 不採用")
    if case .unreadable = CardPrompt.parseResponse(response("壞掉的 {", stop: "end_turn")) {
        check("解析失敗", "解析失敗", "卡片回應：文字不是 JSON → 解析失敗（照現有規則重送一次）")
    } else {
        check("不對", "解析失敗", "卡片回應：文字不是 JSON → 解析失敗（照現有規則重送一次）")
    }

    // ---- 程式把關：頁碼範圍、擴寫太短
    let reply = CardReply(page: 30, key: "重點", tidy: "整理", unsure: [], expanded: "今天，我們來看導數的定義。")
    check(CardPrompt.accept(reply, raw: "今天我們來看導數的定義", pageCount: 20).reply.page.map { "\($0)" } ?? "nil", "nil", "卡片把關：頁碼超過投影片頁數不收")
    check(CardPrompt.accept(reply, raw: "今天我們來看導數的定義", pageCount: 0).reply.page.map { "\($0)" } ?? "nil", "nil", "卡片把關：沒有投影片頁碼不收")
    var inRange = reply
    inRange.page = 5
    check(CardPrompt.accept(inRange, raw: "今天我們來看導數的定義", pageCount: 20).reply.page.map { "\($0)" } ?? "nil", "5", "卡片把關：範圍內的頁碼收")
    let short = CardReply(page: nil, key: "", tidy: "", unsure: [], expanded: "導數定義。")
    let cut = CardPrompt.accept(short, raw: "今天我們來看導數的定義然後我們看一個例題", pageCount: 0)
    check(cut.reply.expanded + "｜" + (cut.note == nil ? "沒說明" : "有說明"), "今天我們來看導數的定義然後我們看一個例題｜有說明", "卡片把關：擴寫比原稿短太多（像摘要）→ 用原稿")
    check(CardPrompt.accept(reply, raw: "今天我們來看導數的定義", pageCount: 20).note == nil ? "採用" : "不採用", "採用", "卡片把關：長度正常照用")

    // ---- 使用者訊息不帶 [s編號]
    let message = CardPrompt.userMessage(context: "", raw: "這段原稿", reference: "Apple 的字", referenceName: "Apple")
    check(message.contains("[s") ? "有編號" : "沒有編號", "沒有編號", "卡片訊息：原稿不帶 [s編號]")
    check(message.contains("（無）") && message.contains("Apple 同一段") ? "對" : message, "對", "卡片訊息：沒前文寫（無）、附 Apple 同一段")
    check(CardPrompt.userMessage(context: "前面", raw: "這段", reference: "", referenceName: "Apple").contains("Apple") ? "有附" : "沒附", "沒附", "卡片訊息：沒有 Apple 的字就不附")

    // ---- 請求：卡片用自己的提示詞和 schema；舊的請求不變
    if let body = try? CardPrompt.requestBody(courseBlock: "課名：測試", userMessage: "這段原稿"),
       let text = String(data: body, encoding: .utf8) {
        check(text.contains("\"expanded\"") && text.contains("擴寫式校正") && text.contains("\"max_tokens\":8000") ? "對" : "不對", "對", "卡片請求：用卡片提示詞、schema、上限 8000")
    } else {
        check("編不出來", "對", "卡片請求：用卡片提示詞、schema、上限 8000")
    }
    let oldBody = try? HaikuPrompt.requestBody(courseBlock: "課名：測試", userMessage: "新稿")
    check(oldBody.map { String(decoding: $0, as: UTF8.self).contains("\"slide_page\"") ? "舊的" : "變了" } ?? "編不出來", "舊的", "卡片請求：模式 0、2 的請求照舊用改字提示詞")

    // ---- 提示詞常數和正本一字不差（tools/haiku_prompt/card.txt、card_schema.json）
    func source(_ name: String) -> String? {
        guard let data = FileManager.default.contents(atPath: "tools/haiku_prompt/" + name) else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }
    check(source("card.txt") == CardPrompt.system ? "一樣" : "不一樣（跑 同步提示詞.py）", "一樣", "卡片提示詞：常數和 card.txt 一字不差")
    check(source("card_schema.json") == CardPrompt.schemaText ? "一樣" : "不一樣（跑 同步提示詞.py）", "一樣", "卡片提示詞：常數和 card_schema.json 一字不差")
    check((try? JSONDecoder().decode(JSONValue.self, from: Data(CardPrompt.schemaText.utf8))) != nil ? "解得開" : "解不開", "解得開", "卡片提示詞：schema 解得開")

    // ---- 複製、整理版、逐字稿、狀態列頁碼
    var a = LiveCard(id: 1, start: 0, end: 61, raw: "原稿一")
    a.state = .done
    a.page = 3
    a.key = "導數定義"
    a.tidy = "老師先複習導數的定義。"
    a.unsure = ["到數→導數"]
    a.expanded = "擴寫一。"
    var b = LiveCard(id: 2, start: 61, end: 125, raw: "原稿二")
    b.state = .failed
    var c = LiveCard(id: 3, start: 125, end: 3700, raw: "原稿三")
    c.state = .done
    c.key = "例題"
    c.tidy = "做一題例題。"
    c.expanded = "擴寫三。"
    check(CardText.copy([a, b, c]), "[p.3] 導數定義\n老師先複習導數的定義。\n\n例題\n做一題例題。", "卡片複製：[頁碼] 重點＋整理版，沒整理到的不放")
    check(CardText.tidyFile([a, b, c]), "00:00–01:01　p.3\n重點：導數定義\n老師先複習導數的定義。\n不確定：到數→導數\n\n01:01–02:05\n（沒整理到）\n\n02:05–1:01:40\n重點：例題\n做一題例題。\n", "整理版：時間、頁碼、重點、整理版、不確定")
    check(CardText.transcript([c, a, b], tail: "還沒進卡"), "擴寫一。\n\n原稿二\n\n擴寫三。\n\n還沒進卡", "逐字稿：依時間接擴寫，沒整理到用原稿，沒進卡的接最後")
    // v0.26.1 分享到別的 App 的文字
    check(CardText.share(a), "[p.3] 導數定義\n\n老師先複習導數的定義。\n\n原稿：\n擴寫一。\n\n不確定：到數→導數", "卡片分享：[頁碼] 重點、整理版、原稿、不確定的詞")
    check(CardText.share(b), "原稿：\n原稿二", "卡片分享：沒整理到的卡只有原稿")
    var d = c
    d.expanded = "第一句。第二句？"
    check(CardText.share(d), "例題\n\n做一題例題。\n\n原稿：\n第一句。\n第二句？", "卡片分享：沒頁碼不寫 [p.N]、原稿一句一行")
    check(CardText.latestPage([a, b, c]).map { "\($0)" } ?? "nil", "3", "狀態列頁碼：最新一張有頁碼的卡")
    check(CardText.latestPage([b]).map { "\($0)" } ?? "nil", "nil", "狀態列頁碼：都沒有頁碼")
    let saved = try? JSONEncoder().encode([a, b])
    let back = saved.flatMap { try? JSONDecoder().decode([LiveCard].self, from: $0) }
    check(back == [a, b] ? "一樣" : "不一樣", "一樣", "卡片存檔：寫出去讀回來一樣")
    check(ReviewText.cardStatus(done: 3, failed: 1, lastLatency: 4.3, stop: nil), "Haiku：整理 3 張・沒整理到 1 張・上一批 4.3 秒", "卡片狀態列")
    check(ReviewText.cardStatus(done: 0, failed: 0, lastLatency: nil, stop: nil), "Haiku：等待第一張卡", "卡片狀態列：還沒有卡")
}
