import Foundation

// v0.23.4 實驗模式（純邏輯，不碰畫面、不連網；shape_check 用 tools/shape_check/main.swift 測）。
// 把模擬做成一種模式：選一個語音檔就自動依序跑完。
// 同一個錄音檔給幾個引擎各轉一次，算出能比的數字，存成一個資料夾（檔案 App › 轉文字 › 實驗）。
// 沒有人工參考稿時算不出錯字率；這裡只算「彼此一致的程度」和「關鍵字出現幾次」，錯字率要等人工批改。

/// 從投影片和課程對照表挑關鍵字（給 Apple 的 contextualStrings、Whisper 的提示詞）。
enum LabKeywords {
    /// 常見英文虛詞，不當關鍵字
    static let stop: Set<String> = [
        "the", "and", "for", "are", "with", "that", "this", "from", "can", "not", "but", "has", "have", "was", "were",
        "its", "into", "than", "then", "there", "these", "those", "their", "which", "when", "where", "what", "will",
        "would", "should", "could", "also", "more", "most", "such", "only", "each", "other", "some", "any", "all",
        "one", "two", "three", "use", "used", "using", "via", "per", "may", "how", "why", "who", "our", "you", "your",
        "they", "them", "been", "being", "does", "did", "very", "about", "between", "both", "same", "like", "eg", "ie",
        "fig", "figure", "table", "chapter", "example", "page", "see", "note",
    ]

    /// 投影片裡的英文詞（3 個字母以上），保留原本的大小寫順序
    static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            if ch.isASCII, ch.isLetter || (ch == "-" && !current.isEmpty) {
                current.append(ch)
            } else {
                if current.count >= 3 { out.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "-"))) }
                current = ""
            }
        }
        if current.count >= 3 { out.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "-"))) }
        return out
    }

    /// 挑法：課程對照表右邊的詞先放；再放投影片裡出現 ≥2 次的兩字詞組（row space）；再放出現 ≥2 次的單字。
    /// 都照出現次數多到少，同次數照第一次出現的順序；不分大小寫去重複；最多 limit 個。
    static func pick(pages: [String], glossaryRights: [String], limit: Int = 100) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        func add(_ s: String) {
            let key = s.lowercased()
            guard out.count < limit, !s.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            out.append(s)
        }
        for r in glossaryRights { add(r) }
        var single: [String: (count: Int, first: Int, show: String)] = [:]
        var double: [String: (count: Int, first: Int, show: String)] = [:]
        var order = 0
        for page in pages {
            for line in page.components(separatedBy: .newlines) {
                let ws = words(line)
                for (i, w) in ws.enumerated() {
                    order += 1
                    let key = w.lowercased()
                    if !stop.contains(key) {
                        let old = single[key]
                        single[key] = ((old?.count ?? 0) + 1, old?.first ?? order, old?.show ?? w)
                    }
                    if i + 1 < ws.count {
                        let next = ws[i + 1]
                        let a = key, b = next.lowercased()
                        if !stop.contains(a), !stop.contains(b) {
                            let k2 = a + " " + b
                            let old = double[k2]
                            double[k2] = ((old?.count ?? 0) + 1, old?.first ?? order, old?.show ?? (w + " " + next))
                        }
                    }
                }
            }
        }
        func ranked(_ d: [String: (count: Int, first: Int, show: String)]) -> [String] {
            d.values.filter { $0.count >= 2 }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.first < $1.first }
                .map(\.show)
        }
        for s in ranked(double) { add(s) }
        for s in ranked(single) { add(s) }
        return out
    }
}

/// 比較用的數字
enum LabMetrics {
    /// 比較前的正規化：去空白和標點、英文轉小寫（字形差、標點差不算不一致）
    static func normalize(_ s: String) -> [Character] {
        s.lowercased().filter { ch in
            guard !ch.isWhitespace, let scalar = ch.unicodeScalars.first else { return false }
            return !CharacterSet.punctuationCharacters.contains(scalar) && !CharacterSet.symbols.contains(scalar)
        }.map { $0 }
    }

    /// 編輯距離（兩列，記憶體只要兩條陣列）
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = [Int32](0...Int32(b.count))
        var cur = [Int32](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = Int32(i)
            let ai = a[i - 1]
            for j in 1...b.count {
                let cost: Int32 = ai == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return Int(prev[b.count])
    }

    /// 一致度＝1 − 編輯距離 ÷ 較長那份的字數（兩份都空算 1）
    static func agreement(_ a: String, _ b: String) -> Double {
        let x = normalize(a), y = normalize(b)
        let n = max(x.count, y.count)
        return n == 0 ? 1 : 1 - Double(distance(x, y)) / Double(n)
    }

    /// 每個關鍵字在稿裡出現幾次（不分大小寫）
    static func hits(_ text: String, keywords: [String]) -> [Int] {
        let low = text.lowercased()
        return keywords.map { k in
            let key = k.lowercased()
            guard !key.isEmpty else { return 0 }
            return low.components(separatedBy: key).count - 1
        }
    }

    /// 英文字（3 個字母以上）有幾個
    static func latinWords(_ text: String) -> Int { LabKeywords.words(text).count }
}

/// 一個引擎的結果
struct LabResult {
    let name: String
    let note: String
    let pieces: [TimedPiece]
    let text: String
    let seconds: Double?
    let error: String?
    /// v0.23.5：載入模型花幾秒（Whisper 才有；seconds 不含這段）
    var loadSeconds: Double? = nil
}

enum LabReport {
    /// v0.23.5：字數不到對照組（Apple 現用）的 10% 算疑似失敗（實測曾有引擎只出兩字卻寫「完成」）
    static func suspicious(chars: Int, baseline: Int?) -> Bool {
        guard let baseline, baseline > 0 else { return false }
        return Double(chars) < Double(baseline) * 0.1
    }

    /// 進度那一欄：完成或疑似失敗＋秒數、字數（Whisper 另寫載入模型幾秒）
    static func rowStatus(seconds: Double, load: Double?, chars: Int, baseline: Int?) -> String {
        let head = suspicious(chars: chars, baseline: baseline) ? "疑似失敗（字數不到 Apple 現用的 10%）" : "完成"
        var line = head + String(format: "，%.0f 秒", seconds)
        if let load {
            line += String(format: "（另載入模型 %.0f 秒）", load)
        }
        return line + "，\(chars) 字"
    }

    static func clock(_ s: Double) -> String {
        let t = max(0, Int(s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }

    /// 報告（Markdown）。audioSeconds＝音檔長度
    static func markdown(file: String, course: String, audioSeconds: Double, keywords: [String], results: [LabResult], app: String) -> String {
        var lines: [String] = []
        lines.append("# 引擎比較：\(file)")
        lines.append("")
        lines.append("- 音檔長度：\(clock(audioSeconds))；關鍵字取自「\(course)」的投影片和課程對照表，共 \(keywords.count) 個")
        lines.append("- App：\(app)")
        lines.append("- 注意：這裡沒有人工參考稿，**不是錯字率**。一致度只表示兩個引擎聽得多像；關鍵字次數多不代表對（也可能硬湊）。錯字率要用批改用的稿另外算")
        lines.append("")
        lines.append("## 各引擎")
        lines.append("")
        lines.append("| 引擎 | 狀態 | 轉換時間 | 字數 | 英文字 | 關鍵字出現（次／種） |")
        lines.append("|---|---|---|---|---|---|")
        // 第一個是 Apple 現用（對照組）
        let baseline = results.first.flatMap { $0.error == nil ? LabMetrics.normalize($0.text).count : nil }
        for r in results {
            if let error = r.error {
                lines.append("| \(r.name) | 失敗：\(error) | | | | |")
                continue
            }
            let h = LabMetrics.hits(r.text, keywords: keywords)
            var time = r.seconds.map { String(format: "%.0f 秒（%.1f 倍速）", $0, $0 > 0 ? audioSeconds / $0 : 0) } ?? ""
            if let load = r.loadSeconds {
                time += String(format: "；另載入模型 %.0f 秒", load)
            }
            let chars = LabMetrics.normalize(r.text).count
            let state = suspicious(chars: chars, baseline: baseline) ? "疑似失敗（字數不到 Apple 現用的 10%）" : "完成"
            lines.append("| \(r.name) | \(state) | \(time) | \(LabMetrics.normalize(r.text).count) | \(LabMetrics.latinWords(r.text)) | \(h.reduce(0, +))／\(h.filter { $0 > 0 }.count) |")
        }
        let ok = results.filter { $0.error == nil }
        if ok.count >= 2 {
            lines.append("")
            lines.append("## 兩兩一致度（去標點空白後，1 − 編輯距離 ÷ 較長字數）")
            lines.append("")
            lines.append("| | " + ok.map(\.name).joined(separator: " | ") + " |")
            lines.append("|---|" + ok.map { _ in "---|" }.joined())
            for a in ok {
                let cells = ok.map { b in a.name == b.name ? "—" : String(format: "%.1f%%", LabMetrics.agreement(a.text, b.text) * 100) }
                lines.append("| \(a.name) | " + cells.joined(separator: " | ") + " |")
            }
        }
        if !ok.isEmpty, !keywords.isEmpty {
            let all = ok.map { LabMetrics.hits($0.text, keywords: keywords) }
            let rows = keywords.indices.filter { i in all.contains { $0[i] > 0 } }
                .sorted { i, j in all.map { $0[i] }.reduce(0, +) > all.map { $0[j] }.reduce(0, +) }
                .prefix(40)
            if !rows.isEmpty {
                lines.append("")
                lines.append("## 關鍵字出現次數（前 40 個，有出現的）")
                lines.append("")
                lines.append("| 關鍵字 | " + ok.map(\.name).joined(separator: " | ") + " |")
                lines.append("|---|" + ok.map { _ in "---|" }.joined())
                for i in rows {
                    lines.append("| \(keywords[i]) | " + all.map { "\($0[i])" }.joined(separator: " | ") + " |")
                }
            }
        }
        lines.append("")
        lines.append("## 各引擎的設定")
        lines.append("")
        for r in results { lines.append("- \(r.name)：\(r.note)") }
        lines.append("")
        lines.append("## 關鍵字清單")
        lines.append("")
        lines.append(keywords.joined(separator: "、"))
        return lines.joined(separator: "\n") + "\n"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// 每分鐘一列、每個引擎一欄的對照表（HTML，用瀏覽器或檔案 App 打開）
    static func sideBySide(file: String, results: [LabResult], audioSeconds: Double) -> String {
        let ok = results.filter { $0.error == nil }
        let minutes = max(1, Int(ceil(audioSeconds / 60)))
        var buckets = ok.map { _ in [String](repeating: "", count: minutes) }
        for (k, r) in ok.enumerated() {
            for p in r.pieces {
                let m = min(minutes - 1, max(0, Int(max(0, p.start) / 60)))
                buckets[k][m] += p.text
            }
        }
        var html = "<!doctype html><html lang=\"zh-Hant\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\">"
        html += "<style>body{font-family:-apple-system,sans-serif;font-size:14px;line-height:1.7;margin:12px}table{border-collapse:collapse;width:100%}"
        html += "td,th{border:1px solid #ccc;vertical-align:top;padding:6px}th{background:#f3f3f3;position:sticky;top:0}td.t{color:#888;white-space:nowrap;font-size:12px}</style>"
        html += "<title>引擎對照</title></head><body><h3>\(escape(file))：每分鐘對照</h3><table><tr><th>時間</th>"
        html += ok.map { "<th>\(escape($0.name))</th>" }.joined() + "</tr>"
        for m in 0..<minutes {
            html += "<tr><td class=\"t\">\(clock(Double(m * 60)))</td>" + ok.indices.map { "<td>\(escape(buckets[$0][m]))</td>" }.joined() + "</tr>"
        }
        return html + "</table></body></html>"
    }
}
