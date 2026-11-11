import Foundation

// v0.23.1 投影片與課程設定檔（規格 B1、B2）。只用 Foundation，shape_check 也編。
// 每門課一份課程設定檔，讓每門課可以有不同設定：0.23.1 先做最小版——每門課一份，
// 只記這門課的投影片、要不要送 Haiku；不同介面排 v0.24。
// PDF 抽字在 SlideImport.swift（要 PDFKit）；這裡只放資料、檔名、估 token、讀寫 JSON。
// PageTracker（規格 B2、B6）是 0.23.3 的事，之後加在這個檔。PageMark、Stall 只是資料，0.23.2 的 ReviewLog（HaikuFix.swift）要用，先放在檔尾。

/// 一份投影片抽出來的字。pages[0]＝p.1。存在 Documents/投影片/<正式課名>/<檔名>.json。
struct SlideDeck: Codable, Equatable {
    /// 正式課名（CourseSchedule.formalName，例：解析幾何）
    let course: String
    /// 原 PDF 檔名（例：lecture-17.pdf）
    let source: String
    /// 匯入時間 yyyyMMdd-HHmmss
    let importedAt: String
    let pages: [String]
    /// 每頁第一行（最多 40 字），之後頁碼分隔線用
    var titles: [String]
    /// 粗估的 token 數（見 estimateTokens），不是 API 數出來的
    var estimatedTokens: Int

    static func make(course: String, source: String, importedAt: String, pages: [String]) -> SlideDeck {
        let cleaned = pages.map { $0.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
        return SlideDeck(
            course: course,
            source: source,
            importedAt: importedAt,
            pages: cleaned,
            titles: cleaned.map(title(of:)),
            estimatedTokens: estimateTokens(cleaned)
        )
    }

    /// 存檔用的名字：原檔名去掉副檔名、拿掉不能當檔名的字，加 .json（lecture-17.pdf → lecture-17.json）
    static func fileName(source: String) -> String {
        let base = (source as NSString).deletingPathExtension
        return CourseSchedule.folderName(base) + ".json"
    }

    /// 給人看的名字（不含 .pdf）
    var name: String { (source as NSString).deletingPathExtension }

    /// 有字的頁數（掃描檔、純圖片的頁抽不到字）
    var pagesWithText: Int { pages.filter { !$0.isEmpty }.count }

    /// 匯入完成、選單上顯示的那一行：「解析幾何：lecture-17（55 頁）」；有抽不到字的頁另外講
    var summary: String {
        var line = "\(course)：\(name)（\(pages.count) 頁"
        let empty = pages.count - pagesWithText
        if empty > 0 {
            line += "，\(empty) 頁沒有字"
        }
        return line + "）"
    }

    /// 每頁第一行有字的行，最多 40 字
    static func title(of page: String) -> String {
        let first = page.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        return String(first.prefix(40))
    }

    /// 【我推論】粗估：中日韓字一字算 1、英文單字一個算 1.3、其他（數字、符號）每 3 個算 1，每頁另加 4（「[p.N]」和換行）。
    /// 只用來判斷「會不會太大、要不要截」（規格 A 表第 9 點：超過 6 萬不送後面的頁），不拿來算錢。
    static func estimateTokens(_ pages: [String]) -> Int {
        var total = 0.0
        for page in pages {
            var cjk = 0
            var latinWords = 0
            var others = 0
            var inWord = false
            for scalar in page.unicodeScalars {
                let v = scalar.value
                let isCJK = (0x3400...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v) || (0x3000...0x303F).contains(v) || (0xFF00...0xFFEF).contains(v)
                let isLatin = (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) || (0xC0...0x24F).contains(v)
                if isLatin {
                    if !inWord { latinWords += 1 }
                    inWord = true
                    continue
                }
                inWord = false
                if isCJK {
                    cjk += 1
                } else if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    others += 1
                }
            }
            total += Double(cjk) + Double(latinWords) * 1.3 + Double(others) / 3 + 4
        }
        return Int(total.rounded(.up))
    }
}

/// 一門課的設定。存在 Documents/課程設定/<正式課名>.json；沒有檔就是預設（送 Haiku、沒有投影片）。
struct CourseProfile: Codable, Equatable {
    /// 這門課錄音中要不要把稿的字送 Haiku 改字（0.23.2 起才真的送）。私人課程和不在設定檔的課不管這裡寫什麼都不送（allowsUpload）。
    var haiku = true
    /// 這門課目前用的投影片：Documents/投影片/<正式課名>/ 裡的檔名（例：lecture-17.json）；nil＝還沒有
    var slides: String? = nil

    init(haiku: Bool = true, slides: String? = nil) {
        self.haiku = haiku
        self.slides = slides
    }

    /// 少欄位也讀得開（之後加欄位，舊檔照讀）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        haiku = try c.decodeIfPresent(Bool.self, forKey: .haiku) ?? true
        slides = try c.decodeIfPresent(String.self, forKey: .slides)
    }

    /// 私人課程（設定檔標 private，或課名含 privateKeywords）永遠不送 Haiku、不自動上傳；
    /// 沒有課名（不在上課時段、選來的檔）、不在設定檔課表上的課也不送（沒有設定檔時一律不送）。
    /// course 給簡稱或正式課名都可以。
    static func allowsUpload(course: String?) -> Bool {
        guard let course = course?.trimmingCharacters(in: .whitespacesAndNewlines), !course.isEmpty else { return false }
        return CourseSchedule.isKnown(course) && !CourseSchedule.isPrivate(course)
    }

    /// 這門課實際會不會送：課名可以送、而且設定開著
    func sends(course: String?) -> Bool {
        haiku && Self.allowsUpload(course: course)
    }

    /// 設定檔名：正式課名（簡稱會換成正式名）＋ .json
    static func fileName(course: String) -> String {
        CourseSchedule.folderName(CourseSchedule.formalName(course)) + ".json"
    }

    /// root 是 App 的 Documents（測試時給暫存資料夾）
    static func url(course: String, root: URL) -> URL {
        root.appendingPathComponent("課程設定", isDirectory: true).appendingPathComponent(fileName(course: course))
    }

    static func load(course: String, root: URL) -> CourseProfile {
        guard let data = try? Data(contentsOf: url(course: course, root: root)),
              let profile = try? JSONDecoder().decode(CourseProfile.self, from: data) else { return CourseProfile() }
        return profile
    }

    func save(course: String, root: URL) throws {
        let target = Self.url(course: course, root: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: target, options: .atomic)
    }
}

/// 投影片資料夾：Documents/投影片/<正式課名>/
enum SlideStore {
    static func folder(course: String, root: URL) -> URL {
        root.appendingPathComponent("投影片", isDirectory: true)
            .appendingPathComponent(CourseSchedule.folderName(CourseSchedule.formalName(course)), isDirectory: true)
    }

    /// 存一份，並把這門課的設定指到這份（匯入的就是這門課最新的一份）。回傳存好的檔。
    @discardableResult
    static func save(_ deck: SlideDeck, root: URL) throws -> URL {
        let dir = folder(course: deck.course, root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = SlideDeck.fileName(source: deck.source)
        let target = dir.appendingPathComponent(name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(deck).write(to: target, options: .atomic)
        var profile = CourseProfile.load(course: deck.course, root: root)
        profile.slides = name
        try profile.save(course: deck.course, root: root)
        return target
    }

    /// 這門課目前的投影片：設定指的那份；那份不見了就拿資料夾裡匯入時間最新的。都沒有是 nil。
    static func latest(course: String, root: URL) -> SlideDeck? {
        let dir = folder(course: course, root: root)
        if let name = CourseProfile.load(course: course, root: root).slides,
           let deck = load(dir.appendingPathComponent(name)) {
            return deck
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap(load)
            .max { $0.importedAt < $1.importedAt }
    }

    static func load(_ url: URL) -> SlideDeck? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SlideDeck.self, from: data)
    }
}

/// 換頁紀錄（規格 B2）：at＝錄音秒數；source：haiku（Haiku 給、程式驗過依據）／text（程式粗比）；unitID＝那一批第一個單位。
struct PageMark: Codable, Equatable {
    let at: Double
    let page: Int
    let source: String
    let unitID: Int
}

/// 錄音中看門狗記到的停頓（規格 B2、B7）：at＝錄音秒數，lost＝少了幾秒。逐字稿插【錄音停頓】用。
struct Stall: Codable, Equatable {
    let at: Double
    let lost: Double
}
