import Foundation

// v0.23.5 下課後用 Whisper 再轉一份（純邏輯，不碰畫面、不連網；shape_check 用 tools/shape_check/whisper_tests.swift 測）。
// iPad 實驗模式實測：Whisper 英文術語比 Apple 好（英文術語命中次數明顯較多），但會鬼打牆（「 林小安」×28、「, Wait」×36、「嘖嘖」×50）。
// 這裡放：濾鬼打牆、切窗的安靜點、待辦標記、紀錄、稿頭。真的跑 Whisper 在 WhisperRunner.swift，排程在 WhisperAfter.swift。

enum WhisperPlan {
    /// 裝置上的模型（和實驗模式同一個；iPad 實測：46:24 錄音 261 秒、55:20 錄音 241 秒）
    static let model = "large-v3-v20240930_626MB"
    /// 一次餵 Whisper 多長（秒）。切小段才存得了進度：被系統收掉時最多重做一段。
    static let windowSeconds = 300.0
    /// 窗尾往後多讀幾秒，在裡面找最安靜的地方切，免得把一個字切成兩半
    static let cutSearchSeconds = 10.0
    static let sampleRate = 16_000.0
    /// 同一場最多試幾次（失敗、轉到一半 App 被關掉都算；被錄音打斷、切到背景暫停不算）
    static let maxAttempts = 3

    /// 每段最多生成幾個 token（電腦版 engine.py：16＋每秒 15，最多 400；鬼打牆會很快停）。
    /// WhisperKit 1.1.1 一個窗最多 224 個（Constants.maxTokenContext＝448／2），所以 14 秒以上的段等於沒限制；下一版錄音中一句 ≤20 秒、短句才有作用。
    static func tokenLimit(seconds: Double) -> Int {
        guard seconds.isFinite else { return 224 }
        return min(16 + Int(min(max(0, seconds), 100) * 15), 400, 224)
    }

    /// samples 裡從 from 起找最安靜的 0.1 秒，回傳它中間的位置（切在這裡）。from 超過長度就回傳長度。
    static func quietCut(_ samples: [Float], from: Int, frame: Int = 1_600) -> Int {
        guard from >= 0, from + frame <= samples.count else { return samples.count }
        var best = from
        var bestEnergy = Float.greatestFiniteMagnitude
        var start = from
        while start + frame <= samples.count {
            var sum: Float = 0
            for i in start..<(start + frame) { sum += abs(samples[i]) }
            if sum < bestEnergy {
                bestEnergy = sum
                best = start
            }
            start += frame
        }
        return best + frame / 2
    }

    /// 轉完幾乎沒有字（1 分鐘以上的錄音、每秒不到 0.2 字；上課約每秒 4 字）：多半是 Whisper 中途出錯（窗內出錯不會丟錯誤，只會少字），當作失敗重轉
    static func tooFew(chars: Int, audioSeconds: Double) -> Bool {
        audioSeconds >= 60 && Double(chars) < audioSeconds * 0.2
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "正常"
        case .fair: return "微溫"
        case .serious: return "很熱"
        case .critical: return "過熱"
        @unknown default: return "不明"
        }
    }

    /// level：0–1，負數是讀不到。charging：充電中或已充滿。
    static func batteryText(level: Float, charging: Bool) -> String {
        guard level >= 0 else { return "電量讀不到" }
        return "電量 \(Int((level * 100).rounded()))%" + (charging ? "（充電中）" : "")
    }

    static func speed(audio: Double, took: Double) -> String {
        took > 0 ? String(format: "%.1f 倍速", audio / took) : "?"
    }
}

// MARK: 濾鬼打牆（照電腦版 engine.py 的三層：每段 token 上限在 WhisperRunner；這裡是壓縮重複＋標註、整段迴圈、幻覺句）

/// 同一個片段（1–12 字；英文一個詞算 1 字；含前後的空白、標點）連續重複 4 次以上，留 1 份並標「〔重複×N，已壓縮〕」（電腦版 collapse_repeats 的寫法），
/// 不無聲刪掉。電腦版是 1–4 字重複 15 次以上；這裡比它嚴：iPad 實測「, Wait」一個詞×36、「 林小安」3 字×28。
/// 只有一個漢字的（嘖嘖嘖、哈哈哈哈）要 8 次以上，免得「對對對對」被改。
/// 從左往右找；同一個位置先試短的片段。最後剩半截：去掉空白標點後和片段一樣（「林小安 林小安 林小安 林小安 林小安」最後那個沒有空白）也算一次，
/// 不一樣（「請問一下,」×4 後面接「請問老師」）就留著，那是下一句的開頭。片段裡至少要有一個字母或漢字（「......」「1111」不動）。
enum LoopFilter {
    static let maxChars = 24
    static let maxWords = 12
    static let minRepeats = 4
    static let minRepeatsSingleHan = 8
    private static let separators: Set<Character> = [" ", "\t", "\n", ",", ".", "?", "!", ";", ":", "，", "。", "？", "！", "、", "；", "：", "…"]

    static func marker(_ count: Int) -> String { "〔重複×\(count)，已壓縮〕" }

    private static func core<S: Sequence>(_ s: S) -> [Character] where S.Element == Character {
        s.filter { !$0.isWhitespace && !separators.contains($0) }
    }

    static func isLatin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    /// 幾「字」：漢字一個算一個，連在一起的英文字母數字算一個
    static func words(_ chars: [Character]) -> Int {
        var count = 0
        var inLatin = false
        for c in chars {
            if isLatin(c) {
                if !inLatin { count += 1 }
                inLatin = true
            } else {
                count += 1
                inLatin = false
            }
        }
        return count
    }

    /// 要拿掉哪些字元（true＝拿掉）、哪個字元後面要插標註（值＝一共重複幾次）
    static func mask(_ chars: [Character]) -> (remove: [Bool], markers: [Int: Int]) {
        let n = chars.count
        var remove = [Bool](repeating: false, count: n)
        var markers: [Int: Int] = [:]
        var i = 0
        while i < n {
            var jumped = false
            for p in 1...maxChars {
                if i + p * minRepeats > n { break }
                var j = i + p
                while j < n, chars[j] == chars[j - p] { j += 1 }
                let length = j - i
                guard length >= p * minRepeats else { continue }
                let unit = Array(chars[i..<(i + p)])
                let unitCore = core(unit)
                guard unit.contains(where: { $0.isLetter }), !unitCore.isEmpty, words(unitCore) <= maxWords else { continue }
                // 英文詞要從詞頭開始（不把 Ahhhh 的 hhhh 當重複）
                if let first = unit.first, isLatin(first), i > 0, isLatin(chars[i - 1]) { continue }
                let singleHan = unitCore.count == 1 && !isLatin(unitCore[0])
                if singleHan, length < p * minRepeatsSingleHan { continue }
                if p == 1, !singleHan { continue }
                let rest = length % p
                var end = j - rest
                var count = length / p
                if rest > 0 {
                    let tail = core(chars[(j - rest)..<j])
                    if !tail.isEmpty, tail == unitCore {
                        end = j
                        count += 1
                    }
                }
                for k in (i + p)..<end { remove[k] = true }
                markers[i + p - 1] = count
                i = end
                jumped = true
                break
            }
            if !jumped { i += 1 }
        }
        return (remove, markers)
    }

    /// 一段字：回傳壓縮過的字、壓了幾處、少了幾個字（不算空白、不算標註）
    static func collapse(_ text: String) -> (text: String, runs: Int, removed: Int) {
        let chars = Array(text)
        let (remove, markers) = mask(chars)
        var out = ""
        var removed = 0
        for (k, c) in chars.enumerated() {
            if remove[k] {
                if !c.isWhitespace { removed += 1 }
            } else {
                out.append(c)
            }
            if let count = markers[k] { out += marker(count) }
        }
        return (out, markers.count, removed)
    }

    /// 跨小段：鬼打牆可能在一小段裡，也可能是一連串小段。整串接起來找，拿掉的字從各小段扣掉，標註接在留下的那份後面；
    /// 扣完只剩空白的小段整段拿掉；留下來的小段時間不變。
    static func filter(_ pieces: [TimedPiece]) -> (pieces: [TimedPiece], runs: Int, removed: Int) {
        var chars: [Character] = []
        var owner: [Int] = []
        for (index, piece) in pieces.enumerated() {
            for c in piece.text {
                chars.append(c)
                owner.append(index)
            }
        }
        let (remove, markers) = mask(chars)
        guard !markers.isEmpty else { return (pieces, 0, 0) }
        var texts = [String](repeating: "", count: pieces.count)
        var removed = 0
        for k in chars.indices {
            if remove[k] {
                if !chars[k].isWhitespace { removed += 1 }
            } else {
                texts[owner[k]].append(chars[k])
            }
            if let count = markers[k] { texts[owner[k]] += marker(count) }
        }
        var out: [TimedPiece] = []
        for (index, piece) in pieces.enumerated() {
            let text = texts[index]
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            out.append(TimedPiece(text: text, start: piece.start, end: piece.end))
        }
        return (out, markers.count, removed)
    }
}

/// 電腦版 engine.py 的另外兩層：幻覺句（沒人講話時 Whisper 會吐「請不吝點讚訂閱」這類，HALLUCINATION）、
/// 整段迴圈（壓縮比 ≥2.4 且 ≥20 字，is_loop）。電腦版兩種都整段丟掉；這裡幻覺句拿掉、整段迴圈換成「〔疑似鬼打牆，略過 N 字〕」，
/// 每一處都回報時間和字數（紀錄只寫這兩個，不寫稿的字），不無聲消失。
enum WhisperClean {
    static let hallucination = try? NSRegularExpression(pattern: "請不吝|點[讚贊]訂閱|訂閱.*(頻道|轉發)|字幕(由|提供|志願者)|中文字幕|明鏡.*點點|優優獨播|Amara\\.org")
    static let loopRatio = 2.4
    static let loopMinChars = 20

    struct Event: Equatable {
        enum Kind: String { case loop = "疑似鬼打牆整段略過", hallucination = "幻覺句拿掉" }
        let kind: Kind
        let start: Double
        let end: Double
        let chars: Int
        var line: String { "\(kind.rawValue)：\(formatStamp(start))–\(formatStamp(end))，\(chars) 字" }
    }

    struct Result {
        var pieces: [TimedPiece]
        var runs = 0
        var removed = 0
        var loops = 0
        var hallucinations = 0
        var events: [Event] = []
    }

    static func isHallucination(_ text: String) -> Bool {
        guard let hallucination else { return false }
        return hallucination.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// UTF-8 長度 ÷ 壓縮後長度（電腦版用 zlib.compress；這裡用系統的 deflate 再加 zlib 的 6 個位元組檔頭檔尾，數字接近）
    static func compressionRatio(_ text: String) -> Double {
        let data = Data(text.utf8)
        guard !data.isEmpty, let packed = try? (data as NSData).compressed(using: .zlib) else { return 0 }
        return Double(data.count) / Double(max(packed.length + 6, 1))
    }

    static func isLoop(_ text: String) -> Bool {
        text.count >= loopMinChars && compressionRatio(text) >= loopRatio
    }

    static func loopMarker(_ chars: Int) -> String { "〔疑似鬼打牆，略過 \(chars) 字〕" }

    /// 順序：幻覺句拿掉 → 連續重複壓縮＋標註 → 壓完還是整段迴圈的換成標註
    static func clean(_ pieces: [TimedPiece]) -> Result {
        var kept: [TimedPiece] = []
        var events: [Event] = []
        for piece in pieces {
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, isHallucination(text) {
                events.append(Event(kind: .hallucination, start: piece.start, end: piece.end, chars: text.count))
                continue
            }
            kept.append(piece)
        }
        let collapsed = LoopFilter.filter(kept)
        var result = Result(pieces: [], runs: collapsed.runs, removed: collapsed.removed)
        for piece in collapsed.pieces {
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isLoop(text) {
                events.append(Event(kind: .loop, start: piece.start, end: piece.end, chars: text.count))
                result.pieces.append(TimedPiece(text: loopMarker(text.count), start: piece.start, end: piece.end))
            } else {
                result.pieces.append(piece)
            }
        }
        result.events = events.sorted { $0.start < $1.start }
        result.loops = events.filter { $0.kind == .loop }.count
        result.hallucinations = events.filter { $0.kind == .hallucination }.count
        return result
    }
}

// MARK: 稿

enum WhisperText {
    /// 英文接英文中間補一個空白（Whisper 每小段的字去掉前後空白後直接接，會變成 matrixrank）
    static func spaced(_ pieces: [TimedPiece]) -> [TimedPiece] {
        var out: [TimedPiece] = []
        var previous: Character?
        for piece in pieces {
            var text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = previous, let first = text.first, isLatin(last), isLatin(first) {
                text = " " + text
            }
            previous = text.last
            out.append(TimedPiece(text: text, start: piece.start, end: piece.end))
        }
        return out
    }

    private static func isLatin(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    /// 整份字（不含稿頭）：照停頓分段（和 App 的稿同一套 LineBuilder），續錄的每段之間放分隔行。
    /// partStarts：每段在整場的第幾秒開始（第一段是 0）；小段照開始時間分到各段。
    static func body(_ pieces: [TimedPiece], partStarts: [Double]) -> String {
        let spacedPieces = spaced(pieces)
        let starts = partStarts.isEmpty ? [0] : partStarts
        var groups = [[TimedPiece]](repeating: [], count: starts.count)
        for piece in spacedPieces {
            var k = 0
            for (index, start) in starts.enumerated() where piece.start >= start - 0.01 { k = index }
            groups[k].append(piece)
        }
        var parts: [String] = []
        for (index, group) in groups.enumerated() {
            var builder = LineBuilder()
            builder.add(group)
            let text = builder.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if index == 0 {
                parts.append(text)
            } else {
                parts.append(PartJoin.divider(part: index + 1, offset: starts[index]) + (text.isEmpty ? "" : "\n\n" + text))
            }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// 稿頭：哪個模型、多久、濾掉幾處
    static func header(title: String, record: WhisperRecord, app: String, finished: String) -> String {
        var lines = ["---"]
        lines.append("標題：\(title)（Whisper 稿）")
        lines.append("說明：按停止後在這台裝置上用 Whisper 再轉一次的稿，不是 App 的定稿；英文術語通常比較準，但可能有同音錯字、會重複同一個詞（鬼打牆：連續 4 次以上的留 1 份並標〔重複×N，已壓縮〕，整段迴圈標〔疑似鬼打牆，略過 N 字〕）。")
        lines.append("模型：WhisperKit \(record.model)，語言 zh，\(record.prompt ? "有關鍵字提示詞" : "沒有提示詞")，簡轉繁")
        lines.append(record.timeLine)
        lines.append(record.filterLine)
        lines.append("App：轉文字 \(app)；轉完：\(finished)")
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: 檔名、待辦、紀錄

/// 一場的檔＝「開始轉的時間 來源檔名」＋後綴（和 Store.file(of:) 同一套）
enum WhisperFiles {
    static let text = " Whisper稿.txt"
    static let times = " Whisper時間.json"
    /// 待辦標記：有這個檔＝還沒轉完；轉完刪掉
    static let pending = " Whisper待辦.json"
    /// 轉到一半的原始小段（還沒濾），轉完刪掉
    static let progress = " Whisper進度.json"
    /// 紀錄（轉了哪幾段、多久、濾掉幾處、每一步），錯誤資料 info.txt 讀這個
    static let record = " Whisper紀錄.json"
}

/// 待辦標記的內容。路徑都相對於 App 的 Documents（重裝或更新 App 後絕對路徑會變）。
struct WhisperJob: Codable, Equatable {
    /// 「逐字稿/解析幾何/20261111-101500 20261111-101000」：加上 WhisperFiles 的後綴就是各檔
    var stem: String
    /// 「錄音/解析幾何」
    var audioFolder: String
    /// 錄音檔名，續錄的每段一個
    var parts: [String]
    /// 每段在整場的第幾秒開始；nil＝沒存（用前面幾段的長度加起來）
    var partStarts: [Double]?
    var title: String
    /// 排進來的時間（yyyyMMdd-HHmmss）
    var queued: String
    /// 轉到第幾段（0 起）、那段的第幾秒
    var part: Int = 0
    var at: Double = 0
    /// 已經轉完的幾段加起來多長（沒存 partStarts 時算位置用）
    var doneAudio: Double = 0
    var attempts: Int = 0
    /// 開始轉時設 true、暫停或失敗時設 false。打開 App 看到 true＝上次轉到一半 App 被關掉
    var running: Bool = false
    /// 之前已經轉完的段（續錄前那次）濾掉的處數、字數、轉換秒數，最後加總
    var priorRuns: Int = 0
    var priorRemoved: Int = 0
    var priorLoops: Int = 0
    var priorHallucinations: Int = 0
    var priorSeconds: Double = 0
    /// 這次（含暫停前）實際轉換花的秒數，不含載入模型
    var spent: Double = 0

    /// 第 index 段在整場的開始秒數
    func offset(of index: Int) -> Double {
        if let starts = partStarts, index < starts.count { return starts[index] }
        return doneAudio
    }

    /// 又排一次（例如續錄後再按停止）：
    /// - 還有沒轉完的待辦、段數只是變多：接著原本的進度，換成新的段清單，次數歸零
    /// - 之前轉完過、段清單一樣：不用再轉（nil）
    /// - 之前轉完過、轉過的段是新清單的開頭：只轉新的段，之前的數字帶過來（進度檔要從已濾的稿開始）
    /// - 其他：從頭轉
    static func merge(new: WhisperJob, pending: WhisperJob?, record: WhisperRecord?) -> WhisperJob? {
        if var old = pending, old.parts.count <= new.parts.count, Array(new.parts.prefix(old.parts.count)) == old.parts {
            old.parts = new.parts
            old.partStarts = new.partStarts
            old.title = new.title
            old.attempts = 0
            old.running = false
            return old
        }
        if pending == nil, let record, !record.parts.isEmpty, record.result?.hasPrefix("完成") == true {
            if record.parts == new.parts { return nil }
            if record.parts.count < new.parts.count, Array(new.parts.prefix(record.parts.count)) == record.parts {
                var job = new
                job.part = record.parts.count
                job.doneAudio = record.audioSeconds
                job.priorRuns = record.runs
                job.priorRemoved = record.removed
                job.priorLoops = record.loops
                job.priorHallucinations = record.hallucinations
                job.priorSeconds = record.seconds
                return job
            }
        }
        return new
    }

    var progressLine: String {
        "第 \(min(part + 1, parts.count))／\(parts.count) 段 \(formatStamp(at))"
    }
}

/// 一場的 Whisper 紀錄（「… Whisper紀錄.json」）
struct WhisperRecord: Codable, Equatable {
    var model: String = WhisperPlan.model
    var prompt: Bool = false
    /// 已經轉完的段（錄音檔名）
    var parts: [String] = []
    /// 錄音總長、轉換秒數（不含載入模型）、載入模型秒數
    var audioSeconds: Double = 0
    var seconds: Double = 0
    var loadSeconds: Double?
    var runs: Int = 0
    var removed: Int = 0
    /// 整段判成迴圈換成標註的段數、拿掉的幻覺句段數
    var loops: Int = 0
    var hallucinations: Int = 0
    /// 最後結果：完成、失敗（原因）、放棄
    var result: String?
    var log: [String] = []

    var timeLine: String {
        var line = "轉換：\(String(format: "%.0f", seconds)) 秒（錄音 \(formatStamp(audioSeconds))，\(WhisperPlan.speed(audio: audioSeconds, took: seconds))，不含載入模型）"
        if let loadSeconds {
            line += String(format: "；載入模型 %.0f 秒", loadSeconds)
        }
        return line
    }

    var filterLine: String {
        var parts: [String] = []
        parts.append(runs == 0 ? "沒有連續重複" : "壓縮 \(runs) 處、少了 \(removed) 字（同一片段連續重複 4 次以上留 1 份，標〔重複×N，已壓縮〕）")
        if loops > 0 { parts.append("整段疑似迴圈 \(loops) 段（換成〔疑似鬼打牆，略過 N 字〕）") }
        if hallucinations > 0 { parts.append("拿掉幻覺句 \(hallucinations) 段（沒人講話時會出現的「請不吝點讚訂閱」這類）") }
        return "鬼打牆：" + parts.joined(separator: "；")
    }

    /// 錯誤資料（info.txt）用：結果一行＋各步紀錄
    var reportLines: [String] {
        var lines = ["下課 Whisper：\(result ?? "還沒轉完")"]
        if !parts.isEmpty {
            lines.append("  " + timeLine)
            lines.append("  " + filterLine)
        }
        lines += log.map { "  " + $0 }
        return lines
    }
}
