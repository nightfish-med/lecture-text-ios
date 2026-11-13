import Foundation

// v0.23.2 錄音中送 Haiku 的「怎麼決定」：回應之後重試／放棄／停用（規格 B6）、待送批次合併、
// 停止後補定稿命中（規格 A③）、狀態列與小卡的字。只用 Foundation，shape_check 也編（tools/shape_check/review_tests.swift）。
// 網路本身在 HaikuClient.swift，一場的狀態機在 LiveReviewer.swift，這裡只放算法和字。
// 這個檔不寫稿的字進任何紀錄：finalWindow 只存在 fixes.json。

/// 這場 Haiku 停用的原因：停了就不再送，已學的規則照常顯示，畫面橫幅講原因（規格 B6）。
enum ReviewStop: String, Codable, Equatable {
    /// 401／403
    case badKey
    /// 這場花費達 1.00 美元
    case costCap
    /// 連續 3 次 400（或其他不重送的 4xx）
    case rejected
    /// 402：帳戶要付款或額度用完
    case noCredit

    /// 橫幅（不擋操作）
    var banner: String {
        switch self {
        case .badKey: return "Haiku 金鑰無效（401／403），這場不再送。到開始畫面的 Haiku 圓鈕換一把"
        case .costCap: return "Haiku 這場花費到上限 1.00 美元，不再送；已改的字照常顯示"
        case .rejected: return "Haiku 暫停：Anthropic 連續 3 次不收請求（400），這場不再送"
        case .noCredit: return "Haiku 暫停：帳戶要付款或額度用完（402），這場不再送"
        }
    }

    /// 狀態列、紀錄用的短句
    var short: String {
        switch self {
        case .badKey: return "金鑰無效"
        case .costCap: return "花費到上限"
        case .rejected: return "連續 3 次 400"
        case .noCredit: return "額度用完"
        }
    }
}

/// 回應之後這批怎麼辦（規格 B6 的表）。attempts＝這批已經送過幾次（含剛剛這次）。
enum ReviewRetry {
    static let maxAttempts = 3
    /// 529／5xx、逾時：依序等 5、15、45 秒
    static let backoff: [Double] = [5, 15, 45]
    /// 429 照 retry-after，最多等 60 秒；沒給就等 15 秒
    static let maxRetryAfter = 60.0
    static let defaultRetryAfter = 15.0
    /// 沒網路時隔幾秒再看一次（網路回來時 NWPathMonitor 會立刻叫）
    static let offlineWait = 5.0
    /// 這場花費上限（美元）
    static let costCap = 1.00
    /// 連續幾次 400 就停用
    static let max400 = 3

    enum Step: Equatable {
        /// 200：解析回覆
        case parse
        /// 標成待送，牆上時間幾秒後再試
        case retry(after: Double)
        /// 試滿 3 次，放棄這批
        case giveUp
        /// 400 類：不重送，記一筆，算進連續 400
        case reject
        /// 這場停用
        case stop(ReviewStop)
    }

    static func wait(attempts: Int) -> Double {
        backoff[min(max(attempts - 1, 0), backoff.count - 1)]
    }

    static func after(status: Int, attempts: Int, retryAfter: String?) -> Step {
        switch status {
        case 200..<300:
            return .parse
        case 401, 403:
            return .stop(.badKey)
        case 402:
            return .stop(.noCredit)
        case 429:
            guard attempts < maxAttempts else { return .giveUp }
            let given = retryAfter.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? defaultRetryAfter
            return .retry(after: min(max(given, 1), maxRetryAfter))
        case 500...599:
            guard attempts < maxAttempts else { return .giveUp }
            return .retry(after: wait(attempts: attempts))
        default:
            return .reject
        }
    }

    /// 網路錯誤。offline（沒網路、連線中斷、App 被暫停回來的 -1005）不算次數，等網路回來；逾時和其他錯照 5、15、45 秒，最多 3 次。
    static func afterNetworkError(offline: Bool, attempts: Int) -> Step {
        if offline { return .retry(after: offlineWait) }
        guard attempts < maxAttempts else { return .giveUp }
        return .retry(after: wait(attempts: attempts))
    }

    /// v0.26.2 卡片模式（模式 1）：網路錯（含 -1200 加密連線失敗）錄音中不放棄這批。
    /// 前 3 次照 5、15、45 秒；之後每 30 秒再試，網路好了就補上（11/13 真機：12:31 斷一下後 9 批全被放棄、網路回來也不補）。
    /// 停止後由補送的期限收尾，還沒送到的卡才標「沒整理到」。
    static let cardParkWait = 30.0

    static func afterNetworkErrorCards(offline: Bool, attempts: Int) -> Step {
        if offline { return .retry(after: offlineWait) }
        guard attempts < maxAttempts else { return .retry(after: cardParkWait) }
        return .retry(after: wait(attempts: attempts))
    }

    /// 回覆解析失敗：重送一次（規格 B4）
    static func afterUnreadable(attempts: Int) -> Step {
        attempts < 2 ? .retry(after: 0) : .giveUp
    }
}

/// 待送的批次（規格 B6「待送超過 4 批：合併成每批最多 600 字，依時間順序送」）。
enum ReviewQueue {
    static let mergeOver = 4
    static let mergeChars = 600

    /// 還沒送完的：待送＋送出中
    static func pendingCount(_ batches: [ReviewBatch]) -> Int {
        batches.filter { $0.state == .pending || $0.state == .sending }.count
    }

    /// 待送（pending）超過 4 批時，把相鄰的待送批併成每批最多 600 字（一批本身超過 600 不拆）；中間有別的狀態就斷開。
    /// 併成的批用第一批的編號、前文、開始時間，次數取兩批大的。chars：單位編號 → 字數。
    static func merge(_ batches: [ReviewBatch], chars: [Int: Int]) -> [ReviewBatch] {
        guard batches.filter({ $0.state == .pending }).count > mergeOver else { return batches }
        func size(_ b: ReviewBatch) -> Int { b.unitIDs.reduce(0) { $0 + (chars[$1] ?? 0) } }
        var out: [ReviewBatch] = []
        for batch in batches {
            if batch.state == .pending, let last = out.last, last.state == .pending, size(last) + size(batch) <= mergeChars {
                out[out.count - 1] = ReviewBatch(
                    id: last.id,
                    unitIDs: last.unitIDs + batch.unitIDs,
                    context: last.context,
                    audioStart: last.audioStart,
                    audioEnd: batch.audioEnd,
                    attempts: max(last.attempts, batch.attempts)
                )
            } else {
                out.append(batch)
            }
        }
        return out
    }
}

/// 停止後：通過的改字在定稿裡命中幾次、定稿同一段時間的字（規格 A③）。
enum ReviewFinal {
    /// 單位前後各多看幾秒
    static let window = 3.0

    /// 每筆「通過」而且還沒補過的（續錄前那段已補過就不動）補 finalHits、finalWindow、windowHas。
    /// units：即時那場的單位（找時間用）；finalText：定稿的字（TextCleanup 過）；finalPieces：定稿每小段（時間從整場開頭算）。
    static func annotate(_ fixes: [FixRecord], units: [LiveUnit], finalText: String, finalPieces: [TimedPiece]) -> [FixRecord] {
        fixes.map { fix in
            guard fix.verdict == .passed, fix.finalHits == nil, let rule = fix.rules.first,
                  let unit = units.first(where: { $0.id == fix.s }) else { return fix }
            var out = fix
            out.finalHits = LiveFix.count(finalText, rules: fix.rules)
            let text = windowText(finalPieces, from: unit.start - window, to: unit.end + window)
            out.finalWindow = text
            out.windowHas = has(text, wrong: rule.core, right: rule.coreRight)
            return out
        }
    }

    /// 定稿裡時間落在 from…to 的小段接起來（TextCleanup 過；沒有時間的小段不算）
    static func windowText(_ pieces: [TimedPiece], from: Double, to: Double) -> String {
        TextCleanup.fix(pieces.filter { $0.start >= 0 && $0.end >= from && $0.start <= to }.map(\.text).joined())
    }

    /// wrong／right／both／neither
    static func has(_ text: String, wrong: String, right: String) -> String {
        let w = !wrong.isEmpty && text.contains(wrong)
        let r = !right.isEmpty && text.contains(right)
        switch (w, r) {
        case (true, true): return "both"
        case (true, false): return "wrong"
        case (false, true): return "right"
        default: return "neither"
        }
    }
}

/// 11/11 同字升級：每條升級規則在這場即時稿套用了幾處（停止補送後算，寫進 fixes.json 的 promotedHits）。
/// rules＝畫面在用的全部規則（對照表＋已學，已去掉這場不再改的）；只數由那條升級規則換掉的段。
enum ReviewPromoted {
    static func hits(_ fixes: [FixRecord], text: String, rules: [LiveFixRule]) -> [FixRecord] {
        guard fixes.contains(where: { $0.promoted != nil }) else { return fixes }
        let used = LiveFix.pieces(text, rules: rules).compactMap(\.rule).filter { $0.source == .promoted }
        return fixes.map { fix in
            guard let p = fix.promoted else { return fix }
            var out = fix
            out.promotedHits = used.filter { $0 == p }.count
            return out
        }
    }
}

/// 錄音畫面標題下那一行、橫幅、綠字小卡的字。
enum ReviewText {
    static func slides(_ name: String?) -> String {
        name.map { "投影片：\($0)" } ?? "沒有投影片"
    }

    /// done＝已回來的批數；passed＝改字通過；blocked＝其他判定（和 ReviewLog.summaryLine 同一個算法）
    static func status(done: Int, passed: Int, blocked: Int, lastLatency: Double?, stop: ReviewStop?) -> String {
        if let stop {
            return "Haiku：已停（\(stop.short)）・已送 \(done) 批・改 \(passed) 處・擋 \(blocked) 處"
        }
        guard done > 0 else { return "Haiku：等待第一批" }
        var line = "Haiku：已送 \(done) 批・改 \(passed) 處・擋 \(blocked) 處"
        if let lastLatency {
            line += String(format: "・上一批 %.1f 秒", lastLatency)
        }
        return line
    }

    /// v0.26.0 即時模式 1（每批一張卡）的狀態列：整理了幾張、沒整理到幾張
    static func cardStatus(done: Int, failed: Int, lastLatency: Double?, stop: ReviewStop?) -> String {
        let counts = "整理 \(done) 張" + (failed > 0 ? "・沒整理到 \(failed) 張" : "")
        if let stop {
            return "Haiku：已停（\(stop.short)）・" + counts
        }
        guard done + failed > 0 else { return "Haiku：等待第一張卡" }
        var line = "Haiku：" + counts
        if let lastLatency {
            line += String(format: "・上一批 %.1f 秒", lastLatency)
        }
        return line
    }

    static func closed(_ reason: String) -> String {
        "Haiku：已關閉（\(reason)）"
    }

    static func offline(pending: Int) -> String {
        "沒有網路，\(pending) 批待送；網路回來自動補送"
    }

    static func busy(status: Int, seconds: Double) -> String {
        "Haiku 暫停：Anthropic 忙（\(status)），\(Int(seconds.rounded())) 秒後再送"
    }

    /// 綠字小卡第二行：誰改的、依據什麼（規格 B8 Views.swift:276）
    static func cardSource(_ rule: LiveFixRule?) -> String {
        let tail = "只改畫面，存檔的稿還是原字"
        if rule?.source == .promoted {
            return "這場同一個改法通過 \(Promotion.after) 次，整場一起改（程式驗過）；" + tail
        }
        guard let rule, rule.source == .haiku else { return "課程對照表改的；" + tail }
        let evidence = (rule.evidence ?? "").trimmingCharacters(in: .whitespaces)
        let basis: String
        if evidence.hasPrefix("投影片") {
            basis = String(evidence.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else {
            basis = evidence
        }
        guard !basis.isEmpty else { return "Haiku 改的（程式驗過）；" + tail }
        return "Haiku 依 \(basis) 改的（程式驗過）；" + tail
    }
}

extension CourseSchedule {
    /// 正式課名換回簡稱（畫面標題和資料夾用簡稱）：解析幾何 → 幾何。課表上沒有的照原樣。
    static func shortName(_ formal: String) -> String {
        slots.first(where: { ($0.formal ?? $0.name) == formal })?.name ?? formal
    }
}
