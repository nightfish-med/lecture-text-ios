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
    /// Haiku 最近一次判出的投影片頁碼（v0.26.0 模式 1：時間最晚、有頁碼的那張卡）
    private(set) var lastPage: Int?
    /// v0.26.0 即時模式 1：每批一張卡（擴寫式校正＋重點＋整理版＋頁碼），不跑挑字改字和 FixValidator
    @ObservationIgnored private(set) var cardMode = false
    /// 卡片（依開始時間）；續錄時前幾段的卡也在
    private(set) var cards: [LiveCard] = []
    /// 每張卡的原稿 vs 擴寫比對（回覆回來時在背景算好，畫面不重算）
    private(set) var diffs: [Int: [CardDiff.Piece]] = [:]
    @ObservationIgnored private var cardsFile: URL?
    /// 這一段（續錄的新段）第一個批次編號：停止後的逐字稿只換這段
    @ObservationIgnored private var firstBatchID = 0
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
        self.firstBatchID = self.nextBatchID
    }

    /// v0.24：即時模式（start 前叫）。v0.26.0：cards＝模式 1 每批一張卡；cardsFile＝「… 卡片.json」；savedCards＝續錄前的卡
    func configure(bigBatch: Bool, referenceName: String = "", cards: Bool = false, cardsFile: URL? = nil,
                   savedCards: [LiveCard] = [], reference: ((Double, Double) -> String)? = nil) {
        self.bigBatch = bigBatch
        self.referenceName = referenceName
        self.reference = reference
        self.cardMode = cards
        self.cardsFile = cards ? cardsFile : nil
        if cards {
            // 上一段沒整理完的卡：單位已經不在記憶體，送不了
            self.cards = savedCards.map { card -> LiveCard in
                guard card.state == .waiting else { return card }
                var out = card
                out.state = .failed
                out.note = "上一段停止時沒整理完"
                return out
            }
            self.lastPage = CardText.latestPage(self.cards)
        }
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
        if cardMode {
            let mine = cards.filter { $0.id >= firstBatchID }
            return ReviewText.cardStatus(done: mine.filter { $0.state == .done }.count, failed: mine.filter { $0.state == .failed }.count,
                                         lastLatency: lastLatency, stop: stop)
        }
        return ReviewText.status(done: doneCount, passed: passedCount, blocked: blockedCount, lastLatency: lastLatency, stop: stop)
    }

    /// v0.26.0 模式 1：還沒排進批次的字從 run.text 的第幾個字開始（卡片下面的即時字用）；nil＝都排進去了
    var unsentOffset: Int? {
        splitter.unsent.first?.offsetStart
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
        if cardMode {
            upsertWaiting(batch)
        }
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
            if cardMode {
                syncWaitingCards()
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
        let block = courseBlock
        let apiKey = key
        let id = batch.id
        if cardMode {
            // v0.26.0 模式 1：一批一張卡。原稿不帶 [s編號]；回覆比較長，用比較長的逾時
            let raw = units.map(\.text).joined()
            let message = CardPrompt.userMessage(context: batch.context, raw: raw, reference: reference, referenceName: referenceName)
            Task {
                let outcome = await Task.detached { () -> HaikuOutcome in
                    guard let body = try? CardPrompt.requestBody(courseBlock: block, userMessage: message) else {
                        return .failure(message: "請求內容編不出來", offline: false)
                    }
                    return await HaikuClient.send(body: body, key: apiKey, session: HaikuClient.cardSession, timeout: HaikuClient.cardTimeout)
                }.value
                await self.handleCard(outcome, batchID: id, raw: raw)
            }
            return
        }
        let message = HaikuPrompt.userMessage(context: batch.context, units: units) + LiveWhisper.referenceBlock(reference, name: referenceName)
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
                if let page = batch.slidePage {
                    lastPage = page
                    // v0.26.0：fixes.json 的 pages 以前一直是空的，每批判出的頁碼記進去
                    log.pages.append(PageMark(at: batch.audioStart, page: page, source: "haiku", unitID: batch.unitIDs.first ?? 0))
                }
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

    // MARK: v0.26.0 模式 1：卡片

    /// 卡片回來：解析、程式把關（頁碼範圍、擴寫太短不採用）、比對都在背景；失敗照現有重試規則，放棄的卡只放原稿
    private func handleCard(_ outcome: HaikuOutcome, batchID: Int, raw: String) async {
        defer {
            inFlight = false
            syncWaitingCards()
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
            let pageCount = pages.count
            let parsed = await Task.detached { () -> CardParsed in
                let result = CardPrompt.parseResponse(data)
                guard case .reply(let reply, _) = result else { return CardParsed(result: result, reply: nil, note: nil, diff: []) }
                let accepted = CardPrompt.accept(reply, raw: raw, pageCount: pageCount)
                return CardParsed(result: result, reply: accepted.reply, note: accepted.note,
                                  diff: CardDiff.pieces(raw: raw, expanded: accepted.reply.expanded))
            }.value
            guard let now = log.batches.firstIndex(where: { $0.id == batchID }) else { return }
            batch = log.batches[now]
            addCost(parsed.result.usage)
            addCardCost(batchID, usage: parsed.result.usage)
            switch parsed.result {
            case .reply(_, let usage):
                batch.state = .done
                batch.usage = usage
                batch.error = nil
                if let reply = parsed.reply {
                    batch.slidePage = reply.page
                    if let page = reply.page {
                        log.pages.append(PageMark(at: batch.audioStart, page: page, source: "haiku", unitID: batch.unitIDs.first ?? 0))
                    }
                    finishCard(batchID, batch: batch, raw: raw, reply: reply, note: parsed.note, diff: parsed.diff)
                }
                consecutive400 = 0
                lastLatency = latency
                waitNote = nil
            case .refusal(let usage):
                batch.state = .done
                batch.stopReason = "refusal"
                batch.usage = usage
                batch.error = "Haiku 拒絕這批，只放原稿"
                failCard(batchID, note: "Haiku 拒絕這批")
                consecutive400 = 0
            case .truncated(let usage):
                batch.state = .done
                batch.stopReason = "max_tokens"
                batch.usage = usage
                batch.error = "回覆超過長度上限，只放原稿"
                failCard(batchID, note: "回覆超過長度上限")
                consecutive400 = 0
            case .unreadable(let reason, let usage):
                batch.usage = usage
                batch.error = "回覆解析失敗：\(reason)"
                apply(ReviewRetry.afterUnreadable(attempts: batch.attempts), to: &batch, status: nil)
            }
            log.batches[now] = batch
        }
    }

    private func finishCard(_ id: Int, batch: ReviewBatch, raw: String, reply: CardReply, note: String?, diff: [CardDiff.Piece]) {
        var card = cards.first(where: { $0.id == id }) ?? LiveCard(id: id, start: batch.audioStart, end: batch.audioEnd, raw: raw)
        card.start = batch.audioStart
        card.end = batch.audioEnd
        card.raw = raw
        card.state = .done
        card.page = reply.page
        card.key = reply.key
        card.tidy = reply.tidy
        card.unsure = reply.unsure
        card.expanded = reply.expanded
        card.note = note
        put(card)
        diffs[id] = diff
        lastPage = CardText.latestPage(cards)
    }

    private func failCard(_ id: Int, note: String) {
        guard var card = cards.first(where: { $0.id == id }) else { return }
        card.state = .failed
        card.note = note
        put(card)
    }

    private func addCardCost(_ id: Int, usage: Usage?) {
        guard let usage, let i = cards.firstIndex(where: { $0.id == id }) else { return }
        let cost = Cost.usd(usage)
        cards[i].costUSD += cost
    }

    /// 有就換、沒有就加，依開始時間排
    private func put(_ card: LiveCard) {
        if let i = cards.firstIndex(where: { $0.id == card.id }) {
            cards[i] = card
        } else {
            cards.append(card)
            cards.sort { $0.start < $1.start }
        }
    }

    /// 批次排出去時先放一張「整理中」的卡（原稿先看得到）
    private func upsertWaiting(_ batch: ReviewBatch) {
        let ids = Set(batch.unitIDs)
        let raw = splitter.units.filter { ids.contains($0.id) }.map(\.text).joined()
        if let existing = cards.first(where: { $0.id == batch.id }) {
            guard existing.state == .waiting else { return }
            var card = existing
            card.raw = raw
            card.start = batch.audioStart
            card.end = batch.audioEnd
            if card != existing { put(card) }
        } else {
            put(LiveCard(id: batch.id, start: batch.audioStart, end: batch.audioEnd, raw: raw))
        }
    }

    /// 合併、放棄之後對齊卡片：被併掉的批的卡拿掉、併成的批補卡；放棄、失敗的批的卡改成「沒整理到」
    private func syncWaitingCards() {
        guard cardMode else { return }
        let byID = Dictionary(log.batches.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let first = firstBatchID
        cards.removeAll { $0.state == .waiting && $0.id >= first && byID[$0.id] == nil }
        let waiting = cards.filter { $0.state == .waiting }.map(\.id)
        for id in waiting {
            guard let batch = byID[id] else { continue }
            switch batch.state {
            case .failed, .abandoned, .done:
                // 放棄、400、停用；或回來了卻沒有卡的內容：只放原稿
                failCard(id, note: "沒整理到")
            case .pending, .sending:
                break
            }
        }
        for batch in log.batches where batch.id >= first && (batch.state == .pending || batch.state == .sending) {
            upsertWaiting(batch)
        }
    }

    /// 停止後還沒整理到的卡改成「沒整理到」（逐字稿用原稿）
    private func finalizeCards() {
        guard cardMode else { return }
        let waiting = cards.filter { $0.state == .waiting }.map(\.id)
        for id in waiting {
            failCard(id, note: "停止時還沒整理到")
        }
        if !waiting.isEmpty { save() }
    }

    /// 停止後的逐字稿（只有這一段）：各卡的擴寫依時間接起來，沒整理到的用原稿，沒進卡的原稿接在最後
    func cardTranscript() -> String {
        let mine = cards.filter { $0.id >= firstBatchID }
        let ids = Set(mine.map(\.id))
        let covered = Set(log.batches.filter { ids.contains($0.id) }.flatMap(\.unitIDs))
        let tail = splitter.units.filter { !covered.contains($0.id) }.map(\.text).joined()
        return CardText.transcript(mine, tail: tail)
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
        finalizeCards()
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
        // v0.26.0 模式 1：卡片另存「… 卡片.json」（稿的字只在這個檔和 fixes.json）
        let cardData = cardsFile == nil ? nil : Store.encodeCards(cards)
        let cardURL = cardsFile
        let previous = saving
        saving = Task.detached {
            await previous?.value
            try? data.write(to: url, options: .atomic)
            if let cardData, let cardURL {
                try? cardData.write(to: cardURL, options: .atomic)
            }
        }
    }

    func waitForSaves() async {
        await saving?.value
    }
}

/// v0.26.0 卡片背景解析的結果（放在類別外面：不跟著 MainActor）
private struct CardParsed {
    let result: CardResult
    let reply: CardReply?
    let note: String?
    let diff: [CardDiff.Piece]
}

/// 背景解析＋驗證的結果（放在類別外面：不跟著 MainActor）
private struct ReviewParsed {
    let result: ReplyResult
    let records: [FixRecord]
    let state: FixState
}
