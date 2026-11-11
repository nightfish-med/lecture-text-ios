import Foundation

// v0.23.2 錄音中 Haiku 改字的純邏輯層（Sources/HaikuFix.swift、LiveFix.swift 規則欄位）。
// 規格 B9 第 1–30、42–48 項；外加讀 tools/haiku_prompt/驗證案例.json 逐筆跑（桌面的 Python 模擬器跑同一份）。
// main.swift 只呼叫 haikuTests(check)。shape_check 在倉庫根目錄執行，讀得到 tools/haiku_prompt/。

func haikuTests(_ check: @escaping (String, String, String) -> Void) {
    func yes(_ ok: Bool, _ name: String) { check(ok ? "對" : "錯", "對", name) }
    func timed(_ text: String, _ start: Double, _ end: Double) -> TimedPiece { TimedPiece(text: text, start: start, end: end) }
    func unit(_ id: Int, _ text: String) -> LiveUnit {
        LiveUnit(id: id, text: text, start: Double(id), end: Double(id) + 1, offsetStart: 0, offsetEnd: text.count)
    }
    func ruleText(_ rules: [LiveFixRule]) -> String {
        rules.map { "\($0.wrong)→\($0.right) 左\($0.keepLeft) 右\($0.keepRight)" }.joined(separator: "；")
    }
    let calcTable = LiveFix.rules(course: "解析幾何")
    let pages = ["Row reduction and echelon form. 高斯消去法 Gaussian elimination", "Inverse matrix A⁻¹ 反矩陣",
                 "Determinant 行列式 det(A)", "Eigenvalue λ and 非零 eigenvector", "Augmented matrix example"]
    let pool = TermPool(pages: pages, glossary: calcTable)
    func edit(_ s: Int, _ wrong: String, _ right: String, _ type: String = "同音", _ evidence: String = "前後文") -> HaikuReply.Edit {
        HaikuReply.Edit(s: s, wrong: wrong, right: right, type: type, evidence: evidence)
    }
    func run(_ edits: [HaikuReply.Edit], _ units: [LiveUnit], table: [LiveFixRule]? = nil, off: Set<String> = [],
             session: String? = nil, chatter: Bool = false, state: FixState = FixState()) -> (records: [FixRecord], state: FixState) {
        var st = state
        let records = FixValidator.validate(edits: edits, chatter: chatter, units: units, pool: pool, table: table ?? calcTable,
                                            off: off, sessionText: session ?? units.map(\.text).joined(), state: &st, batch: 1, at: 10)
        return (records, st)
    }

    // ---- 單位與批次（B9 1–6）
    do {
        var sp = UnitSplitter()
        sp.add([timed("那這個函數", 0, 1)], offsetBefore: 0, offsetAfter: 5)
        sp.add([timed("的到數該怎麼求。", 1, 2.5)], offsetBefore: 5, offsetAfter: 13)
        check(sp.units.map(\.text).joined(separator: "|"), "那這個函數的到數該怎麼求。", "Haiku 單位 1：太短的塊併成一個單位")
        check(sp.units.map { "\($0.id) \($0.start)-\($0.end) \($0.offsetStart)-\($0.offsetEnd)" }.joined(), "1 0.0-2.5 0-13", "Haiku 單位 1：併起來的時間和位置")

        var long = UnitSplitter(nextID: 128)
        let text = String(repeating: "甲", count: 69) + "。" + String(repeating: "乙", count: 60)
        long.add([timed(text, 0, 13)], offsetBefore: 1000, offsetAfter: 1130)
        check(long.units.map { "\($0.id):\($0.text.count)" }.joined(separator: " "), "128:70 129:60", "Haiku 單位 2：130 字在第 70 字的句號切成 2 個")
        check(long.units.map { "\($0.offsetStart)-\($0.offsetEnd) \($0.end == 7 ? "7" : "\($0.end)")" }.joined(separator: " "), "1000-1070 7 1070-1130 13.0",
              "Haiku 單位 2：切開的位置和時間照字數比例")
        check("\(long.nextID)", "130", "Haiku 單位 2：編號接著往下")

        var cleaned = UnitSplitter()
        cleaned.add([timed("上麵的", 0, 1), timed("特征", 1, 2)], offsetBefore: 0, offsetAfter: 5)
        check(cleaned.units.first?.text ?? "", "上面的特征", "Haiku 單位 3：TextCleanup 有修、對照表的字沒套")

        var sent = UnitSplitter()
        sent.add([timed("第一句話講完了。", 0, 2)], offsetBefore: 0, offsetAfter: 8)
        sent.markSent([1], batch: 1)
        sent.add([timed("短", 2, 3)], offsetBefore: 8, offsetAfter: 9)
        check(sent.units.map(\.text).joined(separator: "|"), "第一句話講完了。|短", "Haiku 單位：已送的單位不再併字")
        var parts = UnitSplitter()
        parts.add([timed("第一段", 0, 1)], offsetBefore: 0, offsetAfter: 3)
        parts.newSegment()
        parts.add([timed("第二段開始了", 100, 101)], offsetBefore: 20, offsetAfter: 26)
        check(parts.units.map(\.text).joined(separator: "|"), "第一段|第二段開始了", "Haiku 單位：續錄的新段不併進上一段")
        check(parts.context(before: 2), "第一段", "Haiku 前文：編號之前的稿")
        check("\(BatchPlanner.context([unit(1, String(repeating: "前", count: 280)), unit(2, String(repeating: "後", count: 40))]).count)", "300",
              "Haiku 前文：最多 300 字")

        let fourteen = [unit(1, String(repeating: "字", count: 140))]
        yes(BatchPlanner.due(unsent: fourteen, now: 15, lastSent: 0), "Haiku 批次 4：0–14 秒 140 字，第 15 秒要送")
        yes(!BatchPlanner.due(unsent: [], now: 16, lastSent: 15), "Haiku 批次 4：第 16 秒沒有新字不送")
        let few = [unit(1, String(repeating: "字", count: 15))]
        yes(!BatchPlanner.due(unsent: few, now: 15, lastSent: 0), "Haiku 批次 5：新字 15 字、第 15 秒不送")
        yes(BatchPlanner.due(unsent: few, now: 45, lastSent: 0), "Haiku 批次 5：同樣的字到第 45 秒送")

        check(HaikuPrompt.userMessage(context: "", units: [unit(128, "那這個函數的到數該怎麼求"), unit(129, "然後呢")]),
              "前文（只參考，不准改）：\n（無）\n\n新稿：\n[s128] 那這個函數的到數該怎麼求\n[s129] 然後呢", "Haiku 使用者訊息 6：沒有前文寫（無）")
        check(BatchPlanner.userMessage(context: "我們上次講到列運算", units: [unit(5, "今天講反矩陣")]),
              "前文（只參考，不准改）：\n我們上次講到列運算\n\n新稿：\n[s5] 今天講反矩陣", "Haiku 使用者訊息 6：有前文")
    }

    // ---- 驗證（B9 7–23；完整的一條一條在下面共用案例跑，這裡補規則欄位）
    do {
        let one = run([edit(99, "消去發", "消去法")], [unit(1, "我們用高斯消去發來做")])
        check(one.records.first?.verdict.rawValue ?? "", "s不在新稿", "Haiku 驗證 7：s 不在這批")

        let passed = run([edit(1, "消去發", "消去法", "同音", "投影片p.1")], [unit(1, "我們用高斯消去發來做")])
        let rule = passed.records.first?.rules.first
        check(passed.records.first?.verdict.rawValue ?? "", "通過", "Haiku 驗證 8：消去發→消去法 通過")
        check(rule.map { "\($0.wrong)→\($0.right) \($0.keepLeft) \($0.source.rawValue) \($0.evidence ?? "") \($0.fixID ?? 0)" } ?? "沒有規則",
              "消去發→消去法 0 haiku 投影片p.1 1", "Haiku 驗證 8：全場規則、來源 haiku、依據、對到紀錄編號")
        check(ruleText(passed.state.learned), "消去發→消去法 左0 右0", "Haiku 驗證 8：通過的規則進已學規則")
        check(passed.records.first?.unitText ?? "", "我們用高斯消去發來做", "Haiku 驗證 8：紀錄存那一句（只在 fixes.json）")

        let cross = run([edit(1, "消去發", "消去法")], [unit(1, "接著用高斯消"), unit(2, "去發把它化簡")])
        check("\(cross.records.first?.verdict.rawValue ?? "") s\(cross.records.first?.s ?? 0)", "通過 s1", "Haiku 驗證 10：原字跨 s 和 s+1")

        let rows = run([edit(1, "洛", "row", "英文", "投影片p.1")], [unit(1, "第一個洛加到第二個洛")], table: [])
        check(ruleText(rows.records.first?.rules ?? []), "一個洛加到→一個row加到 左2 右2；二個洛→二個row 左2 右0", "Haiku 驗證 22：一字原字兩處各自定位擴充")
        check(rows.records.first?.rules.map(\.core).joined(separator: ",") ?? "", "洛,洛", "Haiku 驗證 22：core 是中間真正改的字")

        let many = run([edit(1, "消去發", "消去法")], [unit(1, "所以消去發很好用")], session: "消去發。消去發。消去發。消去發。消去發。所以消去發很好用")
        check(ruleText(many.records.first?.rules ?? []), "所以消去發很好→所以消去法很好 左2 右2", "Haiku 驗證 23：3 字原字全場 6 次改成定位擴充")

        let split = [unit(1, "然後第一個洛"), unit(2, "加到第二列")]
        check(ruleText(run([edit(1, "洛", "row", "英文", "投影片p.1")], split, table: []).records.first?.rules ?? []), "一個洛加到→一個row加到 左2 右2",
              "Haiku 驗證 v2：單位切在詞中間，右邊的字從下一個單位取")
        var v1State = FixState()
        let v1 = FixValidator.validate(edits: [edit(1, "洛", "row", "英文", "投影片p.1")], chatter: false, units: split, pool: pool, table: [],
                                       off: [], sessionText: "然後第一個洛加到第二列", state: &v1State, batch: 1, at: 0, version: .v1)
        check(ruleText(v1.first?.rules ?? []), "一個洛→一個row 左2 右0", "Haiku 驗證 v1：只看該單位")
        check(run([edit(1, "第一個洛再加上第一個洛", "列", "術語", "投影片p.1")], [unit(1, "然後第一個洛再加上第一個洛")]).records.first?.verdict.rawValue ?? "",
              "改後少了太多中文字", "Haiku 驗證 v2 11.5：整串字換成一個詞")
        check(FixValidator.defaultVersion.rawValue, "v3", "Haiku 驗證：預設 v3（英文音節檢查；和桌面模擬器一樣）")

        let learned = LiveFixRule(wrong: "消去發", right: "消去法", source: .haiku)
        let twice = run([edit(1, "消去發", "消去髮"), edit(1, "消去發", "消去伐"), edit(1, "消去發", "消去法")], [unit(1, "我們用高斯消去發來做")],
                        state: FixState(learned: [learned]))
        check(twice.records.map(\.verdict.rawValue).joined(separator: ","), "和先前改法衝突,和先前改法衝突,和先前改法衝突",
              "Haiku 驗證 21：衝突第 2 次停用舊規則，之後同一個原字都判衝突")
        check("\(twice.state.learned.count) \(twice.state.retired.map(\.core).joined())", "0 消去發", "Haiku 驗證 21：停用的規則移出已學規則")

        let ids = run([edit(9, "a", "b"), edit(1, "消去發", "消去法")], [unit(1, "我們用高斯消去發來做")])
        check(ids.records.map { "\($0.id)" }.joined(separator: ",") + " 下一號\(ids.state.nextID)", "1,2 下一號3", "Haiku 驗證：每筆紀錄都有編號")
    }

    // ---- 拼音（B9 24）
    yes(Pinyin.near("去爭", "句陣"), "Haiku 拼音 24：去爭～句陣")
    yes(Pinyin.near("公私", "公式"), "Haiku 拼音 24：公私～公式")
    yes(Pinyin.near("不是你", "不是零"), "Haiku 拼音 24：不是你～不是零")
    yes(!Pinyin.near("化是", "化成"), "Haiku 拼音 24：化是≁化成")
    check(Pinyin.syllables("矩陣")?.map { $0.initial + "-" + $0.final }.joined(separator: " ") ?? "轉不出", "j-u zh-en", "Haiku 拼音：聲母韻母拆法")
    yes(Pinyin.syllables("row") == nil, "Haiku 拼音：不是漢字回 nil")

    // ---- 畫面套字（B9 25–27）
    do {
        let expanded = [LiveFixRule(wrong: "一個洛加到", right: "一個row加到", keepLeft: 2, keepRight: 2, source: .haiku, evidence: "投影片p.1", fixID: 7),
                        LiveFixRule(wrong: "二個洛", right: "二個row", keepLeft: 2, keepRight: 0, source: .haiku, evidence: "投影片p.1", fixID: 7)]
        let first = LiveFix.pieces("第一個洛加到第二個洛", rules: [expanded[0]])
        check(first.map { p in p.original.map { "\(p.text)(\($0))" } ?? p.text }.joined(separator: "|"), "第一個|row(洛)|加到第二個洛",
              "Haiku 套字 25：定位擴充分三段，綠底只有中間的字")
        check(LiveFix.copyText("第一個洛加到第二個洛", rules: [expanded[0]]), "第一個row［洛］加到第二個洛", "Haiku 套字 25：複製只標中間的字")
        check(first.compactMap { $0.rule?.fixID }.map { "\($0)" }.joined(), "7", "Haiku 套字 25：改過的那段帶規則（小卡寫來源）")
        check(LiveFix.copyText("第一個洛加到第二個洛", rules: expanded), "第一個row［洛］加到第二個row［洛］", "Haiku 套字 25：兩條一起套")
        check("\(LiveFix.count("第一個洛加到第二個洛", rules: expanded))", "2", "Haiku 套字：count 算改了幾處")
        check(LiveFix.rules(course: "解析幾何", off: ["洛"], learned: expanded).filter { $0.core == "洛" }.count == 0 ? "都關掉" : "還有",
              "都關掉", "Haiku 套字：off 比對 core（按掉「洛」連定位擴充的也不套）")
        check("\(LiveFix.rules(course: "解析幾何", learned: expanded).count - calcTable.count)", "2", "Haiku 套字：已學規則接在對照表後面")

        // 26：首字索引版和逐一比對的舊算法，20 條隨機規則 × 5 個句子
        var seed: UInt64 = 1110
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        let alphabet = Array("矩陣句陣洛加到第二個非零")
        var same = 0
        for round in 0..<5 {
            let rules = (0..<20).map { i in
                LiveFixRule(wrong: String((0..<(1 + next(3))).map { _ in alphabet[next(alphabet.count)] }), right: "X\(round)-\(i)")
            }
            let text = String((0..<40).map { _ in alphabet[next(alphabet.count)] })
            let sorted = rules.enumerated().sorted { $0.element.wrong.count != $1.element.wrong.count ? $0.element.wrong.count > $1.element.wrong.count : $0.offset < $1.offset }.map(\.element)
            var old: [String] = []
            var plain = ""
            var i = text.startIndex
            while i < text.endIndex {
                if let rule = sorted.first(where: { text[i...].hasPrefix($0.wrong) }) {
                    if !plain.isEmpty { old.append(plain + "|nil"); plain = "" }
                    old.append(rule.right + "|" + rule.wrong)
                    i = text.index(i, offsetBy: rule.wrong.count)
                } else {
                    plain.append(text[i])
                    i = text.index(after: i)
                }
            }
            if !plain.isEmpty { old.append(plain + "|nil") }
            let new = LiveFix.pieces(text, rules: rules).map { $0.text + "|" + ($0.original ?? "nil") }
            if new == old { same += 1 }
        }
        check("\(same)", "5", "Haiku 套字 26：首字索引和舊算法 5 句都一樣")

        let oldJSON = try? JSONDecoder().decode(LiveFixRule.self, from: Data(#"{"wrong":"句陣","right":"矩陣"}"#.utf8))
        check(oldJSON.map { "\($0.wrong)→\($0.right) \($0.keepLeft) \($0.source.rawValue)" } ?? "讀不開", "句陣→矩陣 0 table", "Haiku 規則：只有 wrong、right 的舊資料讀得開")
        let back = (try? JSONEncoder().encode(expanded)).flatMap { try? JSONDecoder().decode([LiveFixRule].self, from: $0) }
        yes(back == expanded, "Haiku 規則：存了讀回來一樣")
        check(LiveFixRule(wrong: "ab", right: "c", keepLeft: 5, keepRight: 5).core, "", "Haiku 規則：keep 超過字數不會當掉")
    }

    // ---- 問題（B9 28–30）
    do {
        let u = unit(1, "這裡的ABC3要注意")
        var gate = QuestionGate()
        let a = gate.admit(.init(s: 1, about: "ABC3", text: "s1 的『ABC3』是不是 a1 a2 a3？"), unit: u, at: 100, editedWrongs: [])
        let b = gate.admit(.init(s: 1, about: "要注意", text: "s1 的『要注意』是不是聽錯？"), unit: u, at: 130, editedWrongs: [])
        check("\(a ?? "放行") \(b ?? "放行")", "放行 限頻沒顯示", "Haiku 問題 28：相隔 30 秒的第二題被擋")
        let c = gate.admit(.init(s: 1, about: "ABC3", text: "再問一次？"), unit: u, at: 300, editedWrongs: [])
        check(c ?? "放行", "已問過", "Haiku 問題 29：同一個 about 第二次被擋")
        let d = gate.admit(.init(s: 1, about: "XYZ", text: "這是什麼？"), unit: u, at: 400, editedWrongs: [])
        check(d ?? "放行", "about不在該句", "Haiku 問題 30：about 不在單位裡")
        let e = gate.admit(.init(s: 1, about: "要注意", text: "？"), unit: u, at: 500, editedWrongs: ["注意"])
        check(e ?? "放行", "是這批改過的字", "Haiku 問題：這批改過的字不問")
        let f = gate.admit(.init(s: 2, about: "要注意", text: "？"), unit: nil, at: 600, editedWrongs: [])
        check(f ?? "放行", "s不在新稿", "Haiku 問題：s 不在這批")
        var full = QuestionGate()
        full.shown = 15
        check(full.admit(.init(s: 1, about: "要注意", text: "？"), unit: u, at: 1000, editedWrongs: []) ?? "放行", "已達上限", "Haiku 問題：一場最多 15 題")
    }

    // ---- 費用與 API（B9 42–47）
    do {
        let usage = Usage(input_tokens: 600, output_tokens: 1500, cache_read_input_tokens: 9000)
        yes(abs(Cost.usd(usage) - 0.0009) < 1e-12, "Haiku 費用 42：輸入 600、快取讀 9000、輸出 1500 → 0.0009 美元")
        let bare = try? JSONDecoder().decode(Usage.self, from: Data(#"{"input_tokens":1000,"output_tokens":0}"#.utf8))
        check(bare.map { "\($0.input_tokens) \($0.cache_read_input_tokens.map { "\($0)" } ?? "nil")" } ?? "解不開", "1000 nil", "Haiku 費用 43：缺快取欄位也解得開")

        let block = HaikuPrompt.courseBlock(course: "解析幾何", glossary: calcTable, deck: nil)
        let message = HaikuPrompt.userMessage(context: "", units: [unit(1, "我們用高斯消去發來做")])
        let b1 = try? HaikuPrompt.requestBody(courseBlock: block, userMessage: message)
        let b2 = try? HaikuPrompt.requestBody(courseBlock: block, userMessage: message)
        let body = b1.map { String(decoding: $0, as: UTF8.self) } ?? ""
        yes(b1 != nil && b1 == b2, "Haiku 請求 44：同一輸入編兩次位元組相同")
        yes(body.contains(#""ttl":"1h""#) && body.contains(#""cache_control":{"ttl":"1h","type":"ephemeral"}"#), "Haiku 請求 44：課程區塊帶 1 小時快取")
        yes(!body.contains("temperature") && !body.contains("thinking"), "Haiku 請求 44：沒有 temperature、thinking")
        yes(body.contains(#""model":"claude-haiku-5-5""#) && body.contains(#""max_tokens":6000"#) && body.contains(#""effort":"low""#),
            "Haiku 請求 44：模型、max_tokens、effort")
        yes(body.hasPrefix(#"{"max_tokens":6000,"messages":[{"content":"#), "Haiku 請求 44：鍵照字母排")
        let object = b1.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let system = object?["system"] as? [[String: Any]]
        yes(system?.count == 2 && system?.first?["cache_control"] == nil && (system?.first?["text"] as? String) == HaikuPrompt.system,
            "Haiku 請求 44：第一個 system 區塊是提示詞、不帶快取")
        let format = (object?["output_config"] as? [String: Any])?["format"] as? [String: Any]
        let sentSchema = (format?["schema"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        yes(format?["type"] as? String == "json_schema" && sentSchema != nil && sentSchema == (try? HaikuPrompt.schema()), "Haiku 請求 44：schema 原樣放進 output_config.format")

        check(block, "課名：解析幾何\n詞表（左＝稿裡常見的錯，右＝正確）：" + calcTable.map { "\($0.wrong)→\($0.right)" }.joined(separator: "、") + "\n這堂沒有投影片。",
              "Haiku 課程區塊：沒有投影片")
        let deck = SlideDeck.make(course: "解析幾何", source: "lecture-17.pdf", importedAt: "x", pages: ["Inverse matrix", "", "行列式"])
        check(HaikuPrompt.courseBlock(course: "解析幾何", glossary: [LiveFixRule(wrong: "句陣", right: "矩陣")], deck: deck),
              "課名：解析幾何\n詞表（左＝稿裡常見的錯，右＝正確）：句陣→矩陣\n這堂投影片全文（[p.N] 是頁碼）：\n[p.1]\nInverse matrix\n[p.2]\n[p.3]\n行列式",
              "Haiku 課程區塊：投影片每頁前面 [p.N]")
        let big = SlideDeck.make(course: "解析幾何", source: "big.pdf", importedAt: "x", pages: Array(repeating: String(repeating: "字", count: 996), count: 70))
        check("\(HaikuPrompt.slidePagesSent(big))", "60", "Haiku 課程區塊：投影片超過 6 萬 token 後面的頁不送")

        let reply = #"{"edits":[{"s":1,"wrong":"消去發","right":"消去法","type":"同音","evidence":"投影片p.1"}],"questions":[],"slide_page":1,"page_evidence":"高斯","chatter":false}"#
        func response(_ stop: String, _ blocks: [[String: Any]]) -> Data {
            let object: [String: Any] = ["stop_reason": stop, "content": blocks,
                                         "usage": ["input_tokens": 10, "output_tokens": 20, "cache_read_input_tokens": 30]]
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }
        let ok = HaikuPrompt.parseResponse(response("end_turn", [["type": "thinking", "thinking": ""], ["type": "text", "text": reply]]))
        if case .reply(let r, let stop, let u) = ok {
            check("\(r.edits.first?.right ?? "") \(r.slide_page) \(stop ?? "") \(u?.cache_read_input_tokens ?? 0)", "消去法 1 end_turn 30", "Haiku 回覆 45：跳過 thinking、解第一個 text 區塊")
        } else {
            check("\(ok)", "reply", "Haiku 回覆 45：跳過 thinking、解第一個 text 區塊")
        }
        yes(HaikuPrompt.parseResponse(response("max_tokens", [["type": "text", "text": "{\"edits\":["]])) == .truncated(usage: Usage(input_tokens: 10, output_tokens: 20, cache_read_input_tokens: 30)),
            "Haiku 回覆 45：max_tokens 判截斷、不套")
        if case .refusal = HaikuPrompt.parseResponse(response("refusal", [["type": "text", "text": reply]])) { yes(true, "Haiku 回覆：refusal 整批不套") } else { yes(false, "Haiku 回覆：refusal 整批不套") }
        if case .unreadable = HaikuPrompt.parseResponse(response("end_turn", [["type": "text", "text": "好的，以下是"]])) { yes(true, "Haiku 回覆：不是 JSON 要重送") } else { yes(false, "Haiku 回覆：不是 JSON 要重送") }
        if case .unreadable = HaikuPrompt.parseResponse(Data("<html>".utf8)) { yes(true, "Haiku 回覆：回應本身壞掉") } else { yes(false, "Haiku 回覆：回應本身壞掉") }

        check(APIKeyMask.masked("sk-ant-api03-abcdWXYZ"), "sk-ant-…WXYZ", "Haiku 金鑰 47：遮到只剩末 4 碼")

        var log = ReviewLog(course: "解析幾何", slides: "lecture-17.pdf")
        log.fixes = run([edit(1, "消去發", "消去法")], [unit(1, "我們用高斯消去發來做")]).records
        log.off = []
        log.costUSD = 0.0009
        log.batches = [ReviewBatch(id: 1, unitIDs: [1], context: "", audioStart: 0, audioEnd: 15, state: .done)]
        let logBack = (try? JSONEncoder().encode(log)).flatMap { try? JSONDecoder().decode(ReviewLog.self, from: $0) }
        yes(logBack == log, "Haiku 紀錄：fixes.json 存了讀回來一樣")
        check(ruleText(log.learnedRules) + " 下一號\(log.fixState.nextID)", "消去發→消去法 左0 右0 下一號2", "Haiku 紀錄：續錄還原已學規則和編號")

        // 11/11 同字升級：兩批各通過一次 → 升級；續錄還原升級規則和採用次數；被按掉的不還原
        do {
            let p = TermPool(pages: ["pivot"], glossary: [])
            var st = FixState()
            var recs = FixValidator.validate(edits: [edit(1, "這叫 pibbet", "這叫 pivot", "英文", "投影片p.1")], chatter: false,
                                             units: [unit(1, "這叫 pibbet它的位置")], pool: p, table: [], off: [], sessionText: "這叫 pibbet它的位置",
                                             state: &st, batch: 1, at: 0, promotion: .app)
            recs += FixValidator.validate(edits: [edit(2, "pibbet是", "pivot是", "英文", "投影片p.1")], chatter: false,
                                          units: [unit(2, "第二列的 pibbet是叫這個")], pool: p, table: [], off: [],
                                          sessionText: "這叫 pibbet它的位置第二列的 pibbet是叫這個", state: &st, batch: 2, at: 0, promotion: .app)
            func upText(_ r: FixRecord) -> String {
                let adopted = r.adopted ?? false
                guard let p = r.promoted else { return "\(adopted) -" }
                return "\(adopted) \(p.wrong)→\(p.right) \(p.source.rawValue) \(p.fixID ?? 0)"
            }
            check(recs.map(upText).joined(separator: "；"),
                  "true -；true pibbet→pivot promoted 2", "同字升級：第 2 次採用升成全場規則（來源 promoted、對到第 2 筆）")
            check(LiveFix.copyText("前面的 pibbet也是", rules: st.learned), "前面的 pivot［pibbet］也是", "同字升級：之前沒改到的地方也改")
            var up = ReviewLog(course: "解析幾何")
            up.fixes = recs
            let restored = up.fixState
            let lastSource = restored.learned.last?.source.rawValue ?? ""
            let adoptCount = restored.adopt[Promotion.key("pibbet", "pivot")] ?? 0
            check("\(restored.learned.count) \(lastSource) \(adoptCount)",
                  "3 promoted 2", "同字升級：續錄還原升級規則和採用次數")
            up.off = ["pibbet"]
            check("\(up.learnedRules.filter { $0.source == .promoted }.count)", "0", "同字升級：這場不再改的詞，續錄不還原升級規則")
            yes(up.summaryLine.contains("升級全場 1 條") && !up.summaryLine.contains("pibbet"), "同字升級：摘要一行寫條數、不含稿的字")
            let back = (try? JSONEncoder().encode(up)).flatMap { try? JSONDecoder().decode(ReviewLog.self, from: $0) }
            yes(back == up, "同字升級：fixes.json 存了讀回來一樣（adopted、promoted）")
            let hits = ReviewPromoted.hits(recs, text: "這叫 pibbet它的位置第二列的 pibbet是叫這個前面的 pibbet也是", rules: st.learned)
            check(hits.map { r -> String in r.promotedHits.map { "\($0)" } ?? "-" }.joined(separator: ","), "-,1",
                  "同字升級：升級規則套用幾處（帶前後字的規則先比，另外 1 處才是升級規則改的）")
        }
        yes(!log.summaryLine.contains("消去") && log.summaryLine.hasPrefix("Haiku：1 批（完成 1）、改字通過 1、擋下 0"), "Haiku 紀錄：摘要一行不含稿的字")
        let emptyLog = try? JSONDecoder().decode(ReviewLog.self, from: Data(#"{"course":"解析幾何"}"#.utf8))
        check(emptyLog.map { "\($0.version) \($0.model) \($0.fixes.count)" } ?? "讀不開", "1 claude-haiku-5-5 0", "Haiku 紀錄：少欄位也讀得開")
    }

    // ---- 46：提示詞常數和正本一字不差
    func source(_ name: String) -> String? {
        guard let data = FileManager.default.contents(atPath: "tools/haiku_prompt/" + name) else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }
    let systemFile = source("system.txt")
    check(systemFile == nil ? "讀不到" : (systemFile == HaikuPrompt.system ? "一樣" : "不一樣（跑 同步提示詞.py）"), "一樣", "Haiku 提示詞 46：HaikuPrompt.system 和 system.txt 一字不差")
    let schemaFile = source("schema.json")
    check(schemaFile == nil ? "讀不到" : (schemaFile == HaikuPrompt.schemaText ? "一樣" : "不一樣（跑 同步提示詞.py）"), "一樣", "Haiku 提示詞 46：schema 常數和 schema.json 一字不差")
    yes((try? HaikuPrompt.schema()) != nil, "Haiku 提示詞：schema 解得開")

    // ---- 48：共用的 驗證案例.json
    sharedCases(check)
}

/// 讀 tools/haiku_prompt/驗證案例.json，每一筆照期望結果（頁碼那段是 0.23.3 的 PageTracker，這裡不跑）。
private func sharedCases(_ check: @escaping (String, String, String) -> Void) {
    guard let data = FileManager.default.contents(atPath: "tools/haiku_prompt/驗證案例.json"),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        check("讀不到", "讀得到", "共用案例：讀 tools/haiku_prompt/驗證案例.json")
        return
    }
    func list(_ any: Any?) -> [[String: Any]] { any as? [[String: Any]] ?? [] }
    func pairs(_ any: Any?) -> [LiveFixRule] { (any as? [[String]] ?? []).compactMap { $0.count == 2 ? LiveFixRule(wrong: $0[0], right: $0[1]) : nil } }
    func units(_ any: Any?) -> [LiveUnit] {
        list(any).map { u in
            let text = u["text"] as? String ?? ""
            return LiveUnit(id: u["id"] as? Int ?? 0, text: text, start: 0, end: 0, offsetStart: 0, offsetEnd: text.count)
        }
    }
    func number(_ any: Any?) -> Double { (any as? NSNumber)?.doubleValue ?? 0 }
    let shared = root["共用"] as? [String: Any] ?? [:]
    let sharedPages = shared["投影片"] as? [String] ?? []
    let sharedTable = pairs(shared["對照表"])
    let defaultVersion = ValidatorVersion(rawValue: root["驗證版"] as? String ?? "v1") ?? .v1
    var total = 0
    var good = 0
    func record(_ got: String, _ want: String, _ name: String) {
        total += 1
        if got == want { good += 1 }
        check(got, want, "共用案例 " + name)
    }

    for c in list(root["單位"]) {
        var sp = UnitSplitter()
        var pos = 0
        for b in list(c["塊"]) {
            let text = b["text"] as? String ?? ""
            sp.add([TimedPiece(text: text, start: number(b["start"]), end: number(b["end"]))], offsetBefore: pos, offsetAfter: pos + text.count)
            pos += text.count
        }
        record(sp.units.map(\.text).joined(separator: "｜"), (c["期望"] as? [String] ?? []).joined(separator: "｜"), "單位 \(c["編號"] ?? "")")
    }
    for c in list(root["批次"]) {
        let got = BatchPlanner.due(unsentChars: c["未送字數"] as? Int ?? 0, now: number(c["now"]), lastSent: number(c["lastSent"]))
        record("\(got)", "\(c["期望"] as? Bool ?? !got)", "批次 \(c["編號"] ?? "")")
    }
    for c in list(root["使用者訊息"]) {
        record(HaikuPrompt.userMessage(context: c["前文"] as? String ?? "", units: units(c["單位"])), c["期望"] as? String ?? "", "使用者訊息 \(c["編號"] ?? "")")
    }
    for c in list(root["驗證"]) {
        let table = c["對照表"] != nil ? pairs(c["對照表"]) : sharedTable
        let pool = TermPool(pages: c["投影片"] as? [String] ?? sharedPages, glossary: table)
        let learned = list(c["已學規則"]).map {
            LiveFixRule(wrong: $0["wrong"] as? String ?? "", right: $0["right"] as? String ?? "",
                        keepLeft: $0["keepLeft"] as? Int ?? 0, keepRight: $0["keepRight"] as? Int ?? 0, source: .haiku)
        }
        let us = units(c["單位"])
        let edits = list(c["edits"]).map {
            HaikuReply.Edit(s: $0["s"] as? Int ?? 0, wrong: $0["wrong"] as? String ?? "", right: $0["right"] as? String ?? "",
                            type: $0["type"] as? String ?? "", evidence: $0["evidence"] as? String ?? "")
        }
        var state = FixState(learned: learned)
        let records = FixValidator.validate(edits: edits, chatter: c["閒聊"] as? Bool ?? false, units: us, pool: pool, table: table,
                                            off: Set(c["off"] as? [String] ?? []), sessionText: c["全場稿"] as? String ?? us.map(\.text).joined(),
                                            state: &state, batch: 1, at: 0,
                                            version: (c["驗證版"] as? String).flatMap(ValidatorVersion.init(rawValue:)) ?? defaultVersion)
        for (i, exp) in list(c["期望"]).enumerated() {
            let got = i < records.count ? records[i] : nil
            var want = [exp["判定"] as? String ?? ""]
            var have = [got?.verdict.rawValue ?? "（沒有這筆）"]
            if let s = exp["s"] as? Int {
                want.append("s\(s)")
                have.append("s\(got?.s ?? 0)")
            }
            if let rules = exp["規則"] as? [[String: Any]] {
                want.append(rules.map { "\($0["wrong"] as? String ?? "")→\($0["right"] as? String ?? "") 左\($0["keepLeft"] as? Int ?? -1) 右\($0["keepRight"] as? Int ?? -1)" }.joined(separator: "；"))
                have.append((got?.rules ?? []).map { "\($0.wrong)→\($0.right) 左\($0.keepLeft) 右\($0.keepRight)" }.joined(separator: "；"))
            }
            record(have.joined(separator: " "), want.joined(separator: " "), "驗證 \(c["編號"] ?? "")#\(i + 1) \(c["名稱"] ?? "")")
        }
        if let stopped = c["期望停用"] as? [String] {
            record(Set(state.retired.map(\.core)).sorted().joined(separator: ","), stopped.sorted().joined(separator: ","), "驗證 \(c["編號"] ?? "") 停用")
        }
    }
    for c in list(root["拼音"]) {
        record("\(Pinyin.near(c["a"] as? String ?? "", c["b"] as? String ?? ""))", "\(c["期望"] as? Bool ?? false)", "拼音 \(c["編號"] ?? "")")
    }
    for c in list(root["問題"]) {
        var gate = QuestionGate()
        let us = units(c["單位"])
        for step in list(c["序列"]) {
            let q = step["題"] as? [String: Any] ?? [:]
            let question = HaikuReply.Question(s: q["s"] as? Int ?? 0, about: q["about"] as? String ?? "", text: q["text"] as? String ?? "")
            let got = gate.admit(question, unit: us.first { $0.id == question.s }, at: number(step["at"]), editedWrongs: [])
            record(got ?? "放行", step["期望"] as? String ?? "放行", "問題 \(c["編號"] ?? "") at=\(step["at"] ?? "")")
        }
    }
    for c in list(root["費用"]) {
        let usage = (c["usage"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { try? JSONDecoder().decode(Usage.self, from: $0) }
        let got = usage.map(Cost.usd) ?? -1
        record(abs(got - number(c["期望美元"])) < 1e-12 ? "對" : "\(got)", "對", "費用 \(c["編號"] ?? "")")
    }
    // 11/11：v3 英文音節（判定和兩邊音節數都要和 Python 一樣）
    let sylSlides = (root["音節投影片"] as? [String] ?? []).joined(separator: "\n").lowercased()
    for c in list(root["音節"]) {
        let got = Syllables.check(wrong: c["wrong"] as? String ?? "", right: c["right"] as? String ?? "", slides: sylSlides)
        let counts = got.wrong.map { "\($0),\(got.right ?? -1)" } ?? "不檢查"
        let want = (c["音節"] as? [Int]).map { "\($0[0]),\($0[1])" } ?? "不檢查"
        record("\(got.verdict?.rawValue ?? "不擋") \(counts)", "\(c["期望"] as? String ?? "") \(want)", "音節 \(c["編號"] ?? "")")
    }
    // 11/11：同字升級（依序跑每一批，比判定、升級規則、套用結果）
    for c in list(root["升級"]) {
        let table = pairs(c["對照表"])
        let pool = TermPool(pages: c["投影片"] as? [String] ?? [], glossary: table)
        var state = FixState()
        var session = ""
        var verdicts: [String] = []
        var promoted: [String] = []
        for (i, b) in list(c["批"]).enumerated() {
            let us = units(b["單位"])
            session += us.map(\.text).joined()
            let edits = list(b["edits"]).map {
                HaikuReply.Edit(s: $0["s"] as? Int ?? 0, wrong: $0["wrong"] as? String ?? "", right: $0["right"] as? String ?? "",
                                type: $0["type"] as? String ?? "", evidence: $0["evidence"] as? String ?? "")
            }
            let recs = FixValidator.validate(edits: edits, chatter: false, units: us, pool: pool, table: table, off: [], sessionText: session,
                                             state: &state, batch: i + 1, at: 0, version: .v3,
                                             promotion: (c["升級"] as? Bool ?? false) ? Promotion.app : nil)
            verdicts += recs.map(\.verdict.rawValue)
            promoted += recs.compactMap(\.promoted).map { "\($0.wrong)→\($0.right)" }
        }
        let applied = LiveFix.copyText(c["套用"] as? String ?? "", rules: table + state.learned)
            .replacingOccurrences(of: "［[^］]*］", with: "", options: .regularExpression)
        record([verdicts.joined(separator: ","), promoted.joined(separator: ","), applied].joined(separator: " | "),
               [(c["期望判定"] as? [String] ?? []).joined(separator: ","), (c["期望升級"] as? [String] ?? []).joined(separator: ","),
                c["期望套用"] as? String ?? ""].joined(separator: " | "), "升級 \(c["編號"] ?? "") \(c["名稱"] ?? "")")
    }
    check("\(good)/\(total)", "\(total)/\(total)", "共用案例：全部筆數")
}
