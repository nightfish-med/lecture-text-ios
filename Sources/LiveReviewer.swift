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
    /// v0.29.0：這場是「非課程（其他場合）」（course 是空的；重查、重算寫非課程，不寫討論會）
    let nonCourse: Bool
    /// v0.29.0：非課程時使用者寫的主題（錄音中可以改；每次送卡片、重查、重算都附在使用者訊息，不放進有快取的課程區塊）
    private(set) var topic: String?
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
    /// v0.27.0：重查（Pencil 圈起來）送出中的件數；停止補送時等它們
    @ObservationIgnored private var rechecksInFlight = 0
    @ObservationIgnored private var nextRecheckID = 1
    /// v0.28.0：重查一個一個跑（前一個跑完才送下一個；排著的也算在 rechecksInFlight）
    @ObservationIgnored private var recheckChain: Task<Void, Never>?
    /// v0.28.0 逐字稿改了之後重算重點：卡片編號 → 可以送的時間（去抖動，再被改就從頭等）
    @ObservationIgnored private var refreshDue: [Int: Date] = [:]
    /// 正在送重算的卡（同一張卡同時只有一個）
    @ObservationIgnored private var refreshRunning: Set<Int> = []
    /// 送的時候又被改的卡：跑完再跑一次
    @ObservationIgnored private var refreshAgain: Set<Int> = []
    /// 畫面「更新中」：排著或正在送重算的卡
    private(set) var refreshing: Set<Int> = []
    /// v0.28.0：停止收尾了（補送期限到）：不再送新的重算、重查，晚回來的不套
    @ObservationIgnored private var wrapped = false

    /// base：續錄時原場的改字紀錄（已學規則、off、最大單位編號照舊）
    /// v0.27.0：courseBlock 有給就用它（討論會沒有課名時的中性區塊）；nil＝照課名、對照表、投影片產生
    /// v0.29.0：nonCourse、topic＝非課程（其他場合）和使用者寫的主題（存進改字紀錄，續錄讀得回）
    init(course: String, deck: SlideDeck?, key: String, base: ReviewLog?, file: URL, courseBlock: String? = nil,
         nonCourse: Bool = false, topic: String? = nil,
         clock: @escaping @MainActor () -> Double, onEvent: @escaping @MainActor (String) -> Void) {
        let table = LiveFix.rules(course: course)
        let now = clock()
        self.course = course
        self.nonCourse = nonCourse
        self.topic = SessionTopic.clean(topic)
        self.deckName = deck?.name
        self.key = key
        self.table = table
        self.courseBlock = courseBlock ?? HaikuPrompt.courseBlock(course: course, glossary: table, deck: deck)
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
        start.nonCourse = nonCourse ? true : nil
        start.topic = SessionTopic.clean(topic)
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

    /// v0.28.0：錄音中才建審稿器（錄音中才指定課名）時，之前已經轉出的字補進來（時間已含續錄位移）。
    /// 照約 60 秒切開、一段排一批（一張卡不會太大），排在之後的新字前面。只叫一次；之後的新字照舊走 add
    func addEarlier(_ pieces: [TimedPiece], offsetBefore: Int, offsetAfter: Int) {
        guard feeding, !closed, !pieces.isEmpty else { return }
        let now = audioNow()
        for chunk in CardText.earlierChunks(pieces) {
            splitter.add(chunk, offsetBefore: offsetBefore, offsetAfter: offsetAfter)
            let unsent = splitter.unsent
            if !unsent.isEmpty {
                plan(unsent, now: now)
            }
        }
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

    /// v0.29.0：錄音中改主題（非課程）：之後送的卡片、重查、重算都用新的；記進改字紀錄（續錄讀得回）
    func setTopic(_ text: String?) {
        let cleaned = SessionTopic.clean(text)
        topic = cleaned
        log.topic = cleaned
        save()
    }

    /// v0.29.0 錄音中複製用：這一段（續錄的新段）的卡；前幾段的字在續錄的 head 裡（和停止後的逐字稿同一個規則）
    var segmentCards: [LiveCard] {
        cards.filter { $0.id >= firstBatchID }
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
        sendRefreshes()
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
            // v0.27.0：這場使用者改過的字附在最後當參考（只這場，不存進任何詞表）
            // v0.29.0：非課程的主題（使用者寫的）放在改字對照、說明前面；每次請求都帶現在的主題
            let userEdits = SessionTopic.promptBlock(topic) + CardEdits.promptBlock(cards.flatMap { $0.edits ?? [] })
            let message = CardPrompt.userMessage(context: batch.context, raw: raw, reference: reference, referenceName: referenceName,
                                                 userEdits: userEdits)
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
            // v0.26.2：卡片模式網路錯錄音中不放棄，卡上寫「網路不通，等一下再送」
            apply(ReviewRetry.afterNetworkErrorCards(offline: offline, attempts: batch.attempts), to: &batch, status: nil)
            log.batches[index] = batch
            if batch.state == .pending, var card = cards.first(where: { $0.id == batchID }), card.state == .waiting {
                card.note = CardText.retryNote
                put(card)
            }
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
        // v0.28.0：還在整理時就被改過（或留了說明）：這次回來的重點沒看到那些改動，照改好的逐字稿再重算一次
        if CardEdits.needsRefresh(card.edits) {
            scheduleRefresh(id)
        }
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

    /// 停止後還沒整理到的卡改成「沒整理到」（逐字稿用原稿）；v0.27.0 還沒查完的重查標「停止時還沒查完」
    private func finalizeCards() {
        guard cardMode else { return }
        let waiting = cards.filter { $0.state == .waiting }.map(\.id)
        for id in waiting {
            failCard(id, note: "停止時還沒整理到")
        }
        var changed = !waiting.isEmpty
        for i in cards.indices {
            guard var list = cards[i].rechecks, list.contains(where: { $0.state == .waiting }) else { continue }
            for k in list.indices where list[k].state == .waiting {
                list[k].state = .failed
                list[k].note = "停止時還沒查完"
            }
            cards[i].rechecks = list
            changed = true
        }
        if changed { save() }
    }

    // MARK: v0.27.0 點一下改字、Pencil 圈起來重查

    /// 這張卡畫面上的行（含改過的）
    func lines(of id: Int) -> [CardLine] {
        guard let card = cards.first(where: { $0.id == id }) else { return [] }
        return CardLines.build(card, diff: diffs[id])
    }

    /// 使用者改一行：before 要和現在畫面上那行一樣才記（畫面剛好換掉時不亂改）
    /// v0.28.0：note＝「跟 AI 說」那格（不進逐字稿）；只寫 note 沒改字也記（before＝after，套用時跳過）
    func editLine(cardID: Int, line: Int, before: String, after: String, note: String = "") {
        let text = after.replacingOccurrences(of: "\n", with: "")
        let memo = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != before || !memo.isEmpty, var card = cards.first(where: { $0.id == cardID }) else { return }
        let current = CardLines.build(card, diff: diffs[cardID])
        let sameLine = line >= 0 && line < current.count && current[line].text == before
        // 畫面剛好換掉（例如 Haiku 剛整理回來）：字不改；有寫說明就照樣只存說明，不丟掉
        guard sameLine || !memo.isEmpty else { return }
        let changed = sameLine && text != before
        let edit = CardEdit(line: line, before: before, after: changed ? text : before, by: CardEdit.user, note: memo.isEmpty ? nil : memo)
        card.edits = (card.edits ?? []) + [edit]
        put(card)
        save()
        // log 不寫字（改的字、說明都只進卡片.json）
        onEvent(changed ? "使用者改了第 \(cardID) 張卡的一行" : "使用者在第 \(cardID) 張卡留了說明")
        // v0.28.0：改字、留說明之後照改好的逐字稿重算這張卡的重點和整理版（等幾秒沒再改才送）
        scheduleRefresh(cardID)
    }

    /// Pencil 圈起來：只送圈到的行＋這張卡的重點（不送整份逐字稿），Haiku 帶網路搜尋查。網路錯照卡片的重試；回來後只改圈到的行。
    /// v0.28.0：重查一個一個跑（前一個還沒回來就先寫「排隊中」）
    func recheck(cardID: Int, lines selected: [Int]) {
        recheck(selected.map { CardLineRef(card: cardID, line: $0) })
    }

    /// v0.28.0 跨卡：一筆圈選可以涵蓋相鄰幾張卡的行，合成一次重查。行照卡的時間順序接起來，重點用第一張卡的；
    /// 結果掛在圈到的第一張卡上（also 記其他卡），改法各自套回所屬的卡。
    func recheck(_ refs: [CardLineRef]) {
        guard !closed, !wrapped else { return }
        var parts: [RecheckPart] = []
        for group in RecheckPrompt.group(refs, order: cards.map(\.id)) {
            guard let card = cards.first(where: { $0.id == group.card }) else { continue }
            let lines = CardLines.build(card, diff: diffs[group.card]).map(\.text)
            let rows = group.rows.filter { $0 >= 0 && $0 < lines.count }
            if !rows.isEmpty {
                parts.append(RecheckPart(cardID: group.card, lines: lines, selected: rows))
            }
        }
        guard let first = parts.first, var card = cards.first(where: { $0.id == first.cardID }) else { return }
        let cardID = first.cardID
        let joined = RecheckPrompt.combine(parts)
        let texts = joined.selected.map { joined.lines[$0] }
        let id = nextRecheckID
        nextRecheckID += 1
        var item = CardRecheck(id: id, lines: first.selected, asked: texts.joined(separator: "\n"))
        var others: [RecheckSpan] = []
        for part in parts.dropFirst() {
            let start = cards.first(where: { $0.id == part.cardID })?.start
            others.append(RecheckSpan(cardID: part.cardID, lines: part.selected, start: start))
        }
        if !others.isEmpty {
            item.also = others
        }
        if let stop {
            item.state = .failed
            item.note = "Haiku 這場已停（\(stop.short)），沒有送"
        } else {
            item.note = rechecksInFlight > 0 ? "排隊中…" : "上網查資料中…"
        }
        card.rechecks = (card.rechecks ?? []) + [item]
        put(card)
        save()
        guard stop == nil else { return }
        onEvent("重查：第 \(cardID) 張卡圈了 \(texts.count) 行" + (others.isEmpty ? "" : "（跨 \(parts.count) 張卡）"))
        let message = RecheckPrompt.userMessage(course: course, key: card.key, lines: texts, nonCourse: nonCourse, topic: topic)
        enqueueRecheck(cardID: cardID, recheckID: id, message: message)
    }

    /// 排進重查的隊伍：前一個跑完才開始；收尾了就不送（finalizeCards 已經標「停止時還沒查完」）
    private func enqueueRecheck(cardID: Int, recheckID: Int, message: String) {
        rechecksInFlight += 1
        let previous = recheckChain
        recheckChain = Task {
            await previous?.value
            if !self.closed, !self.wrapped, self.stop == nil {
                self.updateRecheck(cardID, recheckID) { $0.note = "上網查資料中…" }
                await self.runRecheck(cardID: cardID, recheckID: recheckID, message: message)
            } else if !self.closed, !self.wrapped {
                self.failRecheck(cardID, recheckID, note: "Haiku 這場已停，沒有送")
            }
            self.rechecksInFlight -= 1
        }
    }

    private func runRecheck(cardID: Int, recheckID: Int, message: String) async {
        let result = await runWebSearch(system: RecheckPrompt.system, message: message, label: "重查", keepTrying: true,
                                        onNote: { (note: String) in self.updateRecheck(cardID, recheckID) { $0.note = note } },
                                        onCost: { (usd: Double) in self.addRecheckCost(cardID, usd: usd) })
        if result.cancelled { return }
        if let failure = result.failure {
            failRecheck(cardID, recheckID, note: failure)
            return
        }
        let all = result.content
        guard let reply = RecheckReply.parse(RecheckPrompt.text(all)) else {
            let error = RecheckPrompt.searchError(all).map { "（搜尋：\($0)）" } ?? ""
            failRecheck(cardID, recheckID, note: "回覆裡沒有規定的 JSON" + error)
            return
        }
        // v0.28.0：來源只列 Haiku 說支持結論的（舊格式只用引用），不再列全部搜尋結果
        finishRecheck(cardID, recheckID, reply: reply, sources: RecheckPrompt.sources(all, keep: reply.sources), cost: result.cost, searches: result.searches)
    }

    /// v0.29.1 上網查的那一段（Pencil 重查和參照詞搜尋共用一份：請求、pause_turn 接著送、重試、花費）。
    /// keepTrying：true＝網路錯照卡片的規則錄音中一直等（重查）；false＝網路錯（含沒網路）重試用完就算失敗（參照詞搜尋，不卡住排在後面的重查）。
    /// 429／5xx 兩邊都照 ReviewRetry.after。4xx 不算進卡片的「連續 400」、不停用這場（例如帳戶沒開網路搜尋）。
    /// onNote：等待中的一句（畫面）；onCost：每段回應的花費（呼叫的人決定算進哪裡）。
    private func runWebSearch(system: String, message: String, label: String, keepTrying: Bool,
                              onNote: (String) -> Void, onCost: (Double) -> Void) async -> WebSearchResult {
        let apiKey = key
        var assistant: [Any] = []
        var continuations = 0
        var attempts = 0
        var result = WebSearchResult()
        while !closed, !wrapped {
            let body = try? RecheckPrompt.body(userMessage: message, assistant: assistant, system: system)
            guard let body else {
                result.failure = "請求內容編不出來"
                return result
            }
            let outcome = await Task.detached { () -> HaikuOutcome in
                await HaikuClient.send(body: body, key: apiKey, session: HaikuClient.cardSession, timeout: HaikuClient.cardTimeout)
            }.value
            guard !closed, !wrapped else {
                result.cancelled = true
                return result
            }
            switch outcome {
            case .failure(let text, let offline):
                if !offline { attempts += 1 }
                let step: ReviewRetry.Step
                if keepTrying {
                    step = ReviewRetry.afterNetworkErrorCards(offline: offline, attempts: attempts)
                } else if offline {
                    step = .giveUp
                } else {
                    step = ReviewRetry.afterNetworkError(offline: false, attempts: attempts)
                }
                onNote("網路不通，等一下再查")
                onEvent("\(label)：\(text)")
                if case .retry(let after) = step {
                    try? await Task.sleep(for: .seconds(after))
                    continue
                }
                result.failure = "網路不通，沒查到"
                return result
            case .response(let data, let status, _, let retryAfter):
                attempts += 1
                let step = ReviewRetry.after(status: status, attempts: attempts, retryAfter: retryAfter)
                if case .retry(let after) = step {
                    onNote("Anthropic 忙，等一下再查")
                    try? await Task.sleep(for: .seconds(after))
                    continue
                }
                guard step == .parse else {
                    let reason = HaikuClient.errorText(data, status: status)
                    onEvent("\(label)沒成功：\(reason)")
                    result.failure = "沒查到（\(reason)）"
                    return result
                }
                guard let response = RecheckPrompt.parse(data) else {
                    result.failure = "回應不是預期的格式"
                    return result
                }
                let usd = RecheckPrompt.cost(usage: response.usage, searches: response.searches)
                result.answered = true
                result.cost += usd
                result.searches += response.searches
                onCost(usd)
                if response.stopReason == "pause_turn", continuations < RecheckPrompt.maxContinuations {
                    // 搜尋還沒做完：把這段回應原封不動接在 assistant 後面再送一次（不加「繼續」）
                    continuations += 1
                    assistant += response.content
                    continue
                }
                if response.stopReason == "refusal" {
                    result.failure = "Haiku 拒絕這次" + label
                    return result
                }
                result.content = assistant + response.content
                return result
            }
        }
        result.cancelled = true
        return result
    }

    private func updateRecheck(_ cardID: Int, _ recheckID: Int, _ change: (inout CardRecheck) -> Void) {
        guard var card = cards.first(where: { $0.id == cardID }), var list = card.rechecks,
              let k = list.firstIndex(where: { $0.id == recheckID }) else { return }
        change(&list[k])
        card.rechecks = list
        put(card)
    }

    private func failRecheck(_ cardID: Int, _ recheckID: Int, note: String) {
        updateRecheck(cardID, recheckID) { item in
            item.state = .failed
            item.note = note
        }
        save()
    }

    private func addRecheckCost(_ cardID: Int, usd: Double) {
        if let i = cards.firstIndex(where: { $0.id == cardID }) {
            cards[i].costUSD += usd
        }
        log.costUSD += usd
        if log.costUSD >= ReviewRetry.costCap {
            setStop(.costCap)
        }
    }

    /// v0.28.0：一次重查涉及的卡和圈到的行（每張卡用現在畫面上的行；跨卡的其他卡在 also）；卡不見了（批次合併）就跳過
    private func recheckParts(hostID: Int, item: CardRecheck) -> [RecheckPart] {
        var parts: [RecheckPart] = []
        for span in item.spans(host: hostID) {
            guard let card = cards.first(where: { $0.id == span.card }) else { continue }
            parts.append(RecheckPart(cardID: span.card, lines: CardLines.build(card, diff: diffs[span.card]).map(\.text), selected: span.lines))
        }
        return parts
    }

    /// 改動接到各卡的 edits 後面（卡不見了就跳過）
    private func addEdits(_ byCard: [Int: [CardEdit]]) {
        for (id, list) in byCard where !list.isEmpty {
            guard var card = cards.first(where: { $0.id == id }) else { continue }
            card.edits = (card.edits ?? []) + list
            put(card)
        }
    }

    /// 回來了：改法只套在圈到的行（old 要在那幾行找得到），改過的記成 web 改動（綠字）。
    /// v0.28.0：沒把握的猜測放 maybe（畫面有「套用」）；不論有沒有改字，都照逐字稿重算涉及的卡的重點（重點和逐字稿不一致時對齊）
    private func finishRecheck(_ cardID: Int, _ recheckID: Int, reply: RecheckReply, sources: [RecheckSource], cost: Double, searches: Int) {
        guard let host = cards.first(where: { $0.id == cardID }),
              let item = (host.rechecks ?? []).first(where: { $0.id == recheckID }) else { return }
        let parts = recheckParts(hostID: cardID, item: item)
        let joined = RecheckPrompt.combine(parts)
        let result = RecheckPrompt.apply(lines: joined.lines, selected: joined.selected, reply: reply)
        addEdits(RecheckPrompt.split(result.edits, owner: joined.owner))
        var unsure = reply.unsure
        if !result.lost.isEmpty {
            // 猜測的原字在圈起來的行裡找不到：不能套，寫進「沒把握」的字
            let lost = "可能：" + result.lost.map { $0.old + "→" + $0.new }.joined(separator: "、")
            unsure = unsure.isEmpty ? lost : unsure + "；" + lost
        }
        let finalUnsure = unsure
        let guesses = result.maybe.map { RecheckMaybe(old: $0.old, new: $0.new) }
        let applied = result.applied
        updateRecheck(cardID, recheckID) { entry in
            entry.state = .done
            entry.note = nil
            entry.conclusion = reply.conclusion
            entry.why = reply.why
            entry.sources = sources
            entry.applied = applied
            entry.maybe = guesses.isEmpty ? nil : guesses
            entry.unsure = finalUnsure.isEmpty ? nil : finalUnsure
            entry.costUSD = cost
            entry.searches = searches
        }
        save()
        onEvent("重查完：第 \(cardID) 張卡改 \(applied.count) 處、待確認 \(guesses.count) 處、搜尋 \(searches) 次、" + String(format: "%.4f 美元", cost))
        for part in parts {
            scheduleRefresh(part.cardID)
        }
    }

    /// v0.28.0 按「套用」（錄音中）：一個沒把握的猜測套進圈起來的行（記成 web 改動、綠字），標成已套用，再重算涉及的卡的重點
    func applyMaybe(cardID: Int, recheckID: Int, index: Int) {
        guard !closed, !wrapped, let host = cards.first(where: { $0.id == cardID }),
              let item = (host.rechecks ?? []).first(where: { $0.id == recheckID }) else { return }
        let list = item.maybe ?? []
        guard index >= 0, index < list.count, list[index].applied != true else { return }
        let guess = RecheckFix(old: list[index].old, new: list[index].new)
        let byCard = RecheckPrompt.applyMaybe(guess, parts: recheckParts(hostID: cardID, item: item))
        let ok = byCard.values.contains { !$0.isEmpty }
        addEdits(byCard)
        updateRecheck(cardID, recheckID) { entry in
            var marks = entry.maybe ?? []
            if index < marks.count {
                marks[index].applied = ok
            }
            entry.maybe = marks
            if ok {
                let done = entry.applied ?? []
                entry.applied = done + [guess]
            }
        }
        save()
        onEvent(ok ? "重查：第 \(cardID) 張卡按了套用" : "重查：第 \(cardID) 張卡按了套用，那幾行已經找不到原字")
        if ok {
            for id in byCard.keys.sorted() {
                scheduleRefresh(id)
            }
        }
    }

    // MARK: v0.28.0 逐字稿改了之後重算重點、整理版

    /// 排一次重算：只排整理到的卡；停用、收尾了不排。錄音中等最後一次改動後 CardRefresh.delay 秒（再被改就從頭等），停止後馬上送。
    /// 正在送的時候又被改＝跑完再跑一次。私人課程、沒金鑰、Haiku 關掉時根本沒有這個審稿器，所以不會送。
    private func scheduleRefresh(_ id: Int) {
        guard cardMode, !closed, !wrapped, stop == nil,
              let card = cards.first(where: { $0.id == id }), card.state == .done else { return }
        if refreshRunning.contains(id) {
            refreshAgain.insert(id)
        } else {
            refreshDue[id] = Date().addingTimeInterval(feeding ? CardRefresh.delay : 0)
        }
        refreshing.insert(id)
    }

    /// 排著的都不送了（保持舊的重點）；正在送的照樣等它回來
    private func dropRefreshes() {
        guard !refreshDue.isEmpty || !refreshAgain.isEmpty else { return }
        refreshDue.removeAll()
        refreshAgain.removeAll()
        refreshing = refreshRunning
    }

    /// 每秒：時間到的重算送出去（沒網路先放著；停用、收尾了就全部放棄）
    private func sendRefreshes() {
        guard !refreshDue.isEmpty else { return }
        if stop != nil || wrapped {
            dropRefreshes()
            return
        }
        guard online else { return }
        let now = Date()
        let ready = refreshDue.filter { $0.value <= now && !refreshRunning.contains($0.key) }.map(\.key).sorted()
        for id in ready {
            startRefresh(id)
        }
    }

    private func startRefresh(_ id: Int) {
        refreshDue[id] = nil
        guard let card = cards.first(where: { $0.id == id }), card.state == .done else {
            refreshing.remove(id)
            return
        }
        let transcript = CardLines.build(card, diff: diffs[id]).map(\.text).filter { !$0.isEmpty }
        guard !transcript.isEmpty else {
            refreshing.remove(id)
            return
        }
        let message = CardRefresh.userMessage(transcript: transcript, notes: CardEdits.promptNotes(card.edits ?? []),
                                              key: card.key, tidy: card.tidy, topic: topic)
        let block = CardRefresh.courseBlock(course: course, nonCourse: nonCourse)
        refreshRunning.insert(id)
        Task {
            await self.runRefresh(id, courseBlock: block, message: message)
            self.refreshRunning.remove(id)
            self.refreshing.remove(id)
            if self.refreshAgain.remove(id) != nil {
                self.scheduleRefresh(id)
            }
        }
    }

    /// 送一次重算（不帶網路搜尋）。網路錯照 5／15／45 秒最多 3 次（停止後沒網路就不等）；失敗就保持舊的重點和整理版。
    /// 4xx 不算進卡片的「連續 400」；金鑰無效、沒額度照樣停用這場。花費算進這張卡和這場（含上限）。
    private func runRefresh(_ id: Int, courseBlock: String, message: String) async {
        let apiKey = key
        var attempts = 0
        while !closed, !wrapped, stop == nil {
            let outcome = await Task.detached { () -> HaikuOutcome in
                guard let body = try? CardRefresh.requestBody(courseBlock: courseBlock, userMessage: message) else {
                    return .failure(message: "請求內容編不出來", offline: false)
                }
                return await HaikuClient.send(body: body, key: apiKey, session: HaikuClient.cardSession, timeout: HaikuClient.cardTimeout)
            }.value
            guard !closed, !wrapped else { return }
            switch outcome {
            case .failure(let text, let offline):
                if !offline { attempts += 1 }
                if offline && !feeding {
                    onEvent("重點更新：停止後沒有網路，第 \(id) 張卡保持舊的")
                    return
                }
                guard case .retry(let after) = ReviewRetry.afterNetworkError(offline: offline, attempts: attempts) else {
                    onEvent("重點更新沒成功：\(text)（第 \(id) 張卡保持舊的）")
                    return
                }
                try? await Task.sleep(for: .seconds(after))
            case .response(let data, let status, _, let retryAfter):
                attempts += 1
                let step = ReviewRetry.after(status: status, attempts: attempts, retryAfter: retryAfter)
                if case .retry(let after) = step {
                    try? await Task.sleep(for: .seconds(after))
                    continue
                }
                guard step == .parse else {
                    if case .stop(let reason) = step {
                        setStop(reason)
                    }
                    onEvent("重點更新沒成功：" + HaikuClient.errorText(data, status: status) + "（第 \(id) 張卡保持舊的）")
                    return
                }
                let result = await Task.detached { CardRefresh.parseResponse(data) }.value
                guard !closed, !wrapped else { return }
                if let usage = result.usage {
                    addRecheckCost(id, usd: Cost.usd(usage))
                }
                switch result {
                case .reply(let reply, _):
                    applyRefresh(id, reply: reply)
                    return
                case .unreadable(let reason, _):
                    if attempts < 2 { continue }
                    onEvent("重點更新：回覆解析失敗（\(reason)），第 \(id) 張卡保持舊的")
                    return
                case .refusal:
                    onEvent("重點更新：Haiku 拒絕，第 \(id) 張卡保持舊的")
                    return
                case .truncated:
                    onEvent("重點更新：回覆超過長度上限，第 \(id) 張卡保持舊的")
                    return
                }
            }
        }
    }

    /// 重算回來：只換這張卡的重點和整理版（卡片重新找一次，不蓋掉等的時候新加的改字、重查）
    private func applyRefresh(_ id: Int, reply: CardRefreshReply) {
        guard let i = cards.firstIndex(where: { $0.id == id }), cards[i].state == .done else { return }
        cards[i].key = reply.key
        if !reply.tidy.isEmpty {
            cards[i].tidy = reply.tidy
        }
        save()
        onEvent("重點更新：第 \(id) 張卡照改好的逐字稿重寫了重點和整理版")
    }

    /// v0.27.0 討論會停止後分人：這一段的卡（依時間）每行配上時間（用這張卡那批的單位），沒進卡的字當最後一組
    func speakerLines() -> [[SpeakerLine]] {
        let mine = cards.filter { $0.id >= firstBatchID }.sorted { $0.start < $1.start }
        let byBatch = Dictionary(log.batches.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let unitByID = Dictionary(splitter.units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [[SpeakerLine]] = []
        var covered = Set<Int>()
        for card in mine {
            let ids = byBatch[card.id]?.unitIDs ?? []
            covered.formUnion(ids)
            let units = ids.compactMap { unitByID[$0] }.map { TimedPiece(text: $0.text, start: $0.start, end: $0.end) }
            out.append(CardSpeakers.times(lines: CardLines.build(card, diff: diffs[card.id]), units: units, start: card.start, end: card.end))
        }
        let tail = splitter.units.filter { !covered.contains($0.id) && !$0.text.isEmpty }
        if !tail.isEmpty {
            out.append(tail.map { SpeakerLine(text: $0.text, start: $0.start, end: $0.end) })
        }
        return out
    }

    /// 停止後的逐字稿（只有這一段）：各卡的擴寫依時間接起來，沒整理到的用原稿，沒進卡的原稿接在最後
    /// v0.28.0：gaps＝這一段錄音中斷的地方（續錄前幾段的不要給，前幾段的字在 head 裡已經標過）
    func cardTranscript(gaps: [RecordGap] = []) -> String {
        let mine = cards.filter { $0.id >= firstBatchID }
        let ids = Set(mine.map(\.id))
        let covered = Set(log.batches.filter { ids.contains($0.id) }.flatMap(\.unitIDs))
        let tail = splitter.units.filter { !covered.contains($0.id) }.map(\.text).joined()
        return CardText.transcript(mine, tail: tail, gaps: gaps)
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
        // v0.28.0：排著的重點重算不用再等去抖動，馬上送（收尾前跑完）
        let now = Date()
        for id in Array(refreshDue.keys) {
            refreshDue[id] = now
        }
        kick()
    }

    /// 補送：最多等 seconds 秒（牆上時間）。回傳沒送完的批數。
    /// v0.28.0：也等重點重算跑完；停止時沒網路就不等重算（保持舊的）。期限到了就收尾，之後晚回來的重算、重查都不套。
    func flush(seconds: Double) async -> Int {
        stopFeeding()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !closed {
            tick()
            if !online {
                dropRefreshes()
            }
            let refreshIdle = refreshDue.isEmpty && refreshRunning.isEmpty
            if !inFlight, rechecksInFlight == 0, refreshIdle, stop != nil || (pendingCount == 0 && splitter.unsent.isEmpty) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        wrapped = true
        dropRefreshes()
        refreshing.removeAll()
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

/// v0.29.1 上網查一次的結果（重查、參照詞搜尋共用）。failure＝失敗的原因（給畫面和紀錄，不含稿的字）；
/// cancelled＝停止收尾了（不寫失敗）；answered＝有拿到 200 的回應（花了錢）；content＝全部回應（含 pause_turn 前的）
private struct WebSearchResult {
    var content: [Any] = []
    var cost = 0.0
    var searches = 0
    var answered = false
    var failure: String? = nil
    var cancelled = false
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
