import Foundation

// v0.27.1 Sources/SessionFiles.swift：停止後分享的檔名與逐字稿內容、卡片 PDF 的分頁與圖縮放、「以前的課」清單（讀回稿頭、分組、排序）。
// 句子、課名全是自己編的；期望值照規則手算。main.swift 只呼叫 sessionTests(check)。

func sessionTests(_ check: @escaping (String, String, String) -> Void) {
    // ---- 檔名（固定檔名規則：YYYYMMDD_<課名>_逐字稿.md）
    check(SessionExport.transcriptName(stamp: "20261113-091500", course: nil), "20261113_未分類_逐字稿.md", "分享檔名：沒課名是未分類")
    check(SessionExport.transcriptName(stamp: "20261113-091500", course: "某討論"), "20261113_某討論_逐字稿.md", "分享檔名：逐字稿 md")
    check(SessionExport.cardsPDFName(stamp: "20261113-091500", course: "某討論"), "20261113_某討論_重點.pdf", "分享檔名：卡片 PDF")
    check(SessionExport.stamp(recorded: "20261113-091200", started: "20261113-101500") + "|" + SessionExport.stamp(recorded: nil, started: "20261113-101500"),
          "20261113-091200|20261113-101500", "分享檔名：日期用錄音開始那天")

    // ---- 逐字稿內容
    var a = LiveCard(id: 1, start: 0, end: 60, raw: "第一段原字")
    a.state = .done
    a.expanded = "第一段。改好的字。"
    a.page = 3
    var b = LiveCard(id: 2, start: 60, end: 120, raw: "第二段沒整理到")
    b.state = .failed
    let doc = SessionExport.transcriptDocument(stamp: "20261113-091500", course: "某討論", device: "iPad", slides: "lecture-3",
                                               cards: [b, a], speakerText: nil)
    check(doc.hasPrefix("# 20261113 某討論 逐字稿\n") ? "對" : doc, "對", "逐字稿：標題照固定格式")
    check(doc.contains("- 校正依據：投影片 lecture-3") && doc.contains("- 投影片頁碼：每節標題的 p.N") ? "對" : doc, "對", "逐字稿：稿頭寫投影片、頁碼")
    check(doc.components(separatedBy: "---\n\n").last ?? "",
          "## 00:00–01:00　p.3\n\n第一段。\n改好的字。\n\n## 01:00–02:00\n\n第二段沒整理到\n", "逐字稿：每張卡一節（依時間、一句一行）")
    let spoken = SessionExport.transcriptDocument(stamp: "20261113-091500", course: nil, device: "iPhone", slides: nil,
                                                  cards: [a], speakerText: "A：甲。\n\nB：乙。")
    check(spoken.components(separatedBy: "---\n\n").last ?? "", "A：甲。\n\nB：乙。\n", "逐字稿：有分人就用分好人的整份")
    check(spoken.contains("- 校正依據：沒有") && spoken.contains("- 投影片頁碼：每節標題的 p.N") ? "對" : spoken, "對", "逐字稿：沒有投影片")

    // ---- PDF：圖縮放、分頁
    func size(_ s: (width: Double, height: Double)) -> String { String(format: "%.0fx%.0f", s.width, s.height) }
    check(size(CardsPDFLayout.fit(width: 1000, height: 500, maxWidth: 500, maxHeight: 800)), "500x250", "PDF 圖：照寬縮")
    check(size(CardsPDFLayout.fit(width: 400, height: 1000, maxWidth: 500, maxHeight: 500)), "200x500", "PDF 圖：太高照高縮")
    check(size(CardsPDFLayout.fit(width: 100, height: 50, maxWidth: 500, maxHeight: 500)), "100x50", "PDF 圖：不放大")
    check(size(CardsPDFLayout.pixelSize(width: 3200, height: 1800)), "1600x900", "PDF 圖：存的像素最大邊 1600")
    check(size(CardsPDFLayout.fit(width: 0, height: 10, maxWidth: 5, maxHeight: 5)), "0x0", "PDF 圖：壞掉的尺寸")
    typealias B = CardsPDFLayout.Block
    func pages(_ blocks: [B], _ height: Double = 100) -> String {
        CardsPDFLayout.paginate(blocks, pageHeight: height).map { String(format: "%d@%.0f", $0.page, $0.y) }.joined(separator: ",")
    }
    check(pages([B(height: 30, gap: 10), B(height: 30, gap: 10), B(height: 30, gap: 10)]), "0@0,0@40,1@0", "PDF 分頁：放不下換頁")
    check(pages([B(height: 30, gap: 10), B(height: 150, gap: 10), B(height: 20, gap: 0)]), "0@0,1@0,2@0", "PDF 分頁：比一頁高的自己一頁，下一塊換頁")
    check(pages([B(height: 50, gap: 10), B(height: 10, gap: 5, keepWithNext: true), B(height: 40, gap: 0)]), "0@0,1@0,1@15", "PDF 分頁：標題不落單在頁底")
    check(pages([B(height: 50, gap: 0), B(height: 50, gap: 0)]), "0@0,0@50", "PDF 分頁：剛好塞滿")
    check("\(CardsPDFLayout.pageCount(CardsPDFLayout.paginate([B(height: 30, gap: 10), B(height: 150, gap: 10)], pageHeight: 100)))", "2", "PDF 分頁：頁數")
    check("\(CardsPDFLayout.pageCount([]))", "0", "PDF 分頁：沒有東西 0 頁")
    check(String(format: "%.1f|%.1f", CardsPDFLayout.contentWidth, CardsPDFLayout.contentHeight), "499.2|745.8", "PDF：A4 扣掉邊界")

    // ---- 以前的課：檔名
    func mainOf(_ name: String) -> String {
        RunNameCheck.describe(RunCatalog.mainName(name))
    }
    check(mainOf("20261113-091500 20261113-091200.txt"), "20261113-091500|20261113-091200", "以前的課：主稿檔名")
    check(mainOf("20261113-091500 20261113-091200 原文.txt"), "nil", "以前的課：原文不是主稿")
    check(mainOf("20261113-091500 20261113-091200 即時稿.txt"), "nil", "以前的課：即時稿不是主稿")
    check(mainOf("20261113-091500 20261113-091200 Whisper稿.txt"), "nil", "以前的課：Whisper 稿不是主稿")
    check(mainOf("20261113-091500 20261113-091200 卡片.json"), "nil", "以前的課：json 不是")
    check(mainOf(".最近一次.json"), "nil", "以前的課：隱藏檔不是")
    check(mainOf("20261113-091500 我的訪談 錄音.txt"), "20261113-091500|我的訪談 錄音", "以前的課：選來的檔（檔名有空白）")
    check(mainOf("2026111-091500 x.txt"), "nil", "以前的課：時間格式不對")
    check("\(RunCatalog.seconds("12:34") ?? -1)|\(RunCatalog.seconds("1:02:03") ?? -1)|\(RunCatalog.seconds("abc") ?? -1)", "754.0|3723.0|-1.0", "以前的課：時長換秒數")

    // ---- 以前的課：讀回稿頭
    let document = """
    ---
    標題：11/13 某討論（照課表自動命名）
    日期：2026-11-13 09:12 開始，10:04 結束（中間停過，共 2 段）
    時長：52:10
    來源：20261113-091200.caf
    錄音：共 2 段（20261113-091200.caf、20261113-091200 第2段.caf），字照順序接在一起，時間.json 的秒數從第一段開頭算
    講者：A、B（手機只看聲音自動分，可能分錯；A、B 是出現順序，不是人名）
    場景：討論會
    說明：文字由手機語音辨識（Apple，zh_TW）產生，可能有同音錯字，人名與專有名詞尤其要核對。
    ---
    A：第一句。

    B：第二句。

    ---
    離線校正提示（手機蘋果 AI 覺得可能是同音錯字）
    甲 → 乙
    """
    if let entry = RunCatalog.parse(fileName: "20261113-101500 20261113-091200.txt", course: "某討論", document: document) {
        check("\(entry.title)|\(entry.audioSeconds ?? -1)|\(entry.speakers.joined(separator: ","))|\(entry.parts?.count ?? 0)|\(entry.finished)|\(entry.origin ?? "nil")|\(entry.scene ?? "nil")",
              "11/13 某討論|3130.0|A,B|2|true|nil|discussion", "以前的課：稿頭讀回標題、時長、講者、各段、場景")
        check(entry.text, "A：第一句。\n\nB：第二句。", "以前的課：稿的字（附錄拿掉）")
        check(entry.recordedStamp ?? "nil", "20261113-091200", "以前的課：錄音開始時間＝來源檔名")
        check(RunCatalog.rowText(entry), "11/13 09:12　某討論　52:10　討論會", "以前的課：清單一列")
    } else {
        check("讀不出", "讀得出", "以前的課：讀回稿頭")
    }
    check(RunCatalog.parse(fileName: "20261113-101500 20261113-091200.txt", course: nil, document: "沒有稿頭的字") == nil ? "nil" : "有", "nil", "以前的課：沒有稿頭不算")
    let unfinished = "---\n標題：選來的檔\n日期：2026-11-12 08:00（轉成文字的時間，不是原檔錄的時間）\n來源：訪談.m4a\n講者：沒有分人\n注意：這份沒有轉完，只有已出來的字。\n---\n字"
    if let entry = RunCatalog.parse(fileName: "20261112-080000 訪談.txt", course: nil, document: unfinished) {
        check("\(entry.finished)|\(entry.speakers.count)|\(entry.recordedStamp ?? "nil")|\(entry.audioSeconds ?? -1)|\(entry.text)", "false|0|nil|-1.0|字", "以前的課：沒轉完、沒分人、選來的檔")
        check(RunCatalog.rowText(entry), "11/12 08:00", "以前的課：選來的檔用轉成文字的時間")
    } else {
        check("讀不出", "讀得出", "以前的課：選來的檔")
    }

    // ---- 以前的課：分組、排序
    func makeEntry(_ started: String, _ stem: String, _ course: String?) -> RunEntry {
        RunEntry(startedStamp: started, sourceStem: stem, course: course, title: "", audioSeconds: nil, speakers: [], parts: nil,
                 finished: true, origin: nil, text: "", scene: nil)
    }
    let grouped = RunCatalog.group([
        makeEntry("20261110-100000", "20261110-090000", "甲課"),
        makeEntry("20261113-100000", "20261113-090000", "乙課"),
        makeEntry("20261112-100000", "20261112-090000", "甲課"),
        makeEntry("20261114-100000", "外面的檔", nil),
        makeEntry("20261111-100000", "20261111-090000", ""),
    ])
    check(grouped.map { $0.course + ":" + $0.entries.map { String($0.sortStamp.prefix(8)) }.joined(separator: ",") }.joined(separator: " / "),
          "乙課:20261113 / 甲課:20261112,20261110 / 其他:20261114,20261111", "以前的課：依課分組、新的在前、其他放最後")
}

/// 測試用：mainName 的結果寫成字
enum RunNameCheck {
    static func describe(_ value: (stamp: String, stem: String)?) -> String {
        value.map { "\($0.stamp)|\($0.stem)" } ?? "nil"
    }
}
