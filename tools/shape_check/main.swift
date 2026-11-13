import Foundation

// 雲端編譯前先跑：修字和斷句。不用模擬器、不用手機。
// swiftc Sources/TextShaping.swift Sources/Schedule.swift Sources/LinkProtocol.swift Sources/RecordWatch.swift Sources/ClassRecord.swift Sources/LiveFix.swift Sources/SlidePages.swift Sources/HaikuPromptText.swift Sources/HaikuFix.swift Sources/ReviewPlan.swift Sources/DrivePlan.swift Sources/LabPlan.swift Sources/WhisperPlan.swift Sources/LiveCutPlan.swift Sources/LiveCards.swift tools/shape_check/haiku_tests.swift tools/shape_check/review_tests.swift tools/shape_check/drive_tests.swift tools/shape_check/whisper_tests.swift tools/shape_check/livecut_tests.swift tools/shape_check/cards_tests.swift tools/shape_check/recover_tests.swift tools/shape_check/main.swift -o shape_check && ./shape_check
var failed = 0
func check(_ got: String, _ want: String, _ name: String) {
    if got == want {
        print("過 \(name)")
    } else {
        failed += 1
        print("錯 \(name)\n  得到：\(got)\n  應為：\(want)")
    }
}

// 測試用的假課表與假對照表。App 執行時從 Documents/設定/轉文字設定.json 讀；這裡的課名、錯字全是編的。
func sampleSettings() -> AppSettings {
    var s = AppSettings()
    s.firstDay = "2026-02-23"
    s.lastDay = "2026-06-21"
    s.courses = [
        .init(name: "日文", weekday: 1, from: "09:00", to: "10:30"),
        .init(name: "私人課", weekday: 1, from: "20:00", to: "21:00", isPrivate: true),
        .init(name: "桌遊", formal: "桌遊設計", weekday: 2, from: "13:00", to: "14:40"),
        .init(name: "美術", formal: "美術鑑賞", weekday: 2, from: "15:00", to: "16:30"),
        .init(name: "幾何", formal: "解析幾何", weekday: 3, from: "08:00", to: "09:50"),
        .init(name: "木工", formal: "木工實作", weekday: 4, from: "13:30", to: "16:00"),
        .init(name: "讀書會", weekday: 5, from: "18:00", to: "19:30", weeks: [1, 3, 5, 7, 9, 11, 13]),
        .init(name: "幾何", formal: "解析幾何", weekday: 6, from: "14:00", to: "15:30"),
    ]
    s.offDays = ["2026-03-18": [], "2026-03-12": ["木工"]]
    s.privateKeywords = ["私人"]
    s.liveFix = ["解析幾何": [["單位像量", "單位向量"], ["單味像量", "單位向量"], ["反像量", "反向量"], ["像量", "向量"],
                          ["飛靈", "非零"], ["一階到數", "一階導數"], ["到數", "倒數"], ["烤", "column"]]]
    return s
}
AppSettings.current = sampleSettings()

// 修字：例子都是真機稿裡出現過的字形錯（繁體一對多）
check(TextCleanup.fix("一年裏麵"), "一年裡面", "裏麵")
check(TextCleanup.fix("隻不過呢有一個人"), "只不過呢有一個人", "隻不過")
check(TextCleanup.fix("不隻是這樣"), "不只是這樣", "不隻")
check(TextCleanup.fix("空出兩隻手"), "空出兩隻手", "兩隻手不動")
check(TextCleanup.fix("這隻鳥"), "這隻鳥", "這隻不動")
check(TextCleanup.fix("代錶我們"), "代表我們", "代錶")
check(TextCleanup.fix("臉部錶情"), "臉部表情", "錶情")
check(TextCleanup.fix("那他錶這個的目的"), "那他表這個的目的", "他錶這個")
check(TextCleanup.fix("錶麵"), "表面", "錶麵")
check(TextCleanup.fix("我的手錶"), "我的手錶", "手錶不動")
check(TextCleanup.fix("鐘錶店"), "鐘錶店", "鐘錶不動")
check(TextCleanup.fix("吃麵包"), "吃麵包", "麵包不動")
check(TextCleanup.fix("控製沖動"), "控制衝動", "控製沖動")
check(TextCleanup.fix("半保留復製"), "半保留複製", "復製")
check(TextCleanup.fix("人際關係"), "人際關係", "關係不動")
check(TextCleanup.fix("邊緣係統"), "邊緣系統", "係統")
check(TextCleanup.fix("這個係列"), "這個系列", "係列")
check(TextCleanup.fix("長得一樣 ，然後"), "長得一樣，然後", "標點前空白")
check(TextCleanup.fix("寫的 3700多年"), "寫的 3700多年", "數字前空白不動")

// 分段：稿裡不放時間
func piece(_ text: String, _ start: Double, _ end: Double) -> TimedPiece {
    TimedPiece(text: text, start: start, end: end)
}
let twenty = String(repeating: "字", count: 25)
var a = LineBuilder()
a.add([piece("總之我們都", 0, 1)])
a.add([piece("認為說物種會改變。但是以前的人", 1.1, 3)])
check(a.text, "總之我們都認為說物種會改變。但是以前的人", "沒停頓就留在同一段，沒有時間標記")

var b = LineBuilder()
b.add([piece(twenty, 0, 3), piece("停很久才接下一句", 5, 6)])
check(b.text, "\(twenty)\n\n停很久才接下一句", "停頓夠久空一行")

var c = LineBuilder()
c.add([piece("短句", 0, 1), piece("停了還是接著", 3, 4)])
check(c.text, "短句停了還是接著", "太短不因停頓分段")

var d = LineBuilder()
d.add([piece("一年裏", 0, 1), piece("麵的事", 1, 2)])
check(d.text, "一年裡面的事", "跨片段的錯字也要修")

var e = LineBuilder()
e.add([piece("不知道時間的字", -1, -1), piece("也接得上", -1, -1)])
check(e.text, "不知道時間的字也接得上", "沒有時間不崩")

var f = LineBuilder()
f.add([piece(twenty, 0, 2), piece("。", 4, 4.1)])
check(f.text, "\(twenty)。", "停頓後的句號留在同一段")

var g = LineBuilder()
let long = String(repeating: "長", count: 115)
g.add([piece(long + "。接下一段", 0, 5)])
check(g.text, "\(long)。\n\n接下一段", "夠長在句尾分段")

var h = LineBuilder()
let tooLong = String(repeating: "長", count: 185)
h.add([piece(tooLong, 0, 5), piece("完全沒停也要分", 5, 6)])
check(h.text, "\(tooLong)\n\n完全沒停也要分", "超過上限沒句尾也分段")

// 分人：字貼講者
func turn(_ who: String, _ start: Double, _ end: Double) -> SpeakerTurn {
    SpeakerTurn(speaker: who, start: start, end: end)
}
check(
    SpeakerLabeler.label(
        pieces: [piece("你好嗎？", 0, 1), piece("我很好。", 2, 3)],
        turns: [turn("SPEAKER_01", 0, 1.5), turn("SPEAKER_00", 1.5, 3)]
    ).text,
    "A：你好嗎？\n\nB：我很好。",
    "先講的是 A，不看模型給的編號"
)
check(
    SpeakerLabeler.label(
        pieces: [piece("今天", 0, 0.5), piece("天氣", 0.5, 1), piece("很好，", 1, 2), piece("對啊。", 2.1, 3)],
        turns: [turn("x", 0, 0.7), turn("y", 0.7, 0.8), turn("x", 0.8, 2), turn("y", 2, 3)]
    ).text,
    "A：今天天氣很好，\n\nB：對啊。",
    "一小句中間的短雜訊不把句子切開"
)
check(
    SpeakerLabeler.label(
        pieces: [piece("甲說。", 0, 1), piece("沒有時間的字。", -1, -1), piece("乙說。", 2, 3)],
        turns: [turn("x", 0, 1), turn("y", 2, 3)]
    ).text,
    "A：甲說。沒有時間的字。\n\nB：乙說。",
    "沒時間的字跟著前一個人"
)
check(
    SpeakerLabeler.label(
        pieces: [piece("落在空隙。", 1.1, 1.3), piece("後面。", 3, 4)],
        turns: [turn("x", 0, 1), turn("y", 3, 4)]
    ).text,
    "A：落在空隙。\n\nB：後面。",
    "沒重疊的字找時間最近的人"
)
let threePeople = SpeakerLabeler.label(
    pieces: [piece("一。", 0, 1), piece("二。", 2, 3), piece("三。", 4, 5), piece("回到一。", 6, 7)],
    turns: [turn("p", 0, 1), turn("q", 2, 3), turn("r", 4, 5), turn("p", 6, 7)]
)
check(threePeople.text, "A：一。\n\nB：二。\n\nC：三。\n\nA：回到一。", "三個人，回來還是同一個字母")
check(threePeople.names.joined(), "ABC", "人名清單")
check(
    SpeakerLabeler.label(pieces: [piece("沒有分人結果。", 0, 1)], turns: []).text,
    "沒有分人結果。",
    "分人沒結果就是原稿"
)
let longTurn = String(repeating: "長", count: 115)
check(
    SpeakerLabeler.label(pieces: [piece(longTurn + "。接著", 0, 5), piece("講。", 5, 6)], turns: [turn("x", 0, 6)]).text,
    "A：\(longTurn)。\n\nA：接著講。",
    "同一人很長時每段都標人"
)

// 校正：只留有把握的提示，而且只標註
let fixSource = "明治圍新和夏木漱石，夏木漱石。"
let fixEdits = TextFixer.clean([
    TextEdit(wrong: "明治圍新", right: "明治維新"),
    TextEdit(wrong: "夏木漱石", right: "夏目漱石"),
    TextEdit(wrong: "稿裡沒有", right: "不該收了"),
    TextEdit(wrong: "和", right: "跟"),
    TextEdit(wrong: "夏木漱石", right: "重複不收"),
    TextEdit(wrong: "講個幾句話", right: "講幾句話"),
], in: fixSource + "講個幾句話")
check(String(fixEdits.count), "2", "校正只留稿裡有、不是單字、字數相同的")
check(String(TextFixer.clean([TextEdit(wrong: "A：", right: "B：")], in: "A：今天很好").count), "0", "校正不收講者標籤")
check(String(TextFixer.clean([TextEdit(wrong: "A：今天", right: "B：今天")], in: "A：今天很好").count), "0", "校正不收含標籤的片段")

let markSource = "A：夏木漱石來了\n\nB：我不認識夏木漱石\n\nA：講者一直沒來\n\n講者12：夏木漱石又來了"
let markBlocks = TextBlocks.split(markSource, limit: 12)
check(markBlocks.map { block in block.lines.map { "\($0)" }.joined(separator: "+") }.joined(separator: ","), "0,2,4,6", "切塊記得原稿行號")
check(TextBlocks.split("甲\n\n乙\n丙", limit: 900).first?.text ?? "", "甲\n乙\n丙\n", "切塊內容和舊版相同，空行不進去")
let marked = TextMarker.mark(
    hints: [BlockHints(lines: [2], edits: [TextEdit(wrong: "夏木漱石", right: "夏目漱石")])],
    in: markSource
)
check(marked, "A：夏木漱石來了\n\nB：我不認識夏木漱石〔夏目漱石？〕\n\nA：講者一直沒來\n\n講者12：夏木漱石又來了", "校正只標模型看過的那一塊，別塊不動")
check(TextMarker.strip(marked), markSource, "拿掉標註就是原稿，一個字都沒動")
check(
    TextMarker.mark(hints: [BlockHints(lines: [0, 2, 4, 6], edits: [TextEdit(wrong: "A：", right: "B："), TextEdit(wrong: "講者", right: "將者")])], in: markSource),
    "A：夏木漱石來了\n\nB：我不認識夏木漱石\n\nA：講者〔將者？〕一直沒來\n\n講者12：夏木漱石又來了",
    "就算標籤文字漏進來，行首講者標籤也不會被標"
)
check(TextFixer.apply([TextEdit(wrong: "大學", right: "X"), TextEdit(wrong: "東經大學", right: "東京大學")], to: "東經大學和大學"), "東京大學和X", "長的先換")
check(TextFixer.apply([], to: "不動"), "不動", "沒有校正就不動")
check(String(TextFixer.parse("好的：```json\n{\"edits\":[{\"wrong\":\"甲\",\"right\":\"乙\"}]}\n```").count), "1", "模型多說話也讀得到")
check(String(TextFixer.parse("我不能處理這個").count), "0", "沒有 JSON 就是沒有")

// 智慧校正：挑詞整理、判定、標註
let pickSource = "夏木漱石和夏日漱石去東經大學，粒線體。"
let picks = TermCheck.clean([
    TermPick(written: ["夏木漱石"], guess: "夏目漱石"),
    TermPick(written: ["夏日漱石", "稿裡沒有"], guess: "夏目漱石"),
    TermPick(written: ["東經大學"], guess: "東京大學"),
    TermPick(written: ["粒線體"], guess: "粒線體"),
    TermPick(written: ["夏木漱石"], guess: ""),
], in: pickSource)
check(picks.map(\.guess).joined(separator: ","), "夏目漱石,東京大學", "同一個猜測併組，沒聽錯的不查")
check(picks[0].written.joined(separator: ","), "夏木漱石,夏日漱石", "只留稿裡有的寫法")
check(String(TermCheck.parse("好的 {\"groups\":[{\"written\":[\"甲\"],\"guess\":\"乙\"}]} 完成").count), "1", "挑詞 JSON 讀得到")
check(TermCheck.judge(guess: "夏目漱石", hits: [WikiHit(title: "夏目漱石", snippet: "")]).status, "found", "標題相同算查到")
check(TermCheck.judge(guess: "東京大學", hits: [WikiHit(title: "东京大学", snippet: "")]).status, "found", "標題簡體也算查到")
check(TermCheck.judge(guess: "芥川龍之介", hits: [WikiHit(title: "菊池寬", snippet: "朋友是芥川龍之介的")]).status, "judge", "只有內文提到要判斷")
check(TermCheck.judge(guess: "芥川龍之介", hits: [WikiHit(title: "菊池寬", snippet: "朋友是<span class=\"searchmatch\">芥川</span><span class=\"searchmatch\">龍之介</span>的")]).status, "judge", "摘要裡的標籤要先拿掉")
check(TermCheck.judge(guess: "亂打", hits: [WikiHit(title: "別的", snippet: "無關")]).status, "none", "搜尋有結果但無關不算")
check(TermCheck.annotate([
    TermNote(written: ["夏木漱石"], right: "夏目漱石", status: "found", url: nil),
    TermNote(written: ["東經大學"], right: "東京大學", status: "judge", url: nil),
    TermNote(written: ["粒線體"], right: "", status: "none", url: nil),
], in: pickSource), "夏木漱石〔夏目漱石〕和夏日漱石去東經大學〔東京大學？〕，粒線體。", "只標註不改字")
check(
    TermCheck.annotate([TermNote(written: ["A", "東經大學"], right: "東京大學", status: "found", url: nil)], in: "A：東經大學"),
    "A：東經大學〔東京大學〕",
    "智慧校正也碰不到講者標籤"
)
check(
    TermCheck.clean([TermPick(written: ["他"], guess: "她"), TermPick(written: ["A"], guess: "東京大學"), TermPick(written: ["東經大學"], guess: "東京大學")], in: "A：他去東經大學").compactMap { $0.written.first }.joined(),
    "東經大學",
    "智慧校正不收單字和標籤"
)

// 定稿中斷不蓋稿：照 App 的順序走一次，假的「最近一次」不能變
func simulateFinal(interrupted: Bool) -> (last: String, shown: String) {
    var finalGuard = FinalGuard<String>()
    var last = "完整的即時稿"     // 按停止時 keepWhatWeHave 存的
    var shown = last
    finalGuard.begin(draft: shown)
    shown = ""                   // beginRun 清空
    shown += "定稿第一段"
    if finalGuard.mayUpdateLast { last = shown }   // append 的 30 秒存檔
    if interrupted {
        if let draft = finalGuard.interrupt() {
            shown = draft
            last = draft
        } else {
            last = shown
        }
    } else {
        shown += "和第二段"
        finalGuard.finish()
        if finalGuard.mayUpdateLast { last = shown }
    }
    return (last, shown)
}
check(simulateFinal(interrupted: true).last, "完整的即時稿", "定稿中途打斷，最近一次還是即時稿")
check(simulateFinal(interrupted: true).shown, "完整的即時稿", "定稿中途打斷，畫面回到即時稿")
check(simulateFinal(interrupted: false).last, "定稿第一段和第二段", "定稿跑完才換掉")
var noDraft = FinalGuard<String>()
noDraft.begin(draft: nil)
check(noDraft.mayUpdateLast ? "可以" : "不行", "可以", "選檔沒有即時稿，存檔照舊")
check(noDraft.interrupt() ?? "沒有", "沒有", "選檔打斷就留已出來的字")

// 分人那一行：載入、計算、背景分開講
check(
    SpeakerReport.line(count: 2, forced: true, wall: 1080, timing: SpeakerTiming(load: 3, segment: 5, embed: 3, cluster: 1), background: 1068),
    "分人：2 人，共 1080 秒（載入 3、切段 5、聲紋 3、分群 1）；其中 1068 秒 App 在背景，切到別的 App 會暫停。指定人數就一定分成這麼多群，其實只有一人講也會被拆。只看聲音，可能分錯",
    "分人秒數拆開"
)
check(SpeakerReport.line(count: 1, forced: false, wall: 8, timing: nil, background: 0), "分人：1 人，共 8 秒。只看聲音，可能分錯", "沒有細項也不崩")

// 送維基前的關卡：下面的姓名都是編的
func gate(_ guess: String, _ written: String, _ text: String = "") -> String {
    PrivacyGate.allows(TermPick(written: [written], guess: guess), transcript: text) ? "送" : "擋"
}
check(gate("夏目漱石", "夏木漱石"), "送", "公開的四字日本名可以查")
check(gate("芥川龍之介", "福利龍之介"), "送", "五字名可以查")
check(gate("東京大學", "東經大學"), "送", "機構可以查")
check(gate("分子生物學", "分子生學"), "送", "學科可以查")
check(gate("理工學部", "禮公"), "送", "長度差 2 可以查")
check(gate("明治維新", "明治圍新"), "送", "歷史名詞可以查")
check(gate("白血球", "白雪球"), "送", "姓氏開頭的醫學詞可以查")
check(gate("高血壓", "高雪壓"), "送", "高血壓可以查")
check(gate("Alzheimer", "Alzheimar"), "送", "單字外文可以查")
check(gate("陳小明", "陳曉明"), "擋", "三字中文姓名不送")
check(gate("王大同", "王大桐"), "擋", "三字中文姓名不送 2")
check(gate("林美", "林梅"), "擋", "兩字姓名不送")
check(gate("阿華", "阿花"), "擋", "綽號不送")
check(gate("小明", "曉明"), "擋", "小開頭不送")
check(gate("歐陽小明", "歐陽曉明"), "擋", "複姓不送")
check(gate("Mary Chen", "Marie Chen"), "擋", "外文全名不送")
check(gate("夏目漱石", "夏木漱石", "我們夏木漱石老師今天請假"), "擋", "緊貼老師不送")
check(gate("東京大學", "東經大學", "我朋友東經大學"), "擋", "緊貼朋友不送")
check(gate("柏安", "伯安"), "送", "已知限制：沒有常見姓氏的兩字名擋不住")
check(gate("今天和朋友吃飯好開心", "今天和朋友吃飯好開"), "送", "已知限制：沒標點的短句擋不住")
check(gate("今天，和朋友吃飯", "今天和朋友吃飯"), "擋", "有標點的句子不送")
check(gate("這段話全部都被模型塞進來送出去了", "這段話"), "擋", "比稿裡的寫法長太多不送")
check(gate(String(repeating: "長", count: 13), String(repeating: "長", count: 12)), "擋", "太長不送")
let gated = PrivacyGate.split([
    TermPick(written: ["夏木漱石"], guess: "夏目漱石"),
    TermPick(written: ["陳曉明"], guess: "陳小明"),
], transcript: "")
check(gated.allowed.map(\.guess).joined(), "夏目漱石", "關卡放行的")
check(gated.held.map(\.guess).joined(), "陳小明", "關卡擋下的")

// 續錄（v0.13）：新的一段接在原稿後面，時間加上前面的長度
let contHead = PartJoin.head(base: "A：第一段講完了。\n\n", part: 2, offset: 3586)
check(contHead, "A：第一段講完了。\n\n——續錄第 2 段，從 59:46 起——\n\n", "續錄分隔行接在原稿後")
let contSplit = PartJoin.split(contHead + "B：新的字。", head: contHead)
check(contSplit.head, contHead, "續錄拆出原稿")
check(contSplit.body, "B：新的字。", "續錄拆出新的那段")
let noHead = PartJoin.split("沒有續錄的稿", head: "")
check("[\(noHead.head)][\(noHead.body)]", "[][沒有續錄的稿]", "沒有續錄就整份")
let badHead = PartJoin.split("被改過的稿", head: contHead)
check("[\(badHead.head)][\(badHead.body)]", "[][被改過的稿]", "對不上原稿就整份當新的，不掉字")
let contMoved = PartJoin.shift([piece("後來", 1, 2), piece("沒時間", -1, -1)], by: 100)
check(contMoved.map { "\($0.start),\($0.end)" }.joined(separator: " "), "101.0,102.0 -1.0,-1.0", "續錄的時間加上前面長度，沒時間的不動")
check(PartJoin.shift([piece("x", 1, 2)], by: 0) == [piece("x", 1, 2)] ? "同" : "不同", "同", "沒有續錄時間不變")
let contTurns = PartJoin.shift([SpeakerTurn(speaker: "S1", start: 0, end: 5)], by: 60, part: 2)
check("\(contTurns[0].speaker) \(contTurns[0].start) \(contTurns[0].end)", "第2段-S1 60.0 65.0", "續錄的分人代號加段號、時間接續")
check(PartJoin.shift([SpeakerTurn(speaker: "S1", start: 0, end: 5)], by: 0, part: nil)[0].speaker, "S1", "沒有續錄代號不變")
check(SpeakerLabeler.label(
    pieces: PartJoin.shift([piece("後來接著講。", 0, 2)], by: 100),
    turns: PartJoin.shift([SpeakerTurn(speaker: "S2", start: 0, end: 3)], by: 100, part: 2)
).text, "A：後來接著講。", "續錄那段自己從 A 開始")
check(PartJoin.merge(["A", "B"], ["A", "C"]).joined(separator: "、"), "A、B、C", "講者合併不重複")
check(PartJoin.merge(nil, ["A"]).joined(separator: "、"), "A", "原本沒分人")
check(PartJoin.note(nil, part: nil, "新") ?? "nil", "新", "一般的說明照舊")
check(PartJoin.note("舊", part: 2, "新") ?? "nil", "舊\n第 2 段：新", "續錄的說明接在後面")
check(PartJoin.note(nil, part: 2, "新") ?? "nil", "第 2 段：新", "原本沒說明")
check(PartJoin.note("舊", part: 2, nil) ?? "nil", "舊", "這段沒有新說明")

// 句子對回錄音時間（v0.14）：點一句播放、點兩下標記
func startsOf(_ map: TranscriptMap) -> String {
    map.sentences.map { $0.start.map { String($0) } ?? "nil" }.joined(separator: " ")
}
let tm1 = TranscriptMap(
    text: "今天講兩件事。第一個是簡化。\n\n第二個是變形。",
    pieces: [piece("今天講兩件事。", 0, 2), piece("第一個是簡化。", 2.5, 4), piece("第二個是變形。", 5, 7)]
)
check(startsOf(tm1), "0.0 2.5 5.0", "一句一個時間")
check(tm1.sentences.map { "\($0.location)+\($0.length)" }.joined(separator: " "), "0+7 7+7 16+7", "句子位置（UTF-16）")
check(tm1.sentence(atUTF16: 8).map { "\($0)" } ?? "nil", "1", "點在第二句")
check(tm1.sentence(atUTF16: 15).map { "\($0)" } ?? "nil", "nil", "點在空行不算")
check(tm1.sentence(atTime: 3).map { "\($0)" } ?? "nil", "1", "播到 3 秒是第二句")
check(tm1.sentence(atTime: 6).map { "\($0)" } ?? "nil", "2", "播到 6 秒是第三句")
check(tm1.sentences(from: 8, to: 17).map { "\($0)" }.joined(separator: ","), "1,2", "筆跡範圍蓋到的句子")
let tm2 = TranscriptMap(
    text: "A：重點是膽識〔膽色？〕。\n\nB：好。",
    pieces: [piece("重點是膽識。", 10, 12), piece("好。", 13, 14)]
)
check(startsOf(tm2), "10.0 13.0", "講者標籤和標註不影響時間，標註裡的？不斷句")
check(tm2.suspects.map { "\($0.label)@\($0.sentence)" }.joined(), "〔膽色？〕@0", "可疑字清單")
let tmHead = PartJoin.head(base: "第一段。", part: 2, offset: 100)
let tm3 = TranscriptMap(text: tmHead + "第二段。", pieces: [piece("第一段。", 0, 3), piece("第二段。", 100, 103)])
check(startsOf(tm3), "0.0 100.0 100.0", "續錄第 2 段的時間接著算，分隔行用第 2 段開頭")
check(tm3.sentences.map { $0.isDivider ? "隔" : "句" }.joined(), "句隔句", "分隔行自己一句")
let tm4 = TranscriptMap(
    text: "一年裡面的事。後來呢。",
    pieces: [piece("一年裏", 0, 1), piece("麵的事。", 1, 2), piece("後來呢。", 5, 6)]
)
check(startsOf(tm4), "0.0 5.0", "跨片段修過的字對得回去，後面的句子不跑掉")
let tmFlat = TranscriptMap(text: "甲句。乙句。", pieces: [piece("甲句。", 0, 1), piece("乙句。", 2, 3)])
let tmSplit = TranscriptMap(text: "甲句。\n\n乙句。", pieces: [piece("甲句。", 0, 1), piece("乙句。", 2, 3)])
check(tmSplit.sentence(containingContent: tmFlat.sentences[1].content).map { "\($0)" } ?? "nil", "1", "分段改了標記還對得到同一句")
check(startsOf(TranscriptMap(text: "沒有時間檔。", pieces: [])), "nil", "沒有時間.json 不崩")
check(startsOf(TranscriptMap(text: "前面。後面。", pieces: [piece("前面。", -1, -1), piece("後面。", 4, 5)])), "4.0 4.0", "沒時間的片段借後面的")
check(startsOf(TranscriptMap(text: "說「好。」然後。", pieces: [piece("說「好。」然後。", 1, 2)])), "1.0 1.0", "句號後的引號留在同一句")

// 照課表命名（v0.14）：前後 10 分鐘內算這堂課（課表是上面的 sampleSettings）
var taipei = Calendar(identifier: .gregorian)
taipei.timeZone = TimeZone(identifier: "Asia/Taipei")!
func classAt(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> String {
    let date = taipei.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    return CourseSchedule.course(at: date, calendar: taipei) ?? "無"
}
check(classAt(2026, 3, 11, 8, 5), "幾何", "週三上課中")
check(classAt(2026, 3, 11, 7, 50), "幾何", "上課前 10 分鐘算")
check(classAt(2026, 3, 11, 7, 49), "無", "上課前 11 分鐘不算")
check(classAt(2026, 3, 11, 10, 0), "幾何", "下課後 10 分鐘算")
check(classAt(2026, 3, 11, 10, 1), "無", "下課後 11 分鐘不算")
check(classAt(2026, 3, 10, 14, 50), "美術", "兩堂一樣近取下一堂")
check(classAt(2026, 3, 10, 14, 45), "桌遊", "離前一堂近取前一堂")
check(classAt(2026, 3, 20, 18, 30), "無", "雙週沒有單週課")
check(classAt(2026, 3, 13, 18, 30), "讀書會", "單週有單週課")
check(classAt(2026, 3, 12, 14, 0), "無", "停課日")
check(classAt(2026, 3, 18, 8, 30), "無", "整天停課（那天的課都不算）")
check(classAt(2026, 3, 15, 10, 30), "無", "週日沒課")
check(classAt(2026, 7, 1, 8, 30), "無", "學期過了課表過期")
check(classAt(2026, 2, 18, 8, 30), "無", "學期還沒開始")
// v0.24：課表改從設定檔讀
do {
    var shifted = sampleSettings()
    shifted.firstDay = "2026-03-02"
    AppSettings.current = shifted
    check(classAt(2026, 3, 13, 18, 30), "無", "設定檔：第幾週從設定檔的 firstDay 算（晚一週開學，同一天變雙週）")
    shifted.firstDay = nil
    AppSettings.current = shifted
    check(classAt(2026, 3, 13, 18, 30), "無", "設定檔：沒有 firstDay 時單週課不排")
    check(classAt(2026, 3, 11, 8, 5), "幾何", "設定檔：沒有 firstDay 時每週的課照排")
    shifted.toleranceMinutes = 5
    AppSettings.current = shifted
    check(classAt(2026, 3, 11, 7, 50), "無", "設定檔：前後幾分鐘照設定檔")
    AppSettings.current = AppSettings()
    check(classAt(2026, 3, 11, 8, 5), "無", "設定檔：沒有設定檔就沒有課表（用時間命名）")
    check(CourseSchedule.formalName("幾何"), "幾何", "設定檔：沒有設定檔時課名照原樣")
    check(LiveFix.rules(course: "解析幾何").count == LiveFix.common.count ? "只有通用" : "有課程表", "只有通用", "設定檔：沒有設定檔就沒有課程對照表")
    check(CourseProfile.allowsUpload(course: "幾何") ? "送" : "不送", "不送", "設定檔：沒有設定檔時哪門課都不送 Haiku")
    AppSettings.current = sampleSettings()
    check(LiveFix.byCourse["解析幾何"]?.count.description ?? "nil", "8", "設定檔：對照表換成規則")

    let good = #"{"firstDay":"2026-09-07","courses":[{"name":"甲","weekday":1,"from":"08:10","to":"09:00","private":true}],"liveFix":{"甲":[["錯","對"]]}}"#
    let parsed = try? AppSettings.decode(Data(good.utf8))
    check(parsed.map { "\($0.courses.count) \($0.courses[0].isPrivate) \($0.toleranceMinutes) \($0.liveFix["甲"]?.count ?? 0)" } ?? "讀不開",
          "1 true 10 1", "設定檔：讀得開、private 欄位、沒寫的用預設")
    func problem(_ json: String) -> String {
        do { _ = try AppSettings.decode(Data(json.utf8)); return "收了" } catch { return error.localizedDescription }
    }
    check(problem(#"{"courses":[{"name":"甲","weekday":8,"from":"08:10","to":"09:00"}]}"#), "設定檔有錯：courses 第 1 筆 的 weekday 要是 1–7", "設定檔：星期不對不收")
    check(problem(#"{"courses":[{"name":"甲","weekday":1,"from":"8:10","to":"09:00"}]}"#), "設定檔有錯：courses 第 1 筆 的時間要寫成 HH:mm", "設定檔：時間格式不對不收")
    check(problem(#"{"courses":[{"name":" ","weekday":1,"from":"08:10","to":"09:00"}]}"#), "設定檔有錯：courses 第 1 筆 沒有課名", "設定檔：沒有課名不收")
    check(problem(#"{"firstDay":"2026/09/07"}"#), "設定檔有錯：日期「2026/09/07」要寫成 yyyy-MM-dd", "設定檔：日期格式不對不收")
    check(problem(#"{"liveFix":{"甲":[["只有一個"]]}}"#), "設定檔有錯：對照表「甲」有一條不是 [錯字, 正確]", "設定檔：對照表一條不是兩個字不收")
    check(problem("不是 JSON").hasPrefix("設定檔讀不懂") ? "不收" : "收了", "不收", "設定檔：不是 JSON 不收")

    // 真的寫進暫存資料夾：沒有檔、壞檔、好檔
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shape_check_settings_\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    check(AppSettings.reload(root: root).line, "設定檔：沒有（不照課表命名、沒有課程對照表）", "設定檔：沒有檔")
    check(AppSettings.current == AppSettings() ? "空的" : "不是空的", "空的", "設定檔：沒有檔就是空的設定")
    check((try? AppSettings.install(Data(good.utf8), root: root))?.line ?? "存不了", "設定檔：課表 1 筆、課程對照表 1 條", "設定檔：匯入檢查過就存")
    check(AppSettings.url(root: root).path.hasSuffix("設定/轉文字設定.json") ? "對" : AppSettings.url(root: root).path, "對", "設定檔：存在 Documents/設定/轉文字設定.json")
    check((try? AppSettings.install(Data("{\"courses\":[{}]}".utf8), root: root)) == nil ? "不收" : "收了", "不收", "設定檔：壞的匯入不收")
    check(AppSettings.reload(root: root).line, "設定檔：課表 1 筆、課程對照表 1 條", "設定檔：壞的匯入不蓋掉原本的檔")
    try? Data("{壞掉".utf8).write(to: AppSettings.url(root: root))
    check(AppSettings.reload(root: root).line.hasPrefix("設定檔：沒有套用") ? "沒套用" : "套用了", "沒套用", "設定檔：檔壞了不套用")
    check(AppSettings.current == AppSettings() ? "空的" : "不是空的", "空的", "設定檔：檔壞了不沿用上一次的")
    AppSettings.current = sampleSettings()
}
check(CourseSchedule.title(stamp: "20261110-102000", course: "幾何"), "11/10 幾何", "標題：月/日 課名")
check(CourseSchedule.title(stamp: "20261108-170512", course: nil), "11/8 17:05", "不在上課時段用時間")
check(CourseSchedule.folderName("a/b:c"), "abc", "資料夾名拿掉不能用的字")

// v0.14.1 選檔定稿：照 Model.transcribe 選檔那條路走一次（不分人、不校正），每一步都不能閃退、結果要對
// v0.14.16 在這裡閃退（run?.liveInfo = PartJoin.note(run?.liveInfo, …) 同時讀寫 run）；那是 Model.swift 的寫法，
// 由 build.yml 的「同時讀寫」檢查擋，這裡驗這條路上 TextShaping 的部分。
do {
    var finalBuilder = LineBuilder()
    let segments: [[TimedPiece]] = [
        [piece("今天", 0.2, 0.6), piece("我們講", 0.6, 1.2), piece("積分。", 1.2, 1.8)],
        [piece("沒有時間的字", -1, -1), piece("？", -1, -1)],
        [piece("最後", 150.0, 150.5), piece("一句！", 150.5, 155.0)],
    ]
    var allPieces: [TimedPiece] = []
    for segment in segments {
        let shifted = PartJoin.shift(segment, by: 0)
        allPieces += shifted
        finalBuilder.add(shifted)
    }
    let finalText = "" + finalBuilder.text
    check(finalText.isEmpty ? "空" : "有字", "有字", "選檔定稿：有出字")
    check(PartJoin.split(finalText, head: "").body, finalText, "選檔定稿：沒有續錄時整份都是新的")
    check(PartJoin.note(nil, part: nil, nil) ?? "nil", "nil", "選檔定稿：沒有錄音資訊時 liveInfo 留空")
    check(PartJoin.note("舊", part: nil, nil) ?? "nil", "舊", "選檔定稿：沒有新資訊時留舊的")
    check(formatStamp(155), "02:35", "選檔定稿：稿頭時長")
    check(formatStamp(.nan), "?", "選檔定稿：時長不是數字不閃退")
    check(formatStamp(.infinity), "?", "選檔定稿：時長無限大不閃退")
    let finalMap = TranscriptMap(text: finalText, pieces: allPieces)
    check(finalMap.sentences.isEmpty ? "沒有句子" : "有句子", "有句子", "選檔定稿：切得出句子")
    check(finalMap.utf16Count == finalText.utf16.count ? "對" : "錯", "對", "選檔定稿：句子表和稿一樣長")
    let inRange = finalMap.sentences.allSatisfy { $0.location >= 0 && $0.end <= finalText.utf16.count }
    check(inRange ? "都在稿內" : "超出", "都在稿內", "選檔定稿：每句的位置都在稿內")
    let lookups = [finalMap.sentence(atTime: -5), finalMap.sentence(atTime: 1e9), finalMap.sentence(containingContent: 1_000_000),
                   finalMap.sentence(atUTF16: 1_000_000), finalMap.sentence(atUTF16: -1)]
    let safe = lookups.allSatisfy { found in found.map { $0 >= 0 && $0 < finalMap.sentences.count } ?? true }
    check(safe ? "安全" : "越界", "安全", "選檔定稿：極端位置查句子不越界")
    // 時間.json 是空的、稿是空的、時間比字多：都不能閃退
    let noPieces = TranscriptMap(text: finalText, pieces: [])
    check(noPieces.sentences.count == finalMap.sentences.count ? "一樣" : "不一樣", "一樣", "選檔定稿：沒有時間.json 也切句")
    let emptyMap = TranscriptMap(text: "", pieces: allPieces)
    check("\(emptyMap.sentences.count)", "0", "選檔定稿：空稿沒有句子")
    check(emptyMap.sentence(atTime: 3).map(String.init) ?? "nil", "nil", "選檔定稿：空稿查時間不閃退")
}

// v0.15 連電腦：照電腦版的手機收音協定（v1）。網路、相機、麥克風要真機；這裡驗解析 QR、包的格式、時間戳、斷線留 3 秒、重試、讀訊息
do {
    let fp = String(repeating: "0123456789abcdef", count: 4)
    let good = "https://192.168.1.20:8793/?k=abc_DEF-123&fp=\(fp)"
    switch LinkTarget.parse(good) {
    case .success(let t):
        check("\(t.host)|\(t.port)|\(t.key)|\(t.fp == fp)", "192.168.1.20|8793|abc_DEF-123|true", "連電腦：解析 QR 碼")
        check(t.micURL(device: "iPhone")?.absoluteString ?? "nil",
              "wss://192.168.1.20:8793/mic?k=abc_DEF-123&client=app&device=iPhone", "連電腦：收音通道網址")
        check(t.accepts(fingerprint: fp.uppercased()) ? "收" : "拒", "收", "連電腦：指紋一樣（大寫）就收")
        check(t.accepts(fingerprint: String(repeating: "f", count: 64)) ? "收" : "拒", "拒", "連電腦：指紋不一樣就拒")
        check(t.accepts(fingerprint: "") ? "收" : "拒", "拒", "連電腦：沒有指紋就拒")
        check(t.label, "192.168.1.20:8793", "連電腦：畫面不顯示配對碼")
    case .failure(let e):
        check("失敗 \(e)", "成功", "連電腦：解析 QR 碼")
    }
    func parseError(_ text: String) -> String {
        switch LinkTarget.parse(text) {
        case .success: return "成功"
        case .failure(let e): return "\(e)"
        }
    }
    let colon = stride(from: 0, to: 64, by: 2).map { i -> String in
        let s = fp.index(fp.startIndex, offsetBy: i)
        return String(fp[s..<fp.index(s, offsetBy: 2)]).uppercased()
    }.joined(separator: ":")
    check(parseError("https://10.0.0.5:8793/?k=x&fp=\(colon)"), "成功", "連電腦：冒號大寫的指紋也收")
    check(parseError("https://10.0.0.5:8793/?fp=\(fp)"), "noKey", "連電腦：沒有配對碼")
    check(parseError("https://10.0.0.5:8793/?k=x"), "noFingerprint", "連電腦：舊版電腦沒有指紋")
    check(parseError("https://10.0.0.5:8793/?k=x&fp=\(fp.dropLast())"), "badFingerprint", "連電腦：指紋少一個字")
    check(parseError("http://10.0.0.5:8793/?k=x&fp=\(fp)"), "notLink", "連電腦：不是 https 不收")
    check(parseError("隨便一段字"), "notLink", "連電腦：不是網址")
    if case .success(let t) = LinkTarget.parse("https://10.0.0.5/?k=x&fp=\(fp)") {
        check("\(t.port)", "8793", "連電腦：沒寫埠用 8793")
    }

    // 包的格式（小端）：TPA1、序號、時間戳、取樣數、旗標、int16
    let frame = LinkFrame(seq: 7, timestampUs: 1_234_567_890_123, samples: [0x0102, -2] + Array(repeating: 0, count: 1598), flags: 1)
    let bytes = frame.data
    check("\(bytes.count)", "\(24 + 1600 * 2)", "連電腦：一包 24 位元組頭＋1600 取樣")
    if let h = LinkFrame.header(of: bytes) {
        check("\(h.magic)|\(h.seq)|\(h.timestampUs)|\(h.count)|\(h.flags)", "TPA1|7|1234567890123|1600|1", "連電腦：包頭")
    }
    let raw = [UInt8](bytes)
    check("\(raw[24]) \(raw[25]) \(raw[26]) \(raw[27])", "2 1 254 255", "連電腦：聲音是小端 int16")

    // 時間戳：用取樣數算，起點＝現在 − 這批長度 − 輸入延遲
    var stamper = LinkStamper()
    let one = Array(repeating: Int16(100), count: 1600)
    let f1 = stamper.feed(one, nowUs: 1_000_000, latencyUs: 20_000)
    check(f1.map { "\($0.seq)/\($0.timestampUs)/\($0.flags)" }.joined(separator: ","), "0/880000/1", "連電腦：第一包起點、旗標 bit0")
    let f2 = stamper.feed(one, nowUs: 1_100_000, latencyUs: 20_000)
    check(f2.map { "\($0.seq)/\($0.timestampUs)/\($0.flags)" }.joined(separator: ","), "1/980000/0", "連電腦：第二包接著 100 毫秒")
    let half = Array(repeating: Int16(0), count: 800)
    let f3 = stamper.feed(half, nowUs: 1_150_000, latencyUs: 20_000)
    let f4 = stamper.feed(half, nowUs: 1_200_000, latencyUs: 20_000)
    check("\(f3.count) \(f4.map { "\($0.seq)/\($0.timestampUs)" }.joined())", "0 2/1080000", "連電腦：半批湊滿 100 毫秒才送")
    let f5 = stamper.feed(one, nowUs: 3_000_000, latencyUs: 20_000)
    check(f5.map { "\($0.seq)/\($0.timestampUs)/\($0.flags)" }.joined(separator: ","), "3/2880000/1", "連電腦：停了 1.7 秒重設起點、序號接著數")
    let f6 = stamper.feed(one, nowUs: 3_250_000, latencyUs: 20_000)
    check(f6.map { "\($0.timestampUs)/\($0.flags)" }.joined(separator: ","), "2980000/0", "連電腦：晚到 0.15 秒不重設（0.2 秒以內）")
    stamper.reset()
    let f7 = stamper.feed(one, nowUs: 3_400_000, latencyUs: 0)
    check(f7.map { "\($0.seq)/\($0.flags)" }.joined(separator: ","), "5/1", "連電腦：被打斷後重設、旗標 bit0、序號不歸零")
    // 48 kHz 裝置：每批 4096 取樣≈1365 個 16 kHz 取樣、85.3 毫秒，包和包的時間要剛好差 100 毫秒
    var steady = LinkStamper()
    var frames: [LinkFrame] = []
    var now: Int64 = 10_000_000
    for i in 0..<60 {
        let n = i % 3 == 0 ? 1366 : 1365
        now += Int64(n) * 1_000_000 / 16_000
        frames += steady.feed(Array(repeating: Int16(1), count: n), nowUs: now, latencyUs: 15_000)
    }
    let gaps = Set(zip(frames.dropFirst(), frames).map { $0.timestampUs - $1.timestampUs })
    check("\(gaps.sorted())|\(frames.filter { $0.flags == 1 }.count)", "[100000]|1", "連電腦：48 kHz 批次切出來的包時間連續")
    check(frames.allSatisfy { $0.samples.count == 1600 } ? "都 1600" : "有不一樣", "都 1600", "連電腦：每包 100 毫秒")

    // 斷線時留最近 3 秒
    var backlog = LinkBacklog(holdUs: 3_000_000)
    for i in 0..<50 {
        backlog.push(Data([UInt8(i)]), samples: 1600, at: Int64(i) * 100_000)
    }
    let kept = backlog.drain(now: 4_900_000)
    check("\(kept.count) \(kept.first.map { "\($0[0])" } ?? "-")", "31 19", "連電腦：只留最近 3 秒、照順序")
    let dropped = backlog.takeDropped()
    check("\(dropped) \(backlog.takeDropped())", "\(19 * 1600) 0", "連電腦：被擠掉的取樣數，拿了歸零")
    check(LinkText.lost(samples: dropped), "少了約 1.9 秒", "連電腦：報少了幾秒")
    check(LinkText.lost(samples: 0), "沒有少", "連電腦：沒少")

    check([0, 1, 2, 3, 4, 5, 9].map { "\(Int(LinkRetry.delay(attempt: $0)))" }.joined(separator: ","), "1,1,2,3,4,4,4", "連電腦：重連 1、2、3、4 秒，最多 4 秒")

    // 電腦送來的訊息
    func incoming(_ text: String) -> String { "\(LinkIncoming.parse(text))" }
    check(incoming(#"{"type":"welcome","v":1,"rate":16000,"hold_ms":3000,"recording":true,"use":"split"}"#), "welcome(recording: true, version: 1, text: false)", "連電腦：welcome（v1 的電腦）")
    check(incoming(#"{"type":"pong","t1":1234567890123,"t2":987654321}"#), "pong(t1: 1234567890123, t2: 987654321)", "連電腦：pong 大數字不失真")
    check(incoming(#"{"type":"state","recording":false,"use":null,"message":"電腦這邊關掉了手機收音"}"#),
          "state(recording: false, pcOff: true, message: Optional(\"電腦這邊關掉了手機收音\"))", "連電腦：電腦按「不用手機收音」")
    check(incoming(#"{"type":"state","recording":false,"use":null}"#), "state(recording: false, pcOff: false, message: nil)", "連電腦：錄完沒 message 不算關掉")
    check(incoming(#"{"type":"state","recording":true,"use":"only","track":"room"}"#), "state(recording: true, pcOff: false, message: nil)", "連電腦：開始錄")
    check(incoming(#"{"type":"replaced","message":"另一支手機接手收音了"}"#), "replaced(\"另一支手機接手收音了\")", "連電腦：被取代")
    check(incoming("不是 JSON"), "other", "連電腦：看不懂的不閃退")

    // 手機送出的訊息
    let hello = LinkOutgoing.hello(use: .split, device: "iPhone").text
    let helloOK = ["\"type\":\"hello\"", "\"v\":\(LinkOutgoing.version)", "\"client\":\"app\"", "\"use\":\"split\"", "\"rate\":16000", "\"frame_ms\":100", "\"device\":\"iPhone\""].allSatisfy { hello.contains($0) }
    check(helloOK ? "齊" : hello, "齊", "連電腦：hello 欄位")
    let syncText = LinkOutgoing.sync(t1: 1_234_567_890_123, t2: 42, t3: 1_234_567_990_123).text
    let syncBack = (try? JSONSerialization.jsonObject(with: Data(syncText.utf8))) as? [String: Any]
    check("\((syncBack?["t1"] as? NSNumber)?.int64Value ?? 0)", "1234567890123", "連電腦：sync 時間照抄不變")
    check(LinkOutgoing.off.text, #"{"type":"off"}"#, "連電腦：off")

    // 音量條
    check(String(format: "%.2f", LinkLevel.meter(Array(repeating: 0, count: 1600))), "0.00", "連電腦：沒聲音音量 0")
    check(String(format: "%.2f", LinkLevel.meter(Array(repeating: 32767, count: 1600))), "1.00", "連電腦：最大聲音量 1")
    check(String(format: "%.2f", LinkLevel.meter(Array(repeating: 3277, count: 1600))), "0.67", "連電腦：-20 dB 約三分之二")
}

// v0.16 連電腦看電腦的稿：照電腦版的手機收音協定（v3 第 6 節）。訊息的樣子照電腦版 v5.27 的測試程式收到的
do {
    func incoming(_ text: String) -> LinkIncoming { LinkIncoming.parse(text) }
    check("\(incoming(#"{"type":"welcome","v":3,"text":true,"rate":16000,"early_ms":10000,"hold_ms":3000,"recording":false,"use":null}"#))",
          "welcome(recording: false, version: 3, text: true)", "電腦稿：v3 的電腦會送稿")
    check("\(incoming(#"{"type":"welcome","v":2,"rate":16000,"recording":true,"use":"split"}"#))",
          "welcome(recording: true, version: 2, text: false)", "電腦稿：v2 的電腦不送稿（要提示更新）")
    check("\(incoming(#"{"type":"welcome","v":3,"text":false,"recording":false}"#))",
          "welcome(recording: false, version: 3, text: false)", "電腦稿：v3 但說不送就不送")
    check("\(incoming(#"{"type":"gap","lost_sec":1.0,"from":1.0,"to":2.0,"total_sec":3.5,"message":"手機收音接上了"}"#))",
          "gap(lostSec: 1.0, totalSec: 3.5, message: \"手機收音接上了\")", "電腦稿：v2 的 gap（少幾秒以電腦為準）")
    // v0.20：v0.19 把協定升到 v5 時這兩項還寫死 v4，雲端編譯（build 22）卡在這裡沒編到；改成跟著 LinkOutgoing.version
    check(LinkOutgoing.hello(use: .only, device: "iPad").text.contains("\"v\":\(LinkOutgoing.version)") && LinkOutgoing.version >= 4 ? "v4 以上" : "不是", "v4 以上", "電腦稿：hello 送 v≥4（要電腦的稿和 Claude 對話；v3 以上的電腦都送稿）")
    check("\(incoming(#"{"type":"text_add","line":{"id":"x"}}"#))", "other", "電腦稿：行的 id 不是數字就略過，不閃退")
    check("\(incoming(#"{"type":"text_new_kind","x":1}"#))", "other", "電腦稿：看不懂的 type 略過")

    func apply(_ pc: inout PCTranscript, _ text: String) {
        if case .text(let message) = LinkIncoming.parse(text) {
            pc.apply(message)
        }
    }
    var pc = PCTranscript()
    check(pc.canSave ? "能存" : "不能", "不能", "電腦稿：還沒收到不能存")
    // 錄音中連上：整份＋灰字
    apply(&pc, #"{"type":"text_all","session":"2026-11-08_153000","started":"2026-11-08T15:30:00","rec":"recording","eta":null,"stage":"live","mode":"face","names":null,"lines":[{"id":1,"track":"room","who":"","start":3.0,"end":4.5,"stamp":"00:03","text":"先複習上次的內容"},{"id":0,"track":"room","who":"","start":1.0,"end":2.5,"stamp":"00:01","text":"今天我們來講第三張。"}],"drafts":[{"track":"room","text":"正在講","start":5.0}],"omitted":0,"max_lines":2000}"#)
    check(pc.finalText, "今天我們來講第三張。先複習上次的內容", "電腦稿：整份照時間排、同一個人沒停久接在同一段、現場不寫講者")
    check(pc.volatileText, "正在講", "電腦稿：灰字接在後面")
    check("\(pc.rec) \(pc.stamp ?? "-")", "recording 20261108-153000", "電腦稿：錄音中、這場的時間")
    check(pc.canSave ? "能存" : "不能", "不能", "電腦稿：錄音中不能存")
    // 增量：新黑字、灰字清掉、同一個 id 再來不重複、刪句、停很久另起一段
    apply(&pc, #"{"type":"text_draft","track":"room","text":"","start":null}"#)
    apply(&pc, #"{"type":"text_add","line":{"id":2,"track":"room","who":"","start":5.0,"end":6.0,"stamp":"00:05","text":"正在講的這句"},"stage":"live"}"#)
    apply(&pc, #"{"type":"text_add","line":{"id":2,"track":"room","who":"","start":5.0,"end":6.0,"stamp":"00:05","text":"正在講的這句"},"stage":"live"}"#)
    check("\(pc.lines.count) \(pc.volatileText.isEmpty)", "3 true", "電腦稿：同一個 id 再來不會多一行、灰字清掉")
    apply(&pc, #"{"type":"text_add","line":{"id":3,"track":"room","who":"","start":20.0,"end":21.0,"stamp":"00:20","text":"停很久之後"},"stage":"live"}"#)
    apply(&pc, #"{"type":"text_del","id":1}"#)
    check(pc.finalText, "今天我們來講第三張。\n\n正在講的這句\n\n停很久之後","電腦稿：刪句、停超過 1.5 秒另起一段")
    // 後到的較早一句（兩軌輪流轉）照時間插進去
    apply(&pc, #"{"type":"text_add","line":{"id":4,"track":"room","who":"","start":0.2,"end":0.8,"stamp":"00:00","text":"好，"},"stage":"live"}"#)
    check(String(pc.finalText.prefix(12)), "好，今天我們來講第三張。", "電腦稿：後到的較早一句照時間插進去")
    // 斷線重連：整份換掉，不重複
    apply(&pc, #"{"type":"text_all","session":"2026-11-08_153000","started":"2026-11-08T15:30:00","rec":"recording","stage":"live","mode":"face","names":null,"lines":[{"id":0,"track":"room","who":"","start":1.0,"end":2.5,"stamp":"00:01","text":"今天我們來講第三張。"},{"id":5,"track":"room","who":"","start":30.0,"end":31.0,"stamp":"00:30","text":"斷線時講的"}],"drafts":[],"omitted":0,"max_lines":2000}"#)
    check("\(pc.lines.map { "\($0.id)" }.joined(separator: ","))", "0,5", "電腦稿：重連的整份整個換掉（不會跟舊的疊在一起）")
    // 按結束：整理中、灰字清掉；分好人：講者
    apply(&pc, #"{"type":"text_draft","track":"room","text":"最後一句","start":32.0}"#)
    apply(&pc, #"{"type":"rec","rec":"processing","eta":42,"session":"2026-11-08_153000","started":"2026-11-08T15:30:00"}"#)
    check("\(pc.rec) \(pc.eta ?? 0) \(pc.drafts.count) \(pc.canSave)", "processing 42.0 0 false", "電腦稿：整理中帶預估秒數、灰字清掉、還不能存")
    apply(&pc, #"{"type":"text_all","session":"2026-11-08_153000","started":"2026-11-08T15:30:00","rec":"processing","stage":"labelled","mode":"face","names":{"A":"老師","B":"學生"},"lines":[{"id":0,"track":"A","who":"老師","start":1.0,"end":2.5,"stamp":"00:01","text":"今天我們來講第三章。"},{"id":1,"track":"B","who":"學生","start":3.0,"end":4.5,"stamp":"00:03","text":"好"},{"id":2,"track":"A","who":"老師","start":5.0,"end":6.0,"stamp":"00:05","text":"先複習"}],"drafts":[],"omitted":0,"max_lines":2000}"#)
    check(pc.finalText, "老師：今天我們來講第三章。\n\n學生：好\n\n老師：先複習", "電腦稿：分好人後每段前面寫講者")
    apply(&pc, #"{"type":"rec","rec":"idle","eta":null,"session":"2026-11-08_153000","started":"2026-11-08T15:30:00"}"#)
    check(pc.canSave ? "能存" : "不能", "能存", "電腦稿：分好人、回閒置才能存")
    check(pc.speakers.joined(separator: "、"), "老師、學生", "電腦稿：講者照出現順序")
    check(CourseSchedule.title(stamp: pc.stamp ?? "", course: nil), "11/8 15:30", "電腦稿：存成一場的標題照 App 錄音的規則（時間）")
    check(CourseSchedule.title(stamp: pc.stamp ?? "", course: "幾何"), "11/8 幾何", "電腦稿：上課時段照課表命名")
    check(String(format: "%.1f", pc.seconds), "6.0", "電腦稿：長度＝最後一句結束")
    // 分軌：我／對方，灰字接得上才接
    var split = PCTranscript()
    apply(&split, #"{"type":"text_all","session":"2026-11-08_160000","rec":"recording","stage":"live","mode":"online","names":null,"lines":[{"id":0,"track":"me","who":"我","start":1.0,"end":1.5,"text":"你好"},{"id":1,"track":"other","who":"對方","start":2.0,"end":2.5,"text":"嗨"}],"drafts":[{"track":"me","text":"今天","start":3.0}],"omitted":0}"#)
    check(split.finalText + "|" + split.volatileText, "我：你好\n\n對方：嗨|\n\n我：今天", "電腦稿：分軌換人換段、灰字換人也換段")
    apply(&split, #"{"type":"text_all","session":"2026-11-08_160000","rec":"idle","stage":"final","mode":"online","names":null,"lines":[{"id":0,"track":"me","who":"我","start":1.0,"end":1.5,"text":"你好"}],"drafts":[],"omitted":3}"#)
    check("\(split.canSave) \(split.originNote.contains("最前面 3 句"))", "true true", "電腦稿：定稿也能存；太長拿掉的寫進來源")
    // 沒錄過：session 是 null，不能存
    var empty = PCTranscript()
    apply(&empty, #"{"type":"text_all","session":null,"started":null,"rec":"idle","eta":null,"stage":null,"mode":"face","names":null,"lines":[],"drafts":[],"omitted":0,"max_lines":2000}"#)
    check("\(empty.received) \(empty.isEmpty) \(empty.canSave)", "true true false", "電腦稿：還沒錄過的電腦：收到空的一份、不能存")
    check(PCTranscript.stamp(fromSession: "../etc") ?? "不收", "不收", "電腦稿：場次代號不是日期時間就不收")
    // 段落太長要換段（跟 App 分段差不多）
    let longLine = String(repeating: "長", count: 120) + "。"
    var long = PCTranscript()
    apply(&long, "{\"type\":\"text_all\",\"session\":\"2026-11-08_170000\",\"rec\":\"recording\",\"stage\":\"live\",\"lines\":[{\"id\":0,\"track\":\"room\",\"who\":\"\",\"start\":0,\"end\":1,\"text\":\"\(longLine)\"},{\"id\":1,\"track\":\"room\",\"who\":\"\",\"start\":1.2,\"end\":2,\"text\":\"下一句\"}],\"drafts\":[],\"omitted\":0}")
    check(long.finalText.hasSuffix("。\n\n下一句") ? "換段" : long.finalText, "換段", "電腦稿：段落夠長又講完一句就換段")
}

// v0.17 連電腦看 Claude 的回覆：照電腦版的手機收音協定（v4 第 7 節）。訊息的樣子照電腦版 v5.29 的測試程式收到的
do {
    func chatMessage(_ text: String) -> PCChatMessage? {
        if case .chat(let message) = LinkIncoming.parse(text) { return message }
        return nil
    }
    func apply(_ chat: inout PCChat, _ text: String) {
        if let message = chatMessage(text) {
            chat.apply(message)
        }
    }
    check(PCChat.supported(version: 4, chat: true) ? "送" : "不送", "送", "Claude 對話：v4 的電腦會送")
    check(PCChat.supported(version: 3, chat: true) ? "送" : "不送", "不送", "Claude 對話：v3 的電腦（v5.27–v5.28）不送（要提示更新）")
    check(PCChat.supported(version: 4, chat: false) ? "送" : "不送", "不送", "Claude 對話：v4 但說不送就不送")
    check("\(LinkIncoming.parse(#"{"type":"welcome","v":4,"text":true,"chat":true,"tts":true,"rate":16000,"early_ms":10000,"hold_ms":3000,"recording":false,"use":null}"#))",
          "welcome(recording: false, version: 4, text: true)", "Claude 對話：v4 的 welcome 照舊讀得到稿")
    check(chatMessage(#"{"type":"chat_add","item":{"id":1,"role":"other","text":"x"}}"#) == nil ? "略過" : "收了", "略過", "Claude 對話：看不懂的 role 略過")
    check(chatMessage(#"{"type":"chat_add","item":{"id":"x","role":"me","text":"x"}}"#) == nil ? "略過" : "收了", "略過", "Claude 對話：id 不是數字略過，不閃退")
    check("\(LinkIncoming.parse(#"{"type":"chat_new_kind","id":1}"#))", "other", "Claude 對話：看不懂的 type 略過")

    var chat = PCChat()
    apply(&chat, #"{"type":"chat_all","items":[],"thinking":null,"omitted":0,"max_items":50}"#)
    check("\(chat.received) \(chat.items.count) \(chat.preview.hasPrefix("還沒叫 Claude"))", "true 0 true", "Claude 對話：連上先收空的一份，底部寫怎麼叫")
    // 打字 @claude → 正在想 → 想完 → 回覆（電腦實際送的順序）
    apply(&chat, #"{"type":"chat_add","item":{"id":2,"role":"me","text":"@claude 第三章講什麼","start":null,"stamp":"","heard":false,"to_claude":true,"route":"chat","connected":true}}"#)
    apply(&chat, #"{"type":"chat_think","id":2,"on":true,"route":"chat"}"#)
    check("\(chat.thinking ?? -1) \(chat.thinkingText) \(chat.preview)", "2 Claude 正在想… 你：@claude 第三章講什麼", "Claude 對話：他打的那則、正在想")
    check(chat.items[0].caption, "打字問 Claude", "Claude 對話：打字的小字")
    apply(&chat, #"{"type":"chat_think","id":2,"on":false}"#)
    apply(&chat, #"{"type":"chat_add","item":{"id":3,"role":"claude","text":"第三章講的是熱力學。","start":null,"stamp":"","heard":false,"to_claude":false,"model":"claude-sonnet-5-5","carry":"最近幾句"}}"#)
    check("\(chat.thinking == nil) \(chat.newReplies) \(chat.lastNewReply?.text ?? "-") \(chat.preview)", "true 1 第三章講的是熱力學。 第三章講的是熱力學。", "Claude 對話：回覆來了算一則新回覆、底部寫回覆")
    check(chat.items[1].caption, "Sonnet 5.5 · 帶稿：最近幾句", "Claude 對話：回覆的小字（模型名跟電腦網頁一樣）")
    // 同一個 id 再來一次：換掉、不算新回覆
    apply(&chat, #"{"type":"chat_add","item":{"id":3,"role":"claude","text":"第三章講的是熱力學。","model":"claude-sonnet-5-5"}}"#)
    check("\(chat.items.count) \(chat.newReplies)", "2 1", "Claude 對話：同一個 id 換掉不多一則、不再念一次")
    // Hey Claude＋講完才併進來的字
    apply(&chat, #"{"type":"chat_add","item":{"id":4,"role":"heard","text":"嘿 Claude","start":12.3,"stamp":"00:12","heard":true,"to_claude":true,"connected":true}}"#)
    apply(&chat, #"{"type":"chat_text","id":4,"text":"嘿 Claude 熱力學第二定律是什麼"}"#)
    check("\(chat.items.last?.text ?? "-")|\(chat.items.last?.caption ?? "-")", "嘿 Claude 熱力學第二定律是什麼|叫 Claude · 00:12", "Claude 對話：喊 Hey Claude 的泡泡、後面講的併進來")
    // 工作視窗：正在想（工作視窗在想）；直接來回覆也算想完
    apply(&chat, #"{"type":"chat_think","id":4,"on":true,"route":"window"}"#)
    check(chat.thinkingText, "工作視窗在想…", "Claude 對話：工作視窗拿走")
    apply(&chat, #"{"type":"chat_add","item":{"id":5,"role":"claude","text":"查好了：第二定律說熵不會減少。","carry":"全部"}}"#)
    check("\(chat.thinking == nil) \(chat.newReplies) \(chat.items.last?.caption ?? "-")", "true 2 工作視窗 · 帶稿：全部", "Claude 對話：工作視窗的回覆（沒有模型名）")
    // 沒回成
    apply(&chat, #"{"type":"chat_add","item":{"id":6,"role":"me","text":"@claude 會出錯的問題","to_claude":true,"connected":false}}"#)
    apply(&chat, #"{"type":"chat_think","id":6,"on":true,"route":"chat"}"#)
    apply(&chat, #"{"type":"chat_fail","id":6,"message":"Claude 沒回成：假的錯誤"}"#)
    check("\(chat.thinking == nil) \(chat.fails[6] ?? "-") \(chat.preview)", "true Claude 沒回成：假的錯誤 沒回成：Claude 沒回成：假的錯誤", "Claude 對話：沒回成記在那則下面、正在想關掉")
    check(chat.items.last?.caption ?? "-", "打字問 Claude · Claude 還沒連線，訊息先留著", "Claude 對話：Claude 沒連線的小字")
    // 重連：整份換掉，正在想照整份；不算新回覆
    apply(&chat, #"{"type":"chat_all","items":[{"id":3,"role":"claude","text":"第三章講的是熱力學。"},{"id":7,"role":"claude","text":"斷線時回的"}],"thinking":8,"omitted":12,"max_items":50}"#)
    check("\(chat.items.map { "\($0.id)" }.joined(separator: ",")) \(chat.thinking ?? -1) \(chat.omitted) \(chat.newReplies) \(chat.fails.isEmpty)", "3,7 8 12 2 true",
          "Claude 對話：重連整份換掉（斷線時的回覆在、不重複、不再念）、正在想照整份")
    // 換一場：電腦清掉
    apply(&chat, #"{"type":"chat_all","items":[],"thinking":null,"omitted":0,"max_items":50}"#)
    check("\(chat.items.count) \(chat.thinking == nil)", "0 true", "Claude 對話：換一場清掉")
    // 手機最多留 200 則
    var many = PCChat()
    for i in 0..<230 {
        apply(&many, "{\"type\":\"chat_add\",\"item\":{\"id\":\(i),\"role\":\"me\",\"text\":\"第\(i)則\"}}")
    }
    check("\(many.items.count) \(many.items.first?.id ?? -1) \(many.omitted)", "200 30 30", "Claude 對話：手機最多留 200 則，舊的拿掉")

    // 念回覆的時段（tts）
    let ttsOn = LinkOutgoing.tts(playing: true, seconds: 6.54).text
    check(ttsOn, #"{"playing":true,"seconds":6.5,"type":"tts"}"#, "念回覆：開始念送 tts、估的秒數")
    check(LinkOutgoing.tts(playing: false, seconds: nil).text, #"{"playing":false,"type":"tts"}"#, "念回覆：念完送 playing=false")
    check(LinkOutgoing.tts(playing: true, seconds: 999).text.contains("\"seconds\":180") ? "180" : "沒限", "180", "念回覆：最多算 180 秒")
    check(LinkSpeech.clean("看 https://example.com/a?b=1 和 D:\\資料\\x\\稿.md\n- **重點**：熵"), "看 （連結看畫面） 和 （路徑看畫面） 重點：熵", "念回覆：網址、路徑、清單符號、Markdown 不念")
    let longReply = String(repeating: "這是一句話。", count: 100)
    let spoken = LinkSpeech.clean(longReply)
    check("\(spoken.count <= LinkSpeech.maxChars + 7) \(spoken.hasSuffix("。後面請看畫面。"))", "true true", "念回覆：太長只念前面、念到一句結尾")
    check(String(format: "%.1f", LinkSpeech.seconds(for: "一二三四五六七八")), "3.0", "念回覆：中文約每秒 4 字")

    // v0.19 開口就停（協定 v5，電腦版 v5.33）
    check("\(LinkOutgoing.version)", "5", "開口就停：hello 送 v=5")
    check(LinkOutgoing.tts(playing: true, seconds: 4, barge: LinkBarge(id: 3, text: "念的字")).text,
          #"{"id":3,"playing":true,"seconds":4,"stop_on_voice":true,"text":"念的字","type":"tts"}"#, "開口就停：念的時候帶 stop_on_voice、這則的編號和字")
    check(LinkOutgoing.tts(playing: false, seconds: nil, barge: LinkBarge(id: 3, text: "念的字")).text, #"{"playing":false,"type":"tts"}"#, "開口就停：念完照舊只送 playing=false")
    check(LinkOutgoing.tts(playing: true, seconds: 4).text, #"{"playing":true,"seconds":4,"type":"tts"}"#, "開口就停：開關關掉時跟 v0.18 一樣（不帶）")
    let bigBarge = LinkOutgoing.tts(playing: true, seconds: 4, barge: LinkBarge(id: 1, text: String(repeating: "字", count: 5000))).object
    check("\((bigBarge["text"] as? String)?.count ?? 0)", "2000", "開口就停：字最多送 2000 個")
    check(LinkIncoming.parse(#"{"type":"tts_stop","id":3,"why":"voice"}"#) == .ttsStop(id: 3) ? "停" : "不停", "停", "開口就停：讀得懂電腦的 tts_stop")
    check(LinkIncoming.parse(#"{"type":"tts_stop"}"#) == .ttsStop(id: nil) ? "停" : "不停", "停", "開口就停：電腦沒帶編號也讀得懂")
    check(LinkBargeRule.shouldStop(enabled: true, speakingID: 3, stopID: 3) ? "停" : "不停", "停", "開口就停：同一則就停")
    check(LinkBargeRule.shouldStop(enabled: true, speakingID: 4, stopID: 3) ? "停" : "不停", "不停", "開口就停：上一則的停晚到，不停下一則")
    check(LinkBargeRule.shouldStop(enabled: true, speakingID: nil, stopID: 3) ? "停" : "不停", "不停", "開口就停：沒在念不做事")
    check(LinkBargeRule.shouldStop(enabled: false, speakingID: 3, stopID: 3) ? "停" : "不停", "不停", "開口就停：開關關掉不停")
    check(LinkBargeRule.shouldStop(enabled: true, speakingID: 3, stopID: nil) ? "停" : "不停", "停", "開口就停：電腦沒帶編號就停現在這則")
    check("\(LinkBargeRule.enabled(saved: nil)) \(LinkBargeRule.enabled(saved: false)) \(LinkBargeRule.enabled(saved: true))", "true false true", "開口就停：預設開、關了記得")
    check(LinkBargeRule.caption(pcVersion: 4, enabled: true).contains("v5.33") ? "講" : "沒講", "講", "開口就停：舊電腦（v4）講要更新")
    check(LinkBargeRule.caption(pcVersion: 5, enabled: true).contains("一說話就停") ? "講" : "沒講", "講", "開口就停：新電腦寫怎麼用")
    check(LinkBargeRule.caption(pcVersion: 0, enabled: true).contains("v5.33") ? "講" : "沒講", "沒講", "開口就停：還沒連上不說舊")

    // v0.18 念回覆的聲音：預設跟系統一樣，不再寫死美佳
    let phoneVoices = [
        LinkVoiceOption(id: "en.samantha", name: "Samantha", language: "en-US", enhanced: false),
        LinkVoiceOption(id: "cn.tingting", name: "Tingting", language: "zh-CN", enhanced: false),
        LinkVoiceOption(id: "tw.meijia.e", name: "美佳", language: "zh-TW", enhanced: true),
        LinkVoiceOption(id: "hk.sinji", name: "善怡", language: "zh-HK", enhanced: false),
        LinkVoiceOption(id: "tw.meijia", name: "美佳", language: "zh-TW", enhanced: false),
        LinkVoiceOption(id: "tw.meijia", name: "美佳", language: "zh-TW", enhanced: false),
    ]
    let voiceMenu = LinkVoiceChoice.menu(phoneVoices)
    check(voiceMenu.map(\.label).joined(separator: "｜"), "美佳（加強版）・台灣｜美佳・台灣｜善怡・香港｜Tingting・中國大陸", "聲音：只列中文、台灣先、加強版標出來、重複的只留一次")
    check(LinkVoiceChoice.pick(saved: nil, from: voiceMenu)?.id ?? "系統", "系統", "聲音：沒選過＝跟系統一樣（不指定美佳）")
    check(LinkVoiceChoice.pick(saved: "", from: voiceMenu)?.id ?? "系統", "系統", "聲音：選「跟系統一樣」")
    check(LinkVoiceChoice.pick(saved: "hk.sinji", from: voiceMenu)?.id ?? "系統", "hk.sinji", "聲音：選了哪個就用哪個")
    check(LinkVoiceChoice.pick(saved: "gone.voice", from: voiceMenu)?.id ?? "系統", "系統", "聲音：選過的被刪掉就跟系統")
    let systemNote = LinkVoiceChoice.note(saved: "", from: voiceMenu)
    check("\(systemNote.contains("朗讀內容")) \(systemNote.contains("Siri")) \(systemNote.contains("美佳")) \(systemNote.contains("下載"))", "true true false false", "聲音：跟系統時寫照朗讀設定、說實話 Siri 可能不給 App，不推銷美佳")
    check(LinkVoiceChoice.note(saved: "tw.meijia.e", from: voiceMenu), "用 美佳（加強版）・台灣 念", "聲音：選了寫用哪個")
    check(LinkVoiceChoice.note(saved: "gone.voice", from: voiceMenu).hasPrefix("之前選的聲音不在這支手機上了") ? "講" : "沒講", "講", "聲音：被刪掉的有講")
    check(LinkVoiceChoice.menu([]).isEmpty ? "空" : "有", "空", "聲音：手機沒中文聲音時選單只剩跟系統")

    // 連不上時照網路種類講
    check(LinkHint.network(.cellular) ?? "-", "手機現在用 4G／行動網路，沒連 Wi-Fi：請連跟電腦同一個 Wi-Fi，或開個人熱點讓電腦連（已經開熱點的話，確認電腦連的是這支手機的熱點）", "網路：在 4G 直接講")
    check(LinkHint.network(.wifi) ?? "不寫", "不寫", "網路：在 Wi-Fi 不多寫")
    check(LinkHint.network(.unknown) ?? "不寫", "不寫", "網路：還不知道不寫")
    check(LinkHint.network(.none)?.hasPrefix("手機現在沒有網路") == true ? "寫" : "不寫", "寫", "網路：沒網路")
    let why = "連不上電腦，1 秒後重連（手機和電腦要在同一個 Wi-Fi、電腦的「連手機」要開著；第一次連要按「允許」區域網路）"
    check(LinkHint.lostNote(why, network: .cellular), "連不上電腦，1 秒後重連", "網路：在 4G 時拿掉「要在同一個 Wi-Fi」的通用提示（改由上一行直接講）")
    check(LinkHint.lostNote(why, network: .wifi), why, "網路：在 Wi-Fi 照原本的提示")
}

// v0.21 匯出紀錄的檔名與原始轉錄：檔名固定、格式一致，其他工具（或協作的 AI）才能照同一套規則找檔、讀檔
// 規則和電腦版自動轉錄一致：<匯出資料夾>/<課名>/YYYYMMDD_<課名>_原始轉錄.txt；課名用正式全名
do {
    let formal = ["日文": "日文", "桌遊": "桌遊設計", "美術": "美術鑑賞", "幾何": "解析幾何", "木工": "木工實作",
                  "讀書會": "讀書會", "私人課": "私人課"]
    for (short, full) in formal.sorted(by: { $0.key < $1.key }) {
        check(CourseSchedule.formalName(short), full, "課名對照：\(short)")
    }
    check(CourseSchedule.formalName("自己取的"), "自己取的", "課名對照：課表沒有的照原樣")
    let formalSet = Set(CourseSchedule.slots.map { CourseSchedule.formalName($0.name) })
    check(formalSet.sorted().joined(separator: "、"), ["木工實作", "桌遊設計", "美術鑑賞", "解析幾何", "日文", "讀書會", "私人課"].sorted().joined(separator: "、"), "課名對照：課表上的全名（同一門課兩個時段只算一次）")
    check(["桌遊", "美術", "幾何", "木工"].filter { formalSet.contains($0) }.joined(separator: "、"), "", "課名對照：簡稱不會出現在檔名")
    check(CourseSchedule.title(stamp: "20261110-102000", course: "幾何"), "11/10 幾何", "課名對照：畫面標題照舊用簡稱")
    check(CourseSchedule.shortName("解析幾何") + " " + CourseSchedule.shortName("日文") + " " + CourseSchedule.shortName("不在課表"), "幾何 日文 不在課表", "課名對照：正式課名換回簡稱")
    check(ClassRecord.courseName(nil), "未分類", "課名對照：不在上課時段是未分類")
    check(ClassRecord.courseName(""), "未分類", "課名對照：空的也是未分類")

    // 檔名
    let afternoon = classAt(2026, 3, 10, 15, 5)
    check(ClassRecord.rawFileName(stamp: "20261109-153512", course: afternoon), "20261109_美術鑑賞_原始轉錄.txt", "檔名：照課表對到簡稱→正式課名的原始轉錄")
    check(ClassRecord.rawFileName(stamp: "20261110-102013", course: "幾何"), "20261110_解析幾何_原始轉錄.txt", "檔名：原始轉錄（日期＝錄音開始那天）")
    check(ClassRecord.rawFileName(stamp: "20261108-170512", course: nil), "20261108_未分類_原始轉錄.txt", "檔名：沒課是未分類")
    check(ClassRecord.exportFileName(.session, stamp: "20261110-102013", course: "幾何"), "20261110_解析幾何_App匯出_1020.zip", "檔名：zip")
    check(ClassRecord.exportFileName(.withAudio, stamp: "20261111-132501", course: "木工"), "20261111_木工實作_App匯出含錄音_1325.zip", "檔名：zip 含錄音")
    check(ClassRecord.exportFileName(.errors, stamp: "20261110-091502", course: "日文"), "20261110_日文_錯誤資料_0915.txt", "檔名：錯誤資料")
    check(ClassRecord.exportFileName(.errors, stamp: "20261108-170512", course: nil), "20261108_未分類_錯誤資料_1705.txt", "檔名：錯誤資料沒課")
    let namePattern = try! NSRegularExpression(pattern: "^[0-9]{8}_[^_ ]+_(原始轉錄\\.txt|App匯出_[0-9]{4}\\.zip|App匯出含錄音_[0-9]{4}\\.zip|錯誤資料_[0-9]{4}\\.txt)$")
    let names = CourseSchedule.slots.flatMap { slot -> [String] in
        [ClassRecord.rawFileName(stamp: "20261110-102013", course: slot.name),
         ClassRecord.exportFileName(.session, stamp: "20261110-102013", course: slot.name),
         ClassRecord.exportFileName(.withAudio, stamp: "20261110-102013", course: slot.name),
         ClassRecord.exportFileName(.errors, stamp: "20261110-102013", course: slot.name)]
    }
    check(names.filter { namePattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) == nil }.joined(separator: "、"), "", "檔名：每堂課四種檔名都合格式")

    // 區塊第一行
    let headPattern = try! NSRegularExpression(pattern: "^【[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} 開始（時間來源：[^，）]+，引擎：[^）]+）｜[^】]+】$")
    func isHead(_ line: String) -> Bool { headPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }
    let engine = "iPhone 轉文字 0.21.24"
    let one = ClassRecord.rawTranscript(
        text: "A：今天講夏木漱石〔夏目漱石？〕的作品。\n\nB：好。\n",
        id: "20261109-092140", starts: ["20261109-092140"], partCount: 1, engine: engine)
    check(one, "【2026-11-09 09:21 開始（時間來源：App 錄音，引擎：iPhone 轉文字 0.21.24）｜20261109-092140 第1段】\nA：今天講夏木漱石的作品。\n\nB：好。\n", "原始轉錄：一段一個區塊、拿掉〔…〕、留講者")
    check(isHead(one.components(separatedBy: "\n")[0]) ? "對" : "錯", "對", "原始轉錄：區塊第一行格式（和電腦版一樣）")
    check(isHead("【2026-11-05 10:21 開始（時間來源：修改時間−長度，引擎：內顯）｜Nov 5, 2026 at 10_20_32 AM.m4a】") ? "對" : "錯", "對", "原始轉錄：電腦版的區塊第一行也符合同一個格式")

    // 續錄多段：每段一個區塊，分隔行不進原文
    let t2 = PartJoin.head(base: "第一段的字。\n", part: 2, offset: 3000) + "第二段的字。"
    let t3 = PartJoin.head(base: t2, part: 3, offset: 4000) + "A：第三段〔三？〕。\n"
    check(ClassRecord.parts(of: t3).joined(separator: "|"), "第一段的字。|第二段的字。|A：第三段。", "續錄多段：照分隔行拆成三段")
    let log = [
        "09:21:41 開始錄音；按下時已預熱（0.4 秒）",
        "10:12:00 停止錄音：這段錄了 50:00",
        "10:29:00 續錄第 2 段，從 50:00 接著錄；按下時還沒預熱完",
        "10:29:02 續錄開不起來：麥克風被佔用",
        "10:30:05 續錄第 2 段，從 50:00 接著錄；按下時已預熱（0.3 秒）",
        "23:59:00 停止錄音",
        "00:10:00 續錄第 3 段，從 1:06:40 接著錄；按下時已預熱（0.3 秒）",
    ]
    let found = ClassRecord.partStarts(stored: nil, first: "20261109-092140", count: 3, log: log)
    check(found?.joined(separator: " ") ?? "nil", "20261109-092140 20261109-103005 20261110-001000", "續錄多段：舊稿從各步紀錄找各段時間（同段取最後一次、過半夜加一天）")
    check(ClassRecord.partStarts(stored: ["20261109-092140", "20261109-103005", "20261109-110000"], first: "20261109-092140", count: 3, log: [])?.last ?? "nil", "20261109-110000", "續錄多段：v0.21 存的各段時間優先")
    check(ClassRecord.partStarts(stored: nil, first: "20261109-092140", count: 3, log: Array(log.prefix(5))) == nil ? "nil" : "有", "nil", "續錄多段：少一段的時間就算取不到")
    let multi = ClassRecord.rawTranscript(text: t3, id: "20261109-092140", starts: found, partCount: 3, engine: engine)
    let blocks = multi.components(separatedBy: "\n\n")
    check("\(blocks.count)", "3", "續錄多段：三個區塊、區塊之間空一行")
    check(blocks.count == 3 ? blocks[1] : "", "【2026-11-09 10:30 開始（時間來源：App 錄音，引擎：iPhone 轉文字 0.21.24）｜20261109-092140 第2段】\n第二段的字。", "續錄多段：第 2 段用續錄那時的時間")
    check(blocks.allSatisfy { isHead($0.components(separatedBy: "\n")[0]) } ? "對" : "錯", "對", "續錄多段：每個區塊第一行都合格式")
    check(multi.contains("續錄第") || multi.contains("〔") ? "有" : "沒有", "沒有", "續錄多段：原文沒有分隔行和標註")
    let lost = ClassRecord.rawTranscript(text: t3, id: "20261109-092140", starts: nil, partCount: 3, engine: engine)
    let lostLines = lost.components(separatedBy: "\n")
    check(lostLines[0], "【2026-11-09 09:21 開始（時間來源：App 錄音，引擎：iPhone 轉文字 0.21.24）｜20261109-092140 第1–3段】", "續錄多段：時間取不到整場一個區塊")
    check(lostLines[1], "〔共 3 段，各段時間沒有紀錄〕", "續錄多段：取不到時第二行註明")
    check(lost.hasSuffix("A：第三段。\n") && !lost.contains("續錄第") ? "對" : "錯", "對", "續錄多段：取不到時字一個不少、沒有分隔行")
    let picked = ClassRecord.rawTranscript(text: "選來的字。", id: "20261108-200000", starts: ["20261108-200000"], partCount: 1, engine: engine, firstSource: "選檔轉成文字的時間而非錄音時間")
    check(isHead(picked.components(separatedBy: "\n")[0]) ? "對" : "錯", "對", "原始轉錄：選來的檔也合格式、寫明時間來源")
    let fromPC = ClassRecord.rawTranscript(text: "我：電腦轉的字。", id: "20261108-153000", starts: ["20261108-153000"], partCount: 1, engine: "電腦版兩人對談轉文字，存於 iPhone 轉文字 0.21.24", firstSource: "連電腦時電腦開始錄音")
    check(isHead(fromPC.components(separatedBy: "\n")[0]) ? "對" : "錯", "對", "原始轉錄：連電腦存的稿也合格式")

    // v0.21 錄音中複製：要整場累積的字（續錄含前面段落），不是畫面上的最後 3000 字
    let earlier = String(repeating: "前面段落的字。", count: 800)   // 5600 字，比畫面尾巴長
    let headPart = PartJoin.head(base: "開頭第一句。" + earlier, part: 2, offset: 3600)
    let finalNow = headPart + "這段已定稿的字。"
    let copied = LiveCopy.join(final: finalNow, volatile: "還在變的灰字")
    check(copied.hasPrefix("開頭第一句。") ? "對" : "錯", "對", "錄音中複製：含續錄前面段落的開頭")
    check(copied.hasSuffix("這段已定稿的字。還在變的灰字") ? "對" : "錯", "對", "錄音中複製：黑字後接灰字（和畫面一樣）")
    check(String(finalNow.suffix(3000)).hasPrefix("開頭第一句。") ? "畫面尾巴就有" : "畫面尾巴沒有", "畫面尾巴沒有", "錄音中複製：畫面尾巴（recordingTail）不夠，要用整份")
    check(LiveCopy.statusLine(at: 754).hasPrefix("注意：錄音中，到 12:34（") ? "對" : "錯", "對", "錄音中複製：稿頭寫錄音中到幾分")
    check(LiveCopy.statusLine(at: 3725).hasPrefix("注意：錄音中，到 1:02:05") ? "對" : "錯", "對", "錄音中複製：超過一小時寫時:分:秒")
    // 0.23.3：複製稿頭多一行投影片和 Haiku 狀態
    check(LiveCopy.addHeaderLine("---\n標題：x\n---\n稿", line: "投影片：ch3；Haiku：已送 3 批"), "---\n標題：x\n投影片：ch3；Haiku：已送 3 批\n---\n稿", "錄音中複製：稿頭加投影片和 Haiku 一行")
    check(LiveCopy.addHeaderLine("沒有稿頭", line: "投影片：ch3"), "沒有稿頭", "錄音中複製：沒有稿頭就不加")
    // 0.23.4 實驗模式（LabPlan.swift）
    do {
        let pages = ["Linear Systems\nThe row space of the matrix", "row space and rank", "rank of square matrices", "the and for"]
        let kw = LabKeywords.pick(pages: pages, glossaryRights: ["Gauss"], limit: 10)
        check(kw.first ?? "", "Gauss", "實驗模式：課程對照表的詞排最前面")
        check(kw.contains("row space") ? "有" : "沒有", "有", "實驗模式：出現 2 次的兩字詞組當關鍵字")
        check(kw.contains("rank") ? "有" : "沒有", "有", "實驗模式：出現 2 次的單字當關鍵字")
        check(kw.contains(where: { $0.lowercased() == "the" }) ? "有" : "沒有", "沒有", "實驗模式：虛詞不當關鍵字")
        check(kw.contains("square") ? "有" : "沒有", "沒有", "實驗模式：只出現 1 次的不當關鍵字")
        check("\(LabMetrics.distance(Array("kitten"), Array("sitting")))", "3", "實驗模式：編輯距離")
        check(String(format: "%.2f", LabMetrics.agreement("向量，很長", "向量很長")), "1.00", "實驗模式：一致度不算標點空白")
        check(String(format: "%.2f", LabMetrics.agreement("像量很長", "向量很長")), "0.75", "實驗模式：一致度一字不同")
        check(LabMetrics.hits("Row space 和 row space、rank", keywords: ["row space", "rank", "NMR"]).map(String.init).joined(separator: ","), "2,1,0", "實驗模式：關鍵字次數不分大小寫")
        let r = [LabResult(name: "A", note: "", pieces: [TimedPiece(text: "第一分鐘", start: 1, end: 2), TimedPiece(text: "第二分鐘", start: 61, end: 62)], text: "第一分鐘第二分鐘", seconds: 10, error: nil),
                 LabResult(name: "B", note: "", pieces: [], text: "", seconds: nil, error: "壞了")]
        let md = LabReport.markdown(file: "x.caf", course: "解析幾何", audioSeconds: 120, keywords: ["rank"], results: r, app: "0.23.4")
        check(md.contains("| B | 失敗：壞了 |") ? "有" : "沒有", "有", "實驗模式：失敗的引擎寫在報告裡")
        check(md.contains("不是錯字率") ? "有" : "沒有", "有", "實驗模式：報告寫明不是錯字率")
        let html = LabReport.sideBySide(file: "x.caf", results: r, audioSeconds: 120)
        check(html.contains("<td>第二分鐘</td>") ? "有" : "沒有", "有", "實驗模式：每分鐘對照分到第二列")
    }
}

// v0.20 錄音看門狗：牆上時間和錄進檔的秒數（起因：真機一場錄音牆上 2:51、音檔 1:36，錯誤資料什麼都沒有）
do {
    func run(_ steps: [(Double, Double)]) -> (events: [RecordWatch.Event], watch: RecordWatch) {
        var w = RecordWatch()
        var events: [RecordWatch.Event] = []
        for (wall, audio) in steps {
            if let e = w.tick(wall: wall, audio: audio) { events.append(e) }
        }
        return (events, w)
    }
    let normal = run((1...60).map { (Double($0), Double($0) - 0.1) })
    check("\(normal.events.count) \(normal.watch.stallCount)", "0 0", "看門狗：正常錄 60 秒不報")

    let late = run([(1, 0.9), (2, 1.0), (3, 1.0), (4, 1.0), (5, 4.9), (6, 5.9)])
    check("\(late.events.count)", "0", "看門狗：一批晚到 3 秒不算停")

    var steps: [(Double, Double)] = (1...20).map { (Double($0), Double($0)) }
    steps += (21...49).map { (Double($0), 20.0) }       // 20 秒起沒聲音
    steps += (50...55).map { (Double($0), 20.0 + Double($0 - 49)) }
    let cut = run(steps)
    check("\(cut.events.first.map { "\($0)" } ?? "-")", "stalled(audio: 20.0, silentFor: 10.0)", "看門狗：10 秒沒聲音報一次停（停在第 20 秒）")
    check("\(cut.events.filter { if case .stalled = $0 { return true } else { return false } }.count)", "1", "看門狗：停著不重複報")
    if case .resumed(let lost)? = cut.events.last {
        check(String(format: "%.0f", lost), "29", "看門狗：接回來算出少了 29 秒")
    } else {
        check("沒報", "resumed", "看門狗：接回來要報")
    }
    check("\(cut.watch.stallCount) \(cut.watch.stalled)", "1 false", "看門狗：停過 1 次、現在沒停")

    var w = RecordWatch()
    _ = w.tick(wall: 1, audio: 1)
    _ = w.tick(wall: 12, audio: 1)
    check(w.silentFor(wall: 15).map { String(format: "%.0f", $0) } ?? "-", "14", "看門狗：停著時算得出已經幾秒")
    check(RecordWatch.banner(silentFor: 14.6).hasPrefix("錄音停了：已經 14 秒沒有聲音進來") ? "對" : "錯", "對", "看門狗：紅字寫幾秒")

    check(RecordWatch.stopLine(wall: 3161, audio: 3160, stalls: 0), "這段實際經過 52:41，錄到 52:40", "看門狗：差不到 3 秒不講少")
    check(RecordWatch.stopLine(wall: 3600, audio: 1200, stalls: 1), "這段實際經過 1:00:00，錄到 20:00，少了 40:00（錄音中停過 1 次）", "看門狗：停過會寫少多久")
    check(RecordWatch.stopLine(wall: 600, audio: 480, stalls: 0).contains("App 沒看到停") ? "講" : "沒講", "講", "看門狗：少了但沒看到停（App 被暫停）也講")
    check(RecordWatch.clock(3725), "1:02:05", "看門狗：時間寫法")
}


// v0.22 錄音中即時改字（只改畫面）：對照表是上面 sampleSettings 編的
do {
    let calc = LiveFix.rules(course: "解析幾何")
    check(LiveFix.pieces("你給一個像量那他就是飛靈的像量", rules: calc).map { $0.text }.joined(), "你給一個向量那他就是非零的向量", "即時改字：像量、飛靈")
    check(LiveFix.pieces("反像量跟單位像量", rules: calc).map { $0.text }.joined(), "反向量跟單位向量", "即時改字：長的先比（反像量不會變反向量以外的字）")
    check(LiveFix.pieces("第一個烤第二個烤", rules: calc).map { $0.text }.joined(), "第一個column第二個column", "即時改字：一個字的規則（烤→column）")
    check(LiveFix.pieces("做一階到數的時候，這個到數", rules: calc).map { $0.text }.joined(), "做一階導數的時候，這個倒數", "即時改字：一階到數先比，再到數→倒數")
    check(LiveFix.copyText("飛靈的像量", rules: calc), "非零［飛靈］的向量［像量］", "即時改字：複製寫成 改字［原字］")
    check("\(LiveFix.count("層上第一個column可以", rules: calc))", "0", "即時改字：層、可以 不在表裡，不動")
    check(LiveFix.pieces("上麵特征值", rules: LiveFix.rules(course: "美術鑑賞")).map { $0.text }.joined(), "上面特徵值", "即時改字：通用字形錯每門課都套")
    check(LiveFix.pieces("一塊烤", rules: LiveFix.rules(course: "美術鑑賞")).map { $0.text }.joined(), "一塊烤", "即時改字：這門課的表不套到別門課")
    check(LiveFix.pieces("像量", rules: LiveFix.rules(course: "解析幾何", off: ["像量"])).map { $0.text }.joined(), "像量", "即時改字：這場按掉的不改")
    check(LiveFix.pieces("", rules: calc).count == 0 ? "空" : "有", "空", "即時改字：空字串")
    check("\(WatchAlarm.action(wall: 20, lastRearm: 0, stalled: false, inBackground: true, alerted: false))", "rearm", "背景提醒：正常錄音每 15 秒往後延")
    check("\(WatchAlarm.action(wall: 10, lastRearm: 0, stalled: false, inBackground: true, alerted: false))", "none", "背景提醒：不到 15 秒不延")
    check("\(WatchAlarm.action(wall: 30, lastRearm: 0, stalled: true, inBackground: true, alerted: false))", "alertNow", "背景提醒：背景中停了立刻通知")
    check("\(WatchAlarm.action(wall: 30, lastRearm: 0, stalled: true, inBackground: true, alerted: true))", "none", "背景提醒：同一次停只通知一次")
    check("\(WatchAlarm.action(wall: 30, lastRearm: 0, stalled: true, inBackground: false, alerted: false))", "none", "背景提醒：前景停了用紅字，不通知")
}

// v0.23.1 地基：兩個錯字對到同一個詞、投影片與課程設定檔（SlidePages.swift）
do {
    let calc = LiveFix.rules(course: "解析幾何")
    check(LiveFix.pieces("單位像量和單味像量", rules: calc).map { $0.text }.joined(), "單位向量和單位向量", "即時改字：單位像量、單味像量 → 單位向量")

    let deck = SlideDeck.make(course: "解析幾何", source: "lecture-17.pdf", importedAt: "20261110-220000",
                              pages: ["  Inner Product\r\n向量內積定義\n", "", "克拉瑪公式 Cramer formula 3x3"])
    check(deck.titles.joined(separator: "|"), "Inner Product||克拉瑪公式 Cramer formula 3x3", "投影片：每頁標題取第一行")
    check(deck.pages[0], "Inner Product\n向量內積定義", "投影片：頭尾空白和 \\r\\n 整理掉")
    check(deck.summary, "解析幾何：lecture-17（3 頁，1 頁沒有字）", "投影片：匯入結果一行（含沒字的頁）")
    check(SlideDeck.make(course: "解析幾何", source: "lecture-17.pdf", importedAt: "x", pages: ["a", "b"]).summary,
          "解析幾何：lecture-17（2 頁）", "投影片：每頁都有字")
    // 估 token：6 中文字＋2 英文詞×1.3＋4＝12.6；空頁 4；5 中文字＋3 英文詞（Cramer、formula、3x3 裡的 x）×1.3＋2 個數字÷3＋4≈13.57；合計 30.17 進位 31
    check("\(SlideDeck.estimateTokens(["向量內積定義 Inner Product", "", "克拉瑪公式 Cramer formula 3x3"]))", "31", "投影片：token 粗估")
    check(SlideDeck.fileName(source: "lecture-17.pdf"), "lecture-17.json", "投影片：存檔檔名")
    check(SlideDeck.fileName(source: "第3章:矩陣?.pdf"), "第3章矩陣.json", "投影片：檔名拿掉不能用的字")
    let deckData = try? JSONEncoder().encode(deck)
    let deckBack = deckData.flatMap { try? JSONDecoder().decode(SlideDeck.self, from: $0) }
    check(deckBack == deck ? "同" : "不同", "同", "投影片：存了讀回來一樣")

    check(CourseProfile.allowsUpload(course: "私人課") ? "送" : "不送", "不送", "課程設定：私人課程永遠不送")
    check(CourseProfile(haiku: true).sends(course: "私人課") ? "送" : "不送", "不送", "課程設定：私人課程開著也不送")
    check(CourseProfile.allowsUpload(course: " 私人課 ") ? "送" : "不送", "不送", "課程設定：私人課程前後有空白也不送")
    check(CourseSchedule.isPrivate("私人補課") ? "私人" : "不是", "私人", "課程設定：課名含 privateKeywords 的字也算私人")
    check(CourseProfile.allowsUpload(course: "沒在課表的課") ? "送" : "不送", "不送", "課程設定：不在設定檔課表上的課不送")
    check(CourseProfile.allowsUpload(course: nil) ? "送" : "不送", "不送", "課程設定：沒有課名不送")
    check(CourseProfile.allowsUpload(course: "  ") ? "送" : "不送", "不送", "課程設定：空白課名不送")
    check(CourseProfile.allowsUpload(course: "幾何") ? "送" : "不送", "送", "課程設定：簡稱的課可以送")
    check(CourseProfile.allowsUpload(course: "解析幾何") ? "送" : "不送", "送", "課程設定：正式課名可以送")
    check(CourseProfile(haiku: false).sends(course: "解析幾何") ? "送" : "不送", "不送", "課程設定：關掉就不送")
    check(CourseSchedule.slots.filter { !CourseProfile.allowsUpload(course: $0.name) }.map(\.name).joined(separator: ","), "私人課", "課程設定：課表上只有私人課程不送")
    check(CourseProfile.fileName(course: "幾何"), "解析幾何.json", "課程設定：檔名用正式課名")
    check(CourseProfile.fileName(course: "私人課"), "私人課.json", "課程設定：沒有正式名用原名")

    let emptyProfile = try? JSONDecoder().decode(CourseProfile.self, from: Data("{}".utf8))
    check(emptyProfile.map { "\($0.haiku) \($0.slides ?? "nil")" } ?? "讀不開", "true nil", "課程設定：空檔用預設（送、沒投影片）")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let profileText = (try? encoder.encode(CourseProfile(haiku: false, slides: "lecture-17.json"))).map { String(decoding: $0, as: UTF8.self) } ?? ""
    check(profileText, #"{"haiku":false,"slides":"lecture-17.json"}"#, "課程設定：存檔欄位")

    // 真的寫進暫存資料夾讀回來
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shape_check_slides_\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    check(CourseProfile.load(course: "幾何", root: root) == CourseProfile() ? "預設" : "不是", "預設", "課程設定：沒有檔就是預設")
    let saved = try? SlideStore.save(deck, root: root)
    check(saved.map { $0.path.hasSuffix("投影片/解析幾何/lecture-17.json") ? "對" : $0.path } ?? "存不了", "對", "投影片：存在 投影片/正式課名/")
    check(CourseProfile.load(course: "幾何", root: root).slides ?? "nil", "lecture-17.json", "投影片：匯入後課程設定指到這份")
    check(SlideStore.latest(course: "幾何", root: root)?.summary ?? "nil", deck.summary, "投影片：取這門課最新一份")
    let older = SlideDeck.make(course: "解析幾何", source: "lecture-16.pdf", importedAt: "20261103-100000", pages: ["舊的"])
    _ = try? SlideStore.save(older, root: root)
    try? CourseProfile(haiku: true, slides: "不見了.json").save(course: "解析幾何", root: root)
    check(SlideStore.latest(course: "解析幾何", root: root)?.name ?? "nil", "lecture-17", "投影片：設定指的檔不見了就取匯入時間最新的")
    check(SlideStore.latest(course: "美術鑑賞", root: root) == nil ? "還沒有" : "有", "還沒有", "投影片：別的課沒有")

}

// v0.23.2 錄音中 Haiku 改字（純邏輯層）：tools/shape_check/haiku_tests.swift
haikuTests(check)
// v0.23.2 送審的重試、合併、定稿命中、狀態列的字：tools/shape_check/review_tests.swift
reviewTests(check)
// v0.23.2 自動上傳測試資料（要不要傳、檔名、待傳清單、PKCE、Google 請求內容）：tools/shape_check/drive_tests.swift
driveTests(check)
// v0.23.5 下課後 Whisper 再轉一份（濾鬼打牆、切窗、稿頭、待辦合併）、實驗模式疑似失敗：tools/shape_check/whisper_tests.swift
whisperTests(check)
// v0.23.5 實驗模式「Whisper 切句（照電腦版，模擬邊錄邊轉）」：切句、落後模擬、報告那一節：tools/shape_check/livecut_tests.swift
liveCutTests(check)
// v0.26.0 即時模式 1 每批一張卡（逐字比對、一句一行、回覆解析、把關、整理版）：tools/shape_check/cards_tests.swift
cardsTests(check)
// v0.26.1 打斷後快速重試接回麥克風的排程、麥克風共用：tools/shape_check/recover_tests.swift
recoverTests(check)
// v0.27.0 場景、點一下改字、Pencil 圈起來重查、左右欄寬度、討論會停止後分人：tools/shape_check/scene_tests.swift
sceneTests(check)

print(failed == 0 ? "全部通過" : "失敗 \(failed) 項")
exit(failed == 0 ? 0 : 1)
