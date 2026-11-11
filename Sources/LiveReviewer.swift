import Foundation
import Network
import Observation

/// v0.23.2 一場的審稿狀態機（規格 B1、B6）：收單位 → 每秒看要不要送 → 一次只送一個請求 → 回來後（背景）解析與驗證 →
/// 通過的進已學規則；問題、頁碼先只記錄（顯示是 0.23.3）；每批之後把 ReviewLog 寫進即時那場的「… 改字.json」。
/// 花費達 1.00 美元停送；401／403 停用（金鑰無效）；連續 3 次 400 停用。不碰 AudioPump 的執行緒：Model 在主執行緒把字交過來。
/// 稿的字只進 fixes.json；onEvent（各步紀錄）只寫數字和原因，金鑰只放記憶體。
@MainActor
@Observable
final class LiveReviewer {
    /// 正式課名（例：解析幾何）
    let course: String
    /// 這場用的投影片（給人看的名字）；nil＝沒有投影片
    let deckName: String?
    /// 一場的紀錄（fixes.json）
    private(set) var log: ReviewLog
    /// 已學規則（畫面要套的；被按掉的由 Model 的 off 過濾）
    private(set) var learned: [LiveFixRule] = []
    /// NWPathMonitor：網路有沒有通
    private(set) var online = true
    /// 停用的原因；nil＝照常送
    private(set) var stop: ReviewStop?
    /// 429／5xx 等待中的一句（橫幅「Haiku 暫停」）
    private(set) var waitNote: String?
    private(set) var lastLatency: Double?

    /// 每場規則上限（規格 D：規則變多 iPad 會卡）
    static let maxRules = 400

    private let key: String
    private let courseBlock: String
    private let table: [LiveFixRule]
    private let pool: TermPool
    private let pages: [String]
    private let glossary: [LiveFixRule]
    /// v0.24 即時模式：true＝60 秒一批（模式 2、3）
    @ObservationIgnored private(set) var bigBatch = false
    /// v0.25 即時模式 1：另一個辨識器同一段的字（時間含續錄位移）；nil＝不附
    @ObservationIgnored private var reference: ((Double, Double) -> String)?
    @ObservationIgnored private var referenceName = ""
    /// Haiku 最近一次判出的投影片頁碼
    private(set) var lastPage: Int?
    private let file: URL
    private let clock: @MainActor () -> Double
    private let onEvent: @MainActor (String) -> Void
    @ObservationIgnored private var splitter: UnitSplitter
    @ObservationIgnored private var state: FixState
    @ObservationIgnored private var gate = QuestionGate()
    @ObservationIgnored private var nextBatchID: Int
    @ObservationIgnored private var lastPlanned: Double
    @ObservationIgnored private var lastAudio: Double
    @ObservationIgnored private var retryAt = Date.distantPast
    @ObservationIgnored private var feeding = true
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var consecutive400 = 0
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var saving: Task<Void, Never>?

    /// base：續錄時原場的改字紀錄（已學規則、off、最大單位編號照舊）
    init(course: String, deck: SlideDeck?, key: String, base: ReviewLog?, file: URL,
         clock: @escaping @MainActor () -> Double, onEvent: @escaping @MainActor (String) -> Void) {
        let table = LiveFix.rules(course: course)
        let now = clock()
        self.course = course
        self.deckName = deck?.name
        self.key = key
        self.table = table
        self.courseBlock = HaikuPrompt.courseBlock(course: course, glossary: table, deck: deck)
        let pages = deck.map { Array($0.pages.prefix(HaikuPrompt.slidePagesSent($0))) } ?? []
        // 0.23.3：詞池只放投影片和這門課的對照表，不放每門課都套的字形表（11/11 真機：上麵→上面 讓「自然麵→上面」憑「詞表」通過）
        self.pool = TermPool(pages: pages, glossary: LiveFix.byCourse[course] ?? [])
        self.pages = pages
        self.glossary = LiveFix.byCourse[course] ?? []
        self.file = file
        self.clock = clock
        self.onEvent = onEvent
        var start = base ?? ReviewLog(course: course, slides: deck?.source)
        if base != nil {
            start.course = course
            start.slides = deck?.source ?? start.slides
            // 上一段沒送完的批：單位已經不在記憶體，送不了
            for i in start.batches.indices where start.batches[i].state == .pending || start.batches[i].state == .sending {
                start.batches[i].state = .abandoned
                start.batches[i].error = "上一段停止時沒送完"
            }
        }
        self.log = start
        self.state = base?.fixState ?? FixState()
        self.learned = Array((base?.fixState.learned ?? []).prefix(Self.maxRules))
        var splitter = UnitSplitter(nextID: (base?.maxUnitID ?? 0) + 1)
        if base != nil { splitter.newSegment() }
        self.splitter = splitter
        self.nextBatchID = (start.batches.map(\.id).max() ?? 0) + 1
        self.lastPlanned = now
        self.lastAudio = now
    }

    /// v0.24：即時模式（start 前叫）
    func configure(bigBatch: Bool, referenceName: String = "", reference: ((Double, Double) -> String)? = nil) {
        self.bigBatch = bigBatch
        self.referenceName = referenceName
        self.reference = reference
    }

    // MARK: 開始、關掉

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.tick()
            }
        }
        monitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let ok = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.setOnline(ok)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "lecturetext.haiku.path"))
        self.monitor = monitor
        save()
    }

    func close() {
        closed = true
        loop?.cancel()
        loop = nil
        monitor?.cancel()
        monitor = nil
    }

    private func setOnline(_ ok: Bool) {
        guard ok != online else { return }
        online = ok
        onEvent(ok ? "Haiku：網路回來了，補送 \(pendingCount) 批" : "Haiku：沒有網路（\(pendingCount) 批待送）")
        if ok {
            retryAt = .distantPast
            kick()
        }
    }

    // MARK: 給畫面看的

    var doneCount: Int { log.batches.filter { $0.state == .done }.count }
    var passedCount: Int { log.fixes.filter { $0.verdict == .passed }.count }
    var blockedCount: Int { log.fixes.count - passedCount }
    var pendingCount: Int { ReviewQueue.pendingCount(log.batches) }

    var statusLine: String {
        ReviewText.status(done: doneCount, passed: passedCount, blocked: blockedCount, lastLatency: lastLatency, stop: stop)
    }

    /// 橫幅（不擋操作）：停用 > 沒網路 > Anthropic 忙
    var banner: String? {
        if let stop { return stop.banner }
        if !online { return ReviewText.offline(pending: pendingCount) }
        return waitNote
    }

    // MARK: 收字

    /// 一次 isFinal 的那一塊（時間已加上續錄的位移）；offset 是 append 前後 run.text 的字數。
    func add(_ pieces: [TimedPiece], offsetBefore: Int, offsetAfter: Int) {
        guard feeding, !closed, !pieces.isEmpty else { return }
        splitter.add(pieces, offsetBefore: offsetBefore, offsetAfter: offsetAfter)
        _ = audioNow()
    }

    /// 「這場不再改這個詞」：記進 off，相關的改字標 userOff
    func userTurnedOff(_ core: String) {
        guard !core.isEmpty, !log.off.contains(core) else { return }
        log.off.append(core)
        for i in log.fixes.indices where log.fixes[i].rules.contains(where: { $0.core == core }) || log.fixes[i].promoted?.core == core {
            log.fixes[i].userOff = true
        }
        save()
    }

    /// 回到前景、網路回來：立刻看一次
    func kick() {
        tick()
    }

    /// 錄音秒數；停止後錄音的鐘會歸零，所以記最大的
    private func audioNow() -> Double {
        lastAudio = max(lastAudio, clock())
        return lastAudio
    }

    // MARK: 每秒

    private func tick() {
        guard !closed else { return }
        let now = audioNow()
        if stop == nil {
            let unsent = splitter.unsent
            if feeding {
                if BatchPlanner.due(unsentChars: unsent.reduce(0) { $0 + $1.text.count }, now: now, lastSent: lastPlanned, big: bigBatch) {
                    plan(unsent, now: now)
                }
            } else if !unsent.isEmpty {
                plan(unsent, now: now)
            }
        }
        sendNext()
    }

    private func plan(_ units: [LiveUnit], now: Double) {
        guard let first = units.first, let last = units.last else { return }
        let id = nextBatchID
        nextBatchID += 1
        let batch = ReviewBatch(id: id, unitIDs: units.map(\.id), context: splitter.context(before: first.id),
                                audioStart: first.start, audioEnd: last.end)
        splitter.markSent(batch.unitIDs, batch: id)
        log.batches.append(batch)
        log.maxUnitID = max(log.maxUnitID, splitter.nextID - 1)
        lastPlanned = now
    }

    private func sendNext() {
        guard !closed, !inFlight, stop == nil, online, Date() >= retryAt else { return }
        let chars = Dictionary(splitter.units.map { ($0.id, $0.text.count) }, uniquingKeysWith: { a, _ in a })
        let merged = ReviewQueue.merge(log.batches, chars: chars)
        if merged != log.batches {
            log.batches = merged
            for batch in merged where batch.state == .pending {
                splitter.markSent(batch.unitIDs, batch: batch.id)
            }
        }
        guard let index = log.batches.firstIndex(where: { $0.state == .pending }) else { return }
        var batch = log.batches[index]
        let ids = Set(batch.unitIDs)
        let units = splitter.units.filter { ids.contains($0.id) }
        guard !units.isEmpty else {
            batch.state = .abandoned
            batch.error = "找不到這批的字"
            log.batches[index] = batch
            return
        }
        // v0.25 模式 1：主稿是 Whisper，附同一段 Apple 的字當證據（Apple 比 Whisper 快，不用等）
        var reference = ""
        if let source = self.reference {
            reference = String(source(batch.audioStart, batch.audioEnd).prefix(1500))
            batch.whisperChars = reference.count
        }
        batch.attempts += 1
        batch.state = .sending
        log.batches[index] = batch
        inFlight = true
        let message = HaikuPrompt.userMessage(context: batch.context, units: units) + LiveWhisper.referenceBlock(reference, name: referenceName)
        let block = courseBlock
        let apiKey = key
        let id = batch.id
        Task {
            let outcome = await Task.detached { () -> HaikuOutcome in
                guard let body = try? HaikuPrompt.requestBody(courseBlock: block, userMessage: message) else {
                    return .failure(message: "請求內容編不出來", offline: false)
                }
                return await HaikuClient.send(body: body, key: apiKey)
            }.value
            await self.handle(outcome, batchID: id, units: units, reference: reference)
        }
    }

    // MARK: 回來之後

    private func handle(_ outcome: HaikuOutcome, batchID: Int, units: [LiveUnit], reference: String = "") async {
        defer {
            inFlight = false
            save()
            if !closed { tick() }
        }
        guard let index = log.batches.firstIndex(where: { $0.id == batchID }) else { return }
        var batch = log.batches[index]
        switch outcome {
        case .failure(let message, let offline):
            batch.error = message
            if offline { batch.attempts -= 1 }
            apply(ReviewRetry.afterNetworkError(offline: offline, attempts: batch.attempts), to: &batch, status: nil)
            log.batches[index] = batch
        case .response(let data, let status, let latency, let retryAfter):
            batch.http = status
            batch.latency = latency
            let step = ReviewRetry.after(status: status, attempts: batch.attempts, retryAfter: retryAfter)
            guard step == .parse else {
                batch.error = HaikuClient.errorText(data, status: status)
                apply(step, to: &batch, status: status)
                log.batches[index] = batch
                return
            }
            // 解析和驗證放背景（照 Model.swift 的 Task.detached 寫法），不卡畫面
            let at = audioNow()
            let snapshot = state
            let off = Set(log.off)
            let sessionText = splitter.units.map(\.text).joined()
            // v0.24：附了 Whisper 稿的批，Whisper 的字也算證據（改成的字要在投影片、詞表或 Whisper 裡找得到）
            let pool = reference.isEmpty ? self.pool : TermPool(pages: pages + [reference], glossary: glossary)
            let table = self.table
            let parsed = await Task.detached { () -> ReviewParsed in
                let result = HaikuPrompt.parseResponse(data)
                guard case .reply(let reply, _, _) = result else { return ReviewParsed(result: result, records: [], state: snapshot) }
                var next = snapshot
                let records = FixValidator.validate(edits: reply.edits, chatter: reply.chatter, units: units, pool: pool, table: table,
                                                    off: off, sessionText: sessionText, state: &next, batch: batchID, at: at,
                                                    latency: latency, promotion: .app)
                return ReviewParsed(result: result, records: records, state: next)
            }.value
            // 等背景的時候 log 可能變了（新的批、合併），重找一次
            guard let now = log.batches.firstIndex(where: { $0.id == batchID }) else { return }
            batch = log.batches[now]
            addCost(parsed.result.usage)
            switch parsed.result {
            case .reply(let reply, let stopReason, let usage):
                batch.state = .done
                batch.stopReason = stopReason
                batch.usage = usage
                batch.chatter = reply.chatter
                batch.slidePage = reply.slide_page > 0 ? reply.slide_page : nil
                if let page = batch.slidePage { lastPage = page }
                batch.pageEvidence = reply.page_evidence.isEmpty ? nil : reply.page_evidence
                batch.error = nil
                state = parsed.state
                if state.learned.count > Self.maxRules {
                    state.learned = Array(state.learned.prefix(Self.maxRules))
                    onEvent("Haiku：這場規則到上限 \(Self.maxRules) 條，不再收新的")
                }
                learned = state.learned
                log.fixes += parsed.records
                if !state.disabled.isEmpty {
                    log.disabled = Array(state.disabled).sorted()
                }
                recordQuestions(reply, batchID: batchID, units: units, at: at, records: parsed.records)
                consecutive400 = 0
                lastLatency = latency
                waitNote = nil
            case .refusal(let usage):
                batch.state = .done
                batch.stopReason = "refusal"
                batch.usage = usage
                batch.error = "Haiku 拒絕這批，整批不套"
                consecutive400 = 0
            case .truncated(let usage):
                batch.state = .done
                batch.stopReason = "max_tokens"
                batch.usage = usage
                batch.error = "回覆超過長度上限，這批不套"
                consecutive400 = 0
            case .unreadable(let reason, let usage):
                batch.usage = usage
                batch.error = "回覆解析失敗：\(reason)"
                apply(ReviewRetry.afterUnreadable(attempts: batch.attempts), to: &batch, status: nil)
            }
            log.batches[now] = batch
            log.maxUnitID = max(log.maxUnitID, splitter.nextID - 1)
        }
    }

    private func apply(_ step: ReviewRetry.Step, to batch: inout ReviewBatch, status: Int?) {
        switch step {
        case .parse:
            break
        case .retry(let after):
            batch.state = .pending
            retryAt = Date().addingTimeInterval(after)
            if let status, after >= 1 {
                waitNote = ReviewText.busy(status: status, seconds: after)
            }
        case .giveUp:
            batch.state = .abandoned
            batch.error = (batch.error ?? "") + "（試 \(ReviewRetry.maxAttempts) 次都沒成功，放棄這批）"
            retryAt = .distantPast
        case .reject:
            batch.state = .failed
            consecutive400 += 1
            if consecutive400 >= ReviewRetry.max400 {
                setStop(.rejected)
            }
        case .stop(let reason):
            batch.state = .failed
            setStop(reason)
        }
    }

    private func setStop(_ reason: ReviewStop) {
        guard stop == nil else { return }
        stop = reason
        waitNote = nil
        onEvent("Haiku 停用：\(reason.short)（\(log.summaryLine)）")
    }

    private func addCost(_ usage: Usage?) {
        guard let usage else { return }
        log.costUSD += Cost.usd(usage)
        if log.costUSD >= ReviewRetry.costCap {
            setStop(.costCap)
        }
    }

    /// 問題先只記錄（0.23.3 才顯示）：shown＝通過限頻、0.23.3 起會顯示的那些
    private func recordQuestions(_ reply: HaikuReply, batchID: Int, units: [LiveUnit], at: Double, records: [FixRecord]) {
        let edited = Set(records.filter { $0.verdict == .passed }.map(\.wrong))
        for q in reply.questions {
            let unit = units.first { $0.id == q.s }
            let reason = gate.admit(q, unit: unit, at: at, editedWrongs: edited, chatter: reply.chatter)
            log.questions.append(QuestionRecord(id: log.questions.count + 1, batch: batchID, s: q.s, at: at,
                                                about: q.about, text: q.text, shown: reason == nil, reason: reason))
        }
    }

    // MARK: 停止

    /// 停止餵字：還沒送的字下一次每秒檢查就整批排進待送
    func stopFeeding() {
        _ = audioNow()
        feeding = false
        kick()
    }

    /// 補送：最多等 seconds 秒（牆上時間）。回傳沒送完的批數。
    func flush(seconds: Double) async -> Int {
        stopFeeding()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !closed {
            tick()
            if !inFlight, stop != nil || (pendingCount == 0 && splitter.unsent.isEmpty) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        countPromoted()
        await saving?.value
        return pendingCount
    }

    /// 11/11 同字升級：每條升級規則在即時稿套用了幾處（筆電之後要算），寫進 fixes.json
    private func countPromoted() {
        guard log.promotedCount > 0 else { return }
        let rules = LiveFix.rules(course: course, off: Set(log.off), learned: learned)
        log.fixes = ReviewPromoted.hits(log.fixes, text: splitter.units.map(\.text).joined(), rules: rules)
        save()
    }

    /// 定稿完成後：每筆通過的改字補 finalHits／finalWindow／windowHas（規格 A③），背景算。
    func annotateFinal(text: String, pieces: [TimedPiece]) async {
        let fixes = log.fixes
        let units = splitter.units
        let done = await Task.detached {
            ReviewFinal.annotate(fixes, units: units, finalText: text, finalPieces: pieces)
        }.value
        // 背景算的時候又回來的批（補送晚到）不要蓋掉：只換同編號的
        let byID = Dictionary(done.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        log.fixes = log.fixes.map { byID[$0.id] ?? $0 }
        save()
        await saving?.value
    }

    // MARK: 寫檔

    /// 依序寫（新的不會被晚寫的舊版蓋掉）
    private func save() {
        guard let data = Store.encodeReview(log) else { return }
        let url = file
        let previous = saving
        saving = Task.detached {
            await previous?.value
            try? data.write(to: url, options: .atomic)
        }
    }

    func waitForSaves() async {
        await saving?.value
    }
}

/// 背景解析＋驗證的結果（放在類別外面：不跟著 MainActor）
private struct ReviewParsed {
    let result: ReplyResult
    let records: [FixRecord]
    let state: FixState
}
