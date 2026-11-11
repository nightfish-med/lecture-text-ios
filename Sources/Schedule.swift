import Foundation

/// 使用者自己的課表、停課日、私人課程、課程對照表：程式裡不寫任何課名，執行時從
/// Documents/設定/轉文字設定.json 讀（「檔案」App 看得到；也可以從分享選單把同名 .json 丟進 App）。
/// 沒有這個檔＝沒有課表（錄音用時間命名）、沒有課程對照表、沒有課可以送 Haiku 或自動上傳；其他功能照常。
/// 格式見 README。不放 MainActor、只用 Foundation：雲端編譯前的 shape_check 也會編這個檔來測。
struct AppSettings: Codable, Equatable {
    struct Course: Codable, Equatable {
        /// 畫面標題和資料夾用的簡稱（舊檔都放在這個名字的資料夾，改了舊檔就對不上）
        var name: String
        /// 正式課名，只用在匯出檔名和課程設定檔名；nil＝和 name 一樣
        var formal: String? = nil
        /// 1＝週一 … 7＝週日
        var weekday: Int
        /// "HH:mm"
        var from: String
        var to: String
        /// 只有這幾週上（第 1 週＝firstDay 那週）；nil 是每週
        var weeks: [Int]? = nil
        /// 私人課程：永遠不送 Haiku、不自動上傳、不出現在投影片選課
        var isPrivate = false

        enum CodingKeys: String, CodingKey {
            case name, formal, weekday, from, to, weeks
            case isPrivate = "private"
        }

        init(name: String, formal: String? = nil, weekday: Int, from: String, to: String,
             weeks: [Int]? = nil, isPrivate: Bool = false) {
            self.name = name
            self.formal = formal
            self.weekday = weekday
            self.from = from
            self.to = to
            self.weeks = weeks
            self.isPrivate = isPrivate
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            formal = try c.decodeIfPresent(String.self, forKey: .formal)
            weekday = try c.decode(Int.self, forKey: .weekday)
            from = try c.decode(String.self, forKey: .from)
            to = try c.decode(String.self, forKey: .to)
            weeks = try c.decodeIfPresent([Int].self, forKey: .weeks)
            isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        }
    }

    /// 第 1 週的週一（yyyy-MM-dd）；nil＝不限開始日、單週課（weeks）不排
    var firstDay: String? = nil
    /// 課表最後一天；之後一律用時間當名字。nil＝不過期
    var lastDay: String? = nil
    /// 錄音開始時間在上課前後幾分鐘內都算這堂課
    var toleranceMinutes = 10
    var courses: [Course] = []
    /// 停課日：空陣列＝整天沒課，否則只有這幾門（簡稱）停
    var offDays: [String: [String]] = [:]
    /// 課名（簡稱或正式名）含這些字就當私人課程，不在課表上的名字也擋
    var privateKeywords: [String] = []
    /// 課程對照表：key 是正式課名，每條是 [稿裡常見的錯, 正確]
    var liveFix: [String: [[String]]] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firstDay = try c.decodeIfPresent(String.self, forKey: .firstDay)
        lastDay = try c.decodeIfPresent(String.self, forKey: .lastDay)
        toleranceMinutes = try c.decodeIfPresent(Int.self, forKey: .toleranceMinutes) ?? 10
        courses = try c.decodeIfPresent([Course].self, forKey: .courses) ?? []
        offDays = try c.decodeIfPresent([String: [String]].self, forKey: .offDays) ?? [:]
        privateKeywords = try c.decodeIfPresent([String].self, forKey: .privateKeywords) ?? []
        liveFix = try c.decodeIfPresent([String: [[String]]].self, forKey: .liveFix) ?? [:]
    }

    /// 這次 App 用的設定（沒有設定檔就是空的）。改這個值時順便換好對照表。
    static var current = AppSettings() {
        didSet { rulesByCourse = current.makeRules() }
    }
    /// 課程對照表換成規則（LiveFix.byCourse 讀這裡）
    private(set) static var rulesByCourse: [String: [LiveFixRule]] = [:]

    private func makeRules() -> [String: [LiveFixRule]] {
        liveFix.mapValues { pairs in
            pairs.compactMap { pair in pair.count == 2 ? LiveFixRule(wrong: pair[0], right: pair[1]) : nil }
        }
    }

    static let folderName = "設定"
    static let fileName = "轉文字設定.json"

    /// root 是 App 的 Documents（測試時給暫存資料夾）
    static func url(root: URL) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(fileName)
    }

    enum Problem: Error, LocalizedError, Equatable {
        case unreadable(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "設定檔讀不懂：\(why)"
            case .invalid(let why): return "設定檔有錯：\(why)"
            }
        }
    }

    private static func isClock(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]) else { return false }
        return (0...23).contains(h) && (0...59).contains(m)
    }

    /// 解開並檢查。課名空的、星期不是 1–7、時間不是 HH:mm、日期不是 yyyy-MM-dd、對照表一條不是兩個字串：整份不收，講是哪裡。
    static func decode(_ data: Data) throws -> AppSettings {
        let settings: AppSettings
        do {
            settings = try JSONDecoder().decode(AppSettings.self, from: data)
        } catch DecodingError.keyNotFound(let key, let context) {
            throw Problem.unreadable("少了 \(key.stringValue)（\(context.codingPath.map(\.stringValue).joined(separator: "."))）")
        } catch DecodingError.typeMismatch(_, let context) {
            throw Problem.unreadable("型別不對（\(context.codingPath.map(\.stringValue).joined(separator: "."))）")
        } catch {
            throw Problem.unreadable("不是 JSON 或格式不對")
        }
        for day in [settings.firstDay, settings.lastDay].compactMap({ $0 }) where CourseSchedule.dayParts(day) == nil {
            throw Problem.invalid("日期「\(day)」要寫成 yyyy-MM-dd")
        }
        for (index, course) in settings.courses.enumerated() {
            let label = "courses 第 \(index + 1) 筆"
            if course.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw Problem.invalid("\(label) 沒有課名") }
            if !(1...7).contains(course.weekday) { throw Problem.invalid("\(label) 的 weekday 要是 1–7") }
            if !isClock(course.from) || !isClock(course.to) { throw Problem.invalid("\(label) 的時間要寫成 HH:mm") }
        }
        for day in settings.offDays.keys where CourseSchedule.dayParts(day) == nil {
            throw Problem.invalid("停課日「\(day)」要寫成 yyyy-MM-dd")
        }
        for (course, pairs) in settings.liveFix {
            for pair in pairs where pair.count != 2 || pair[0].isEmpty {
                throw Problem.invalid("對照表「\(course)」有一條不是 [錯字, 正確]")
            }
        }
        return settings
    }

    enum LoadResult: Equatable {
        case missing
        case loaded(courses: Int, rules: Int)
        case failed(String)

        /// 寫進紀錄、橫幅的一行（不寫課名）
        var line: String {
            switch self {
            case .missing: return "設定檔：沒有（不照課表命名、沒有課程對照表）"
            case .loaded(let courses, let rules): return "設定檔：課表 \(courses) 筆、課程對照表 \(rules) 條"
            case .failed(let why): return "設定檔：沒有套用（\(why)）"
            }
        }
    }

    private func counts() -> LoadResult {
        .loaded(courses: courses.count, rules: liveFix.values.reduce(0) { $0 + $1.count })
    }

    /// 讀 Documents/設定/轉文字設定.json 換掉 current。沒有檔、讀不懂都換成空的設定（不沿用上一次的）。
    @discardableResult
    static func reload(root: URL) -> LoadResult {
        guard let data = try? Data(contentsOf: url(root: root)) else {
            current = AppSettings()
            return .missing
        }
        do {
            current = try decode(data)
            return current.counts()
        } catch {
            current = AppSettings()
            return .failed(error.localizedDescription)
        }
    }

    /// 從分享選單或「選檔案」丟進來的設定檔：先檢查，過了才存成 Documents/設定/轉文字設定.json（蓋掉舊的）並套用。
    /// 檢查沒過就丟錯，舊的設定檔和 current 都不動。
    static func install(_ data: Data, root: URL) throws -> LoadResult {
        let settings = try decode(data)
        let target = url(root: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        current = settings
        return settings.counts()
    }
}

/// v0.14：照課表自動命名；不在上課時段照舊用時間。課表來自 AppSettings（設定檔），程式裡沒有課名。
enum CourseSchedule {
    struct Slot {
        /// 畫面標題和資料夾用的簡稱
        let name: String
        /// 1＝週一 … 7＝週日
        let weekday: Int
        let from: String
        let to: String
        /// 只有這幾週上（單週課）；nil 是每週
        var weeks: [Int]? = nil
        /// v0.21：正式課名，只用在匯出檔名（<課名>/YYYYMMDD_<課名>_原始轉錄.txt）；nil＝和 name 一樣
        var formal: String? = nil
        /// 私人課程：不送 Haiku、不自動上傳
        var isPrivate = false
    }

    static var firstDay: String? { AppSettings.current.firstDay }
    static var lastDay: String? { AppSettings.current.lastDay }
    static var toleranceMinutes: Int { AppSettings.current.toleranceMinutes }

    static var slots: [Slot] {
        AppSettings.current.courses.map {
            Slot(name: $0.name, weekday: $0.weekday, from: $0.from, to: $0.to, weeks: $0.weeks, formal: $0.formal, isPrivate: $0.isPrivate)
        }
    }

    /// 停課日：空陣列＝整天沒課，否則只有這幾門停
    static var offDays: [String: [String]] { AppSettings.current.offDays }

    private static func minutes(_ clock: String) -> Int {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : 0
    }

    /// "2026-09-07" → (2026, 9, 7)；格式不對是 nil
    static func dayParts(_ text: String) -> (year: Int, month: Int, day: Int)? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        return (y, m, d)
    }

    /// 這個時間是哪一堂課；不在任何一堂的前後 toleranceMinutes 分鐘內就是 nil。
    /// 兩堂都在範圍內（前一堂剛下課、下一堂快開始）取離得近的；一樣近取下一堂（通常是為下一堂先按錄音）。
    static func course(at date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String? {
        let settings = AppSettings.current
        guard !settings.courses.isEmpty else { return nil }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
        guard let y = c.year, let m = c.month, let d = c.day,
              let hour = c.hour, let minute = c.minute, let wd = c.weekday else { return nil }
        let day = String(format: "%04d-%02d-%02d", y, m, d)
        if let first = settings.firstDay, day < first { return nil }
        if let last = settings.lastDay, day > last { return nil }
        let weekday = wd == 1 ? 7 : wd - 1
        // 第幾週從設定檔的 firstDay 算；沒有 firstDay 時單週課（weeks）不排
        var week: Int?
        if let first = settings.firstDay.flatMap(dayParts),
           let start = calendar.date(from: DateComponents(year: first.year, month: first.month, day: first.day)),
           let today = calendar.date(from: DateComponents(year: y, month: m, day: d)),
           let days = calendar.dateComponents([.day], from: start, to: today).day {
            week = days / 7 + 1
        }
        let now = hour * 60 + minute
        let off = settings.offDays[day]
        var best: (name: String, distance: Int, start: Int)?
        for slot in slots where slot.weekday == weekday {
            if let weeks = slot.weeks {
                guard let week, weeks.contains(week) else { continue }
            }
            if let off, off.isEmpty || off.contains(slot.name) { continue }
            let s = minutes(slot.from)
            let e = minutes(slot.to)
            let distance = now < s ? s - now : (now > e ? now - e : 0)
            guard distance <= settings.toleranceMinutes else { continue }
            if let current = best, distance > current.distance || (distance == current.distance && s < current.start) {
                continue
            }
            best = (slot.name, distance, s)
        }
        return best?.name
    }

    /// 標題：有課是「11/10 幾何」，沒課是「11/10 10:20」。stamp 是 yyyyMMdd-HHmmss。
    static func title(stamp: String, course: String?) -> String {
        let c = Array(stamp)
        guard c.count == 15, let month = Int(String(c[4..<6])), let day = Int(String(c[6..<8])) else {
            return course ?? stamp
        }
        if let course, !course.isEmpty {
            return "\(month)/\(day) \(course)"
        }
        return "\(month)/\(day) \(String(c[9..<11])):\(String(c[11..<13]))"
    }

    /// v0.21：簡稱換正式課名（匯出檔名要和電腦版自動轉錄一致）。課表上沒有的名字照原樣。
    static func formalName(_ short: String) -> String {
        guard let slot = slots.first(where: { $0.name == short }) else { return short }
        return slot.formal ?? slot.name
    }

    /// 簡稱或正式課名是不是設定檔課表上的課
    static func isKnown(_ course: String) -> Bool {
        slots.contains { $0.name == course || ($0.formal ?? $0.name) == course }
    }

    /// 私人課程：課表上標 private 的課（簡稱或正式名），或課名含 privateKeywords 裡的字
    static func isPrivate(_ course: String) -> Bool {
        if slots.contains(where: { $0.isPrivate && ($0.name == course || ($0.formal ?? $0.name) == course) }) { return true }
        let formal = formalName(course)
        return AppSettings.current.privateKeywords.contains { !$0.isEmpty && (course.contains($0) || formal.contains($0)) }
    }

    /// 當資料夾名字用：拿掉檔名不能有的字。
    static func folderName(_ course: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|")
        let cleaned = course.components(separatedBy: bad).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "其他" : cleaned
    }
}
