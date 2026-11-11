import Foundation

/// v0.21 匯出紀錄的檔名與「原始轉錄」格式。
/// 檔名固定、格式一致，其他工具（或協作的 AI）才能照同一套規則找檔、讀檔。
/// 規則和電腦版自動轉錄一致：<匯出資料夾>/<課名>/YYYYMMDD_<課名>_原始轉錄.txt，
/// 每份錄音一個區塊，區塊第一行【YYYY-MM-DD HH:MM 開始（時間來源：…，引擎：…）｜識別】，下一行起是原文，區塊之間空一行。
/// 課名用正式全名（CourseSchedule.formalName），畫面標題和 App 裡的資料夾照舊用簡稱。
/// 只用 Foundation：雲端編譯前的 shape_check 也編這個檔來測。
enum ClassRecord {
    /// 不在上課時段（或選來的檔）
    static let unclassified = "未分類"

    /// 檔名用的課名：正式全名；沒有課名是未分類。拿掉檔名不能有的字。
    static func courseName(_ short: String?) -> String {
        guard let short, !short.isEmpty else { return unclassified }
        return CourseSchedule.folderName(CourseSchedule.formalName(short))
    }

    /// yyyyMMdd-HHmmss 的前 8 碼
    static func day(_ stamp: String) -> String {
        let c = Array(stamp)
        guard c.count == 15 else { return String(stamp.prefix(8)) }
        return String(c[0..<8])
    }

    /// yyyyMMdd-HHmmss 的時分（HHMM）
    static func hourMinute(_ stamp: String) -> String {
        let c = Array(stamp)
        guard c.count == 15 else { return "0000" }
        return String(c[9..<13])
    }

    /// 20261109-092140 → 2026-11-09 09:21
    static func readable(_ stamp: String) -> String {
        let c = Array(stamp)
        guard c.count == 15 else { return stamp }
        return "\(String(c[0..<4]))-\(String(c[4..<6]))-\(String(c[6..<8])) \(String(c[9..<11])):\(String(c[11..<13]))"
    }

    /// YYYYMMDD_<課名>_原始轉錄.txt；日期＝錄音開始那天
    static func rawFileName(stamp: String, course: String?) -> String {
        "\(day(stamp))_\(courseName(course))_原始轉錄.txt"
    }

    enum Export {
        case session, withAudio, errors

        var label: String {
            switch self {
            case .session: return "App匯出"
            case .withAudio: return "App匯出含錄音"
            case .errors: return "錯誤資料"
            }
        }

        var ext: String { self == .errors ? "txt" : "zip" }
    }

    /// YYYYMMDD_<課名>_App匯出_HHMM.zip、…_App匯出含錄音_HHMM.zip、…_錯誤資料_HHMM.txt；HHMM＝錄音開始時間
    static func exportFileName(_ kind: Export, stamp: String, course: String?) -> String {
        "\(day(stamp))_\(courseName(course))_\(kind.label)_\(hourMinute(stamp)).\(kind.ext)"
    }

    // MARK: 原始轉錄的內容

    /// 續錄的分隔行（PartJoin.divider）
    private static let dividerPattern = try? NSRegularExpression(pattern: "^——續錄第 ([0-9]+) 段，從 .+ 起——$")

    private static func isDivider(_ line: String) -> Bool {
        guard let pattern = dividerPattern else { return false }
        return pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// 稿拆成各段（照續錄分隔行切），每段拿掉〔…〕校正標註、去掉頭尾空行；講者標籤（A：）留著。
    static func parts(of text: String) -> [String] {
        var result: [[String]] = [[]]
        for line in text.components(separatedBy: "\n") {
            if isDivider(line.trimmingCharacters(in: .whitespaces)) {
                result.append([])
            } else {
                result[result.count - 1].append(line)
            }
        }
        return result.map { lines in
            TextMarker.strip(lines.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// 各段開始時間（yyyyMMdd-HHmmss）。v0.21 起存在稿裡（stored）；舊稿從各步紀錄找「HH:mm:ss 續錄第 N 段，從 … 接著錄」
    /// （同一段有好幾行取最後一次：續錄沒開成又按了一次）。紀錄只有時:分:秒：日期從第一段那天往後推，時間倒退就是過了半夜，加一天。
    /// 有一段找不到就 nil（整場一個區塊）。
    static func partStarts(stored: [String]?, first: String, count: Int, log: [String]) -> [String]? {
        if let stored, stored.count == count, stored.allSatisfy({ $0.count == 15 }) { return stored }
        guard count >= 1, first.count == 15 else { return nil }
        if count == 1 { return [first] }
        guard let pattern = try? NSRegularExpression(pattern: "^([0-9]{2}):([0-9]{2}):([0-9]{2}) 續錄第 ([0-9]+) 段，從 ") else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone   // 只拿來加日期，不換時區
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyyMMdd-HHmmss"
        guard var current = parser.date(from: first) else { return nil }
        var found: [Int: String] = [:]
        for line in log {
            let ns = line as NSString
            let clock = line.prefix(8)
            guard clock.count == 8, clock.allSatisfy({ $0.isNumber || $0 == ":" }) else { continue }
            let parts = clock.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 3 else { continue }
            // 每一行都往前推日期（紀錄照時間順序）
            let day = String(parser.string(from: current).prefix(9))
            let candidate = parser.date(from: day + String(format: "%02d%02d%02d", parts[0], parts[1], parts[2]))
            if var next = candidate {
                if next < current.addingTimeInterval(-60) {
                    next = calendar.date(byAdding: .day, value: 1, to: next) ?? next
                }
                if next > current { current = next }
            }
            if let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               let part = Int(ns.substring(with: match.range(at: 4))), part >= 2, part <= count {
                found[part] = parser.string(from: current)
            }
        }
        var result = [first]
        for part in 2...count {
            guard let stamp = found[part] else { return nil }
            result.append(stamp)
        }
        return result
    }

    /// 原始轉錄 txt 的內容。
    /// id：這一場的識別（App 錄的是錄音開始的時間 20261109-092140）；engine：「iPhone 轉文字 0.21.24」；
    /// firstSource：第 1 段的時間來源（App 錄音／選來的檔轉成文字的時間／連電腦）。續錄的第 2 段起一定是 App 錄音。
    static func rawTranscript(text: String, id: String, starts: [String]?, partCount: Int,
                              engine: String, firstSource: String = "App 錄音") -> String {
        let pieces = parts(of: text)
        let count = max(partCount, pieces.count)
        if let starts, starts.count == pieces.count, pieces.count == count {
            let blocks = pieces.enumerated().map { index, body -> String in
                let source = index == 0 ? firstSource : "App 錄音"
                return "【\(readable(starts[index])) 開始（時間來源：\(source)，引擎：\(engine)）｜\(id) 第\(index + 1)段】\n\(body)"
            }
            return blocks.joined(separator: "\n\n") + "\n"
        }
        // 各段時間對不起來：整場一個區塊
        let first = starts?.first ?? id
        let label = count > 1 ? "第1–\(count)段" : "第1段"
        var block = "【\(readable(first)) 開始（時間來源：\(firstSource)，引擎：\(engine)）｜\(id) \(label)】\n"
        if count > 1 {
            block += "〔共 \(count) 段，各段時間沒有紀錄〕\n"
        }
        block += pieces.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return block + "\n"
    }
}

/// v0.21 錄音中就能複製：即時轉錄的用處就是邊錄邊拿到字。
/// 錄音中的 run.text 已經是整場累積的字（續錄時＝前面各段的稿＋分隔行＋這段），畫面只顯示最後 3000 字（recordingTail）；
/// 複製用 run.text 全部，再接上灰字（引擎還可能改的字），和畫面看到的順序一樣。
enum LiveCopy {
    static func join(final: String, volatile: String) -> String {
        final + volatile
    }

    /// 0.23.3：在稿頭（開頭「---」到下一個「---」之間）最後加一行；沒有稿頭或 line 是空的就原樣回傳
    static func addHeaderLine(_ document: String, line: String) -> String {
        guard !line.isEmpty, document.hasPrefix("---\n"),
              let end = document.range(of: "\n---", range: document.index(document.startIndex, offsetBy: 3)..<document.endIndex)
        else { return document }
        var out = document
        out.insert(contentsOf: "\n" + line, at: end.lowerBound)
        return out
    }

    /// 稿頭「注意」那行：錄音中、複製到哪裡
    static func statusLine(at seconds: Double) -> String {
        "注意：錄音中，到 \(formatStamp(seconds))（複製當下的字；還在錄，最後幾句引擎還可能改，按停止後會再定稿一次）"
    }
}
