import Foundation

// v0.27.1 純邏輯（只用 Foundation，shape_check 也編；tools/shape_check/session_tests.swift）：
// 停止後分享的檔名與逐字稿內容（照固定檔名規則：YYYYMMDD_<課名>_逐字稿.md、YYYYMMDD_<課名>_重點.pdf）、
// 卡片 PDF 的排版算法（A4、分頁、圖縮放）、「以前的課」清單（從逐字稿資料夾的檔讀回、依課分組、新的在前）。
// PDF 實際畫在 CardsPDF.swift，清單畫面在 HistoryViews.swift。

// MARK: - 停止後分享的檔

enum SessionExport {
    /// 檔名用的日期：錄音開始那天（App 錄的檔名就是按下錄音的時間）；選來的檔用轉成文字那天
    static func stamp(recorded: String?, started: String) -> String {
        recorded ?? started
    }

    /// YYYYMMDD_<課名>_逐字稿.md（課名用正式全名；沒有課名＝未分類）
    static func transcriptName(stamp: String, course: String?) -> String {
        "\(ClassRecord.day(stamp))_\(ClassRecord.courseName(course))_逐字稿.md"
    }

    /// YYYYMMDD_<課名>_重點.pdf（每張卡的重點、整理版、逐字稿、重查、投影片那一頁）
    static func cardsPDFName(stamp: String, course: String?) -> String {
        "\(ClassRecord.day(stamp))_\(ClassRecord.courseName(course))_重點.pdf"
    }

    /// 逐字稿 md：照固定的逐字稿格式寫稿頭；內文有分人＝整份（A：…），否則每張卡一節（時間、頁碼）。
    /// slides＝這場用的投影片名字（nil＝沒有）。
    static func transcriptDocument(stamp: String, course: String?, device: String, slides: String?,
                                   cards: [LiveCard], speakerText: String?) -> String {
        let name = ClassRecord.courseName(course)
        let pages = cards.contains { $0.page != nil }
        var lines = [
            "# \(ClassRecord.day(stamp)) \(name) 逐字稿",
            "",
            "- 來源：轉文字 App（\(device)）錄音 \(ClassRecord.readable(stamp)) 開始；Whisper 主稿，Claude Haiku 每 60 秒整理一張卡",
            "- 校正依據：" + (slides.map { "投影片 \($0)" } ?? "沒有"),
            "- 處理說明：Haiku 擴寫式校正（只改聽錯的字、補標點，不摘要）；使用者在錄音中改的行、Pencil 重查改的字已套用；沒整理到的卡用 Whisper 原字",
            "- 投影片頁碼：" + (pages ? "每節標題的 p.N" : "未標註"),
            "",
            "---",
            "",
        ]
        if let speakerText, !speakerText.isEmpty {
            lines.append(speakerText.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            for card in cards.sorted(by: { $0.start < $1.start }) {
                let body = card.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                lines.append("## " + CardText.range(card) + (card.page.map { "　p.\($0)" } ?? ""))
                lines.append("")
                lines.append(CardDiff.lines(body))
                lines.append("")
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

// MARK: - 卡片 PDF 的排版

enum CardsPDFLayout {
    /// A4 直式（點）
    static let pageWidth = 595.2
    static let pageHeight = 841.8
    static let margin = 48.0
    /// 投影片圖最大邊（像素）、JPEG 品質
    static let maxPixels = 1600.0
    static let jpegQuality = 0.6

    static var contentWidth: Double { pageWidth - margin * 2 }
    static var contentHeight: Double { pageHeight - margin * 2 }

    /// 圖縮到寬 maxWidth 以內、高 maxHeight 以內（不放大），保持比例
    static func fit(width: Double, height: Double, maxWidth: Double, maxHeight: Double) -> (width: Double, height: Double) {
        guard width > 0, height > 0 else { return (0, 0) }
        let scale = min(1, maxWidth / width, maxHeight / height)
        return (width * scale, height * scale)
    }

    /// 存進 PDF 的圖縮到最大邊 maxPixels（不放大）
    static func pixelSize(width: Double, height: Double) -> (width: Double, height: Double) {
        fit(width: width, height: height, maxWidth: maxPixels, maxHeight: maxPixels)
    }

    /// 由上往下排一塊塊（每塊的高度、塊之後的間距）：放不下就換頁；比一頁還高的塊自己一頁（從頁頂開始）。
    /// 回傳每塊在第幾頁（0 起）、頁內的 y（從內容區頂端算）。keepWithNext＝這塊要和下一塊同一頁（標題不要落單在頁底）。
    struct Block: Equatable {
        var height: Double
        var gap: Double
        var keepWithNext = false
    }

    static func paginate(_ blocks: [Block], pageHeight: Double = CardsPDFLayout.contentHeight) -> [(page: Int, y: Double)] {
        var out: [(page: Int, y: Double)] = []
        var page = 0
        var y = 0.0
        for (i, block) in blocks.enumerated() {
            var need = block.height
            if block.keepWithNext, i + 1 < blocks.count {
                need += block.gap + min(blocks[i + 1].height, pageHeight)
            }
            if y > 0, y + need > pageHeight {
                page += 1
                y = 0
            }
            out.append((page, y))
            y += block.height + block.gap
            if y > pageHeight {
                // 比一頁還高的塊：下一塊從新的一頁開始
                page += 1
                y = 0
            }
        }
        return out
    }

    /// 總頁數
    static func pageCount(_ placed: [(page: Int, y: Double)]) -> Int {
        (placed.map(\.page).max() ?? -1) + 1
    }
}

// MARK: - 以前的課

/// 從逐字稿資料夾一份稿（.txt）讀回來的摘要（打開時再換成 SavedRun）
struct RunEntry: Equatable {
    /// 檔名前面的時間（yyyyMMdd-HHmmss，＝ SavedRun.startedStamp）
    var startedStamp: String
    /// 檔名後面的來源（錄音檔名去掉副檔名）
    var sourceStem: String
    /// 課名子資料夾（nil＝逐字稿資料夾最上層）
    var course: String?
    var title: String
    var audioSeconds: Double?
    var speakers: [String]
    /// 續錄過的各段錄音檔名（稿頭「錄音：共 N 段（…）」）
    var parts: [String]?
    var finished: Bool
    var origin: String?
    /// 稿的字（稿頭和最後的校正附錄拿掉）
    var text: String
    /// v0.27.0 起存的場景（lecture／discussion／chat）；舊稿 nil
    var scene: String?

    /// 錄音開始的時間：來源檔名是時間就用它（App 錄的），否則用轉成文字的時間
    var recordedStamp: String? {
        RunCatalog.isStamp(sourceStem) ? sourceStem : nil
    }

    var sortStamp: String { recordedStamp ?? startedStamp }

    /// 清單用的識別（同一個資料夾裡不會重複）
    var key: String { (course ?? "") + "/" + startedStamp + " " + sourceStem }
}

enum RunCatalog {
    static let other = "其他"
    /// 稿頭一定是這樣開始（SavedRun.document）
    static let headPrefix = "---\n標題："

    static func isStamp(_ text: String) -> Bool {
        let c = Array(text)
        guard c.count == 15, c[8] == "-" else { return false }
        return c.enumerated().allSatisfy { $0.offset == 8 || $0.element.isASCII && $0.element.isNumber }
    }

    /// 這個檔名是不是一場的主稿：「yyyyMMdd-HHmmss 來源.txt」，而且不是附屬檔（原文、即時稿、Whisper…）
    static func mainName(_ fileName: String) -> (stamp: String, stem: String)? {
        guard fileName.hasSuffix(".txt"), !fileName.hasPrefix(".") else { return nil }
        let base = String(fileName.dropLast(4))
        let c = Array(base)
        guard c.count > 16, c[15] == " " else { return nil }
        let stamp = String(c[0..<15])
        let stem = String(c[16...])
        guard isStamp(stamp), !stem.isEmpty else { return nil }
        for tail in [" 原文", " 即時稿", " Whisper即時", " Whisper稿", " 原始轉錄"] where stem.hasSuffix(tail) {
            return nil
        }
        return (stamp, stem)
    }

    /// 「12:34」「1:02:03」→ 秒數
    static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return Double(parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 })
    }

    /// 稿（SavedRun.document 的格式）讀回來；不是主稿（沒有稿頭）＝nil
    static func parse(fileName: String, course: String?, document: String) -> RunEntry? {
        guard let name = mainName(fileName), document.hasPrefix(headPrefix) else { return nil }
        let afterOpen = document.index(document.startIndex, offsetBy: 4)
        guard let close = document.range(of: "\n---\n", range: afterOpen..<document.endIndex) else { return nil }
        let head = String(document[afterOpen..<close.lowerBound]).components(separatedBy: "\n")
        var body = String(document[close.upperBound...])
        // 最後的附錄（校正紀錄、離線校正提示、智慧校正）不是稿的字
        for marker in ["\n\n---\n校正紀錄", "\n\n---\n離線校正提示", "\n\n---\n智慧校正"] {
            if let range = body.range(of: marker) {
                body = String(body[..<range.lowerBound])
            }
        }
        var entry = RunEntry(startedStamp: name.stamp, sourceStem: name.stem, course: course, title: "", audioSeconds: nil,
                             speakers: [], parts: nil, finished: true, origin: nil, text: body, scene: nil)
        for line in head {
            if line.hasPrefix("標題：") {
                var title = String(line.dropFirst(3))
                if let auto = title.range(of: "（照課表自動命名）") {
                    title = String(title[..<auto.lowerBound])
                }
                entry.title = title
            } else if line.hasPrefix("時長：") {
                let value = String(line.dropFirst(3)).components(separatedBy: "（").first ?? ""
                entry.audioSeconds = seconds(value)
            } else if line.hasPrefix("講者："), !line.hasPrefix("講者：沒有分人") {
                let list = String(line.dropFirst(3)).components(separatedBy: "（").first ?? ""
                entry.speakers = list.components(separatedBy: "、").filter { !$0.isEmpty }
            } else if line.hasPrefix("錄音：共 "), let open = line.firstIndex(of: "（"), let end = line.firstIndex(of: "）"), open < end {
                let names = String(line[line.index(after: open)..<end]).components(separatedBy: "、").filter { !$0.isEmpty }
                entry.parts = names.count > 1 ? names : nil
            } else if line.hasPrefix("注意：這份沒有轉完") {
                entry.finished = false
            } else if line.hasPrefix("來源：") {
                let value = String(line.dropFirst(3))
                if !value.hasPrefix(name.stem) { entry.origin = value }
            } else if line.hasPrefix("場景：") {
                entry.scene = RecordScene.allCases.first { $0.title == String(line.dropFirst(3)) }?.rawValue
            }
        }
        return entry
    }

    /// 依課分組（沒有課名＝其他，放最後），組內新的在前；組依最新一場排，新的在前
    static func group(_ entries: [RunEntry]) -> [(course: String, entries: [RunEntry])] {
        var groups: [String: [RunEntry]] = [:]
        for entry in entries {
            let key = (entry.course ?? "").isEmpty ? other : entry.course!
            groups[key, default: []].append(entry)
        }
        let sorted = groups.map { key, list in
            (course: key, entries: list.sorted { ($0.sortStamp, $0.startedStamp) > ($1.sortStamp, $1.startedStamp) })
        }
        return sorted.sorted { a, b in
            if (a.course == other) != (b.course == other) { return b.course == other }
            return (a.entries.first?.sortStamp ?? "") > (b.entries.first?.sortStamp ?? "")
        }
    }

    /// 清單一列：「11/13 09:15　幾何　52:10　上課」（沒有的不寫）
    static func rowText(_ entry: RunEntry) -> String {
        let stamp = entry.sortStamp
        let c = Array(stamp)
        var parts: [String] = []
        if c.count == 15, let month = Int(String(c[4..<6])), let day = Int(String(c[6..<8])) {
            parts.append("\(month)/\(day) \(String(c[9..<11])):\(String(c[11..<13]))")
        }
        if let course = entry.course, !course.isEmpty { parts.append(course) }
        if let seconds = entry.audioSeconds { parts.append(formatStamp(seconds)) }
        if let scene = entry.scene.flatMap(RecordScene.init(rawValue:)) { parts.append(scene.title) }
        return parts.joined(separator: "　")
    }
}
