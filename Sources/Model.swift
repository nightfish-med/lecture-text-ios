import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// 要給系統分享畫面的檔。
struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// 右欄點了，稿要捲到這一句並閃一下。id 每次不同，同一句點兩次也會再跳。
struct JumpRequest: Equatable {
    let id = UUID()
    let range: NSRange
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case recording
        case copying
        case preparing
        case downloading(Double)
        case transcribing(Double)
        /// 分人中；nil 是算到看不出進度的階段（第一次下載模型、後段比對）。
        case separating(Double?)
        case correcting(Double)
        case failed(String)
    }

    /// 續錄：接在同一場後面錄。新的一段另存錄音檔，字接在原稿後面，時間加上前面的長度。
    struct Continuation {
        /// 續錄前的那一場：稿、講者、校正都照舊。
        let base: SavedRun
        /// 原稿＋分隔行；新的字接在後面。
        let head: String
        let basePieces: [TimedPiece]
        /// 前面幾段加起來多長，新段的時間都加上這個。
        let offset: Double
        let part: Int
        let file: URL
        /// v0.21：這段按下的時間（yyyyMMdd-HHmmss），存進 partStamps；定稿再跑一次 beginRun 也用同一個，不會變成定稿的時間。
        let stamp: String
    }

    private(set) var phase: Phase = .idle
    private(set) var run: SavedRun?
    /// 灰字：引擎還可能改。定稿後併進 run.text。
    private(set) var volatileText = ""
    /// 錄音中語音引擎出錯：錄音還在繼續，只是沒有字。
    private(set) var liveError: String?
    /// v0.20：錄音停了（超過 10 秒沒有聲音進來），紅字顯示；接回來就清掉。
    private(set) var stallNote: String?
    /// 最近一次蘋果 AI 分段的結果，顯示在畫面上。
    private(set) var arrangeNote: String?
    /// 預熱狀態，顯示在錄音鈕旁邊。
    private(set) var warmNote = "預熱中…"
    /// 上次閃退停在哪一步。
    private(set) var crashNote: String?
    /// 正在續錄第幾段；nil 是一般錄音。
    private(set) var continuing: Continuation?
    /// 匯出中或匯出失敗的說明。
    private(set) var exportNote: String?
    /// v0.21 錄音中按複製後短暫顯示「已複製到 mm:ss」。
    private(set) var liveCopyNote: String?
    /// v0.22：這場被按掉、不再自動改的原字（點綠底字 →「這場不再改這個詞」）。新的一場清空。
    private(set) var liveFixOff: Set<String> = []
    /// v0.22：錄音中畫面要套的對照表（課程表＋通用）。課名用正式名（簡稱照設定檔換成正式名）。
    /// v0.23.2：再加上 Haiku 這場學到、程式驗過的規則（依「這場不再改」過濾）；錄音中指定的課名優先。
    var liveFixRules: [LiveFixRule] {
        let course = reviewer?.course ?? run?.course.map(CourseSchedule.formalName)
        return LiveFix.rules(course: course, off: liveFixOff, learned: reviewer?.learned ?? [])
    }
    /// v0.23.2：這場錄音中送 Haiku 改字的審稿器；nil＝這場不送（沒金鑰、沒課名、這門課關著、私人課程或不在設定檔的課），行為和 v0.22 一樣。
    private(set) var reviewer: LiveReviewer?
    /// reviewer 是 nil 的原因（狀態列「Haiku：已關閉（…）」）
    private(set) var reviewOffReason = "還沒開始錄音"
    /// 沒送是因為沒有課名：錄音中狀態列可以點來指定
    private(set) var reviewNeedsCourse = false
    /// 這場用的投影片名字（狀態列）；nil＝沒有投影片
    private(set) var sessionSlides: String?
    /// 開始錄音前指定「這場是哪門課」（正式課名）；按錄音用掉一次就清空。nil＝照課表。
    private(set) var chosenCourse: String?
    /// 續錄時原場的改字紀錄
    @ObservationIgnored private var reviewBase: ReviewLog?
    /// 這次 transcribe 的定稿有沒有完整跑完（停止後補定稿命中要用）
    @ObservationIgnored private var finalDone = false
    @ObservationIgnored private var reviewBackground: UIBackgroundTaskIdentifier = .invalid
    /// v0.23.5：按停止到定稿、Haiku 補送都結束之間是 true（下課 Whisper 等它）
    @ObservationIgnored private var stopFlowActive = false
    @ObservationIgnored private var liveCopyTask: Task<Void, Never>?
    /// 有值就跳系統分享畫面。
    var share: ShareFile?
    var appleAIStatus: String { AppleAI.statusLine }
    /// 辨識中只顯示最後一小段；全文等結束才放進畫面（幾小時的課字很多）。
    var liveTail: String { String((run?.text ?? "").suffix(300)) }
    var recordingTail: String { String((run?.text ?? "").suffix(3000)) }
    /// v0.26.0 模式 1：還沒排進批次（還沒有卡）的 Whisper 字，卡片下面顯示；Apple 灰字另外接在後面（volatileText）
    var cardTail: String {
        guard let text = run?.text, let start = reviewer?.unsentOffset else { return "" }
        let body = String(text.dropFirst(min(max(start, 0), text.count)))
        return String(body.trimmingCharacters(in: .whitespacesAndNewlines).suffix(800))
    }

    var showImporter = false
    /// v0.15：開「連電腦」畫面（手機當電腦的麥克風）。
    var showLink = false
    /// 情境決定人數。0＝單人、上課（不分人），2＝兩人對談，3 以上＝指定人數，-1＝多人但不知道幾個（自動）。
    /// 預設單人：指定 2 人時單人錄音會被硬拆成假的 A、B，自動又會把兩人判成一人（真機實測），兩邊都不能當預設，所以由使用者選情境。
    /// 用新的鍵：舊鍵可能存著 2，沿用就等於沒修。
    var speakerMode: Int = UserDefaults.standard.object(forKey: "speakerScene") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(speakerMode, forKey: "speakerScene") }
    }
    /// 校正。0＝關閉，1＝離線（蘋果 AI 挑可能的同音字，只標註，不上網），2＝智慧（蘋果 AI 挑詞，過 PrivacyGate 才查維基，只標註）。
    /// 校正維持只標註，不改稿。全校正要連 Claude，手機還沒有。預設關閉：準度還沒驗。
    var fixMode: Int = UserDefaults.standard.integer(forKey: "fixMode") {
        didSet { UserDefaults.standard.set(fixMode, forKey: "fixMode") }
    }
    /// v0.24 即時模式（下一次錄音生效）。0＝Apple＋Haiku 15 秒一批（原本）；
    /// 1（v0.25）＝主稿用錄音中的 Whisper（約晚 15–20 秒），Whisper 還沒轉到的那一小段先用 Apple 灰字；Haiku 60 秒一批改 Whisper 稿、附 Apple 當證據；
    /// 2＝Apple＋Haiku 60 秒一批（不跑 Whisper，對照用）。
    var liveMode: Int = UserDefaults.standard.integer(forKey: "liveMode") {
        didSet { UserDefaults.standard.set(liveMode, forKey: "liveMode") }
    }
    static let liveModeNames = ["Apple＋Haiku（15 秒一批）", "Whisper 主稿＋Haiku 每 60 秒一張卡（重點、整理版、擴寫）", "Apple＋Haiku（60 秒一批，對照用）"]
    /// v0.25 模擬上課：下一個選來的檔當作錄音跑（4 倍速，Whisper、Haiku 都跑）
    var simulateNext = false
    @ObservationIgnored private var simSource: URL?
    /// v0.25 模式 1：這場主稿是 Whisper（停止後不跑 Apple 定稿）
    @ObservationIgnored private var whisperMain = false
    /// v0.25 模式 1：Apple 的字（這段錄音的秒數），灰字和 Haiku 證據用
    @ObservationIgnored private var applePieces: [TimedPiece] = []
    @ObservationIgnored private var appleVolatile = ""
    /// v0.24：這場錄音中的 Whisper（模式 1 才有）
    private(set) var liveWhisper: LiveWhisper?
    var speakerModeLabel: String {
        switch speakerMode {
        case 0: return "單人"
        case -1: return "自動"
        default: return "\(speakerMode) 人"
        }
    }

    @ObservationIgnored private var live: LiveSession?
    @ObservationIgnored private var liveURL: URL?
    @ObservationIgnored private var builder = LineBuilder()
    @ObservationIgnored private var pieces: [TimedPiece] = []
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var totalSeconds = 0.0
    @ObservationIgnored private var warm: LiveSession.Warm?
    @ObservationIgnored private var warmTask: Task<Void, Never>?
    @ObservationIgnored private var warmSeconds: Double?
    @ObservationIgnored private var pressedAt: Date?
    @ObservationIgnored private var firstWordSeconds: Double?
    @ObservationIgnored private var liveInfo: String?
    @ObservationIgnored private var finalGuard = FinalGuard<SavedRun>()
    @ObservationIgnored private var backgroundSince: Date?
    @ObservationIgnored private var backgroundTotal = 0.0
    /// 按停止的時間，定稿那次 beginRun 要帶過去。
    @ObservationIgnored private var stopStamp: String?
    /// 上次閃退停在哪一步（錯誤資料用）。
    @ObservationIgnored private var crashStep: String?
    /// 這一場的步驟紀錄，存進 run.log。
    @ObservationIgnored private var sessionLog: [String] = []
    /// 這次打開 App 以後的全部紀錄（只在記憶體）：錄音開不起來這類還沒有稿的錯誤也留得住。
    @ObservationIgnored private var launchLog: [String] = []
    @ObservationIgnored private var exporting = false
    /// v0.20 錄音看門狗：每秒比牆上時間和錄進檔的秒數。
    @ObservationIgnored private var watch = RecordWatch()
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// 這段真的開始收音的時間（牆上時間從這裡算）。
    @ObservationIgnored private var partStartedAt: Date?
    @ObservationIgnored private var lastRecoverTry = Date.distantPast

    /// v0.14：點一句從那裡播。
    let player: Playback
    /// v0.23.2：停止後把「匯出（不含錄音）」那包自動傳到 Google 雲端硬碟「轉文字App測試資料」（DriveSync.swift；可關、私人課程不傳）
    let drive: DriveUploader
    /// v0.23.4 實驗模式：同一個錄音檔給幾個引擎各轉一次（EngineLab.swift）
    let lab = EngineLab()
    /// v0.23.5：按停止後用 Whisper 在裝置上再轉一份（WhisperAfter.swift；星星選單開關，預設關）
    let whisper = WhisperAfter()
    /// 播不了的原因（沒有錄音、這句對不到時間），顯示在播放條的位置。
    private(set) var playNote: String?
    /// 右欄點了要跳到哪一句。
    private(set) var jump: JumpRequest?
    /// 點的那一句：幾句共用同一個開始時間時，亮點的那句，不亮同時間的最後一句。
    @ObservationIgnored private var anchor: Int?
    /// 這次錄音照課表對到的課（按下錄音時決定）。
    @ObservationIgnored private var pendingCourse: String?
    @ObservationIgnored private var mapCache: (stamp: String, text: String, map: TranscriptMap)?
    @ObservationIgnored private var marksCache: (key: String, marks: [SentenceMark])?
    /// 標記改了就加一，讀標記的畫面才會更新（標記本身放在不追蹤的快取裡）。
    private var marksVersion = 0

    /// 續錄時是整場的長度（前面幾段＋這段）。
    var recordingSeconds: TimeInterval { (continuing?.offset ?? 0) + (live?.seconds ?? 0) }
    /// 畫面上看得到版本，真機驗證才知道裝的是哪一版。
    var versionLine: String { "版本 \(AppInfo.version)" }

    var isBusy: Bool {
        switch phase {
        case .idle, .failed: return false
        default: return true
        }
    }

    init() {
        player = Playback()
        drive = DriveUploader()
        drive.onEvent = { [weak self] line in self?.log(line, toRun: false) }
        drive.onBanner = { [weak self] line in self?.showBanner(line) }
        // v0.23.5：錄音、轉文字、實驗模式在跑時 Whisper 不跑；紀錄也進這次開 App 的紀錄
        whisper.onLog = { [weak self] entry in self?.launchLog.append(entry) }
        whisper.canRun = { [weak self] in
            guard let self else { return false }
            return !self.isBusy && !self.lab.running && !self.stopFlowActive
        }
        lab.onRunning = { [weak self] running in
            if running {
                self?.whisper.pause("實驗模式在跑")
            } else {
                self?.whisper.kick("實驗模式跑完")
            }
        }
        // 課表、課程對照表從設定檔讀（Documents/設定/轉文字設定.json）；沒有檔＝不照課表命名、沒有課程對照表
        log(AppSettings.reload(root: Store.documents).line, toRun: false)
        #if DEBUG
        if applyDemo() { return }
        #endif
        watchBackground()
        run = Store.loadLastRun()
        refreshCourseSettings()
        if let step = Store.takeCrumb() {
            crashStep = step
            crashNote = "上次閃退在：\(step)。稿在那之前已存。"
            log("上次閃退在：\(step)", toRun: false)
        }
        warmUp()
        // v0.23.2：上次沒傳成的測試資料，開 App 幾秒後再試一次（沒登入、關著、沒設定時不動）
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.drive.retryPending()
        }
        // v0.23.5：上次沒轉完的下課 Whisper，開 App 10 秒後接著轉（在錄音就等停止）
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.whisper.kick("打開 App")
        }
    }

    /// 切到別的 App 時工作會暫停，分人秒數要把這段分開講。
    private func watchBackground() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.backgroundSince = Date()
                self?.whisper.enteredBackground()
                // v0.20：錄音中切出去要記（中斷常發生在背景）
                if self?.phase == .recording {
                    self?.log("錄音中切到背景（鎖螢幕或換 App）")
                }
            }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // v0.23.5：下課 Whisper 回到前景接著轉（在錄音就不動）
                self?.whisper.kick("回到前景")
                guard let self, let since = self.backgroundSince else { return }
                let away = Date().timeIntervalSince(since)
                self.backgroundTotal += away
                self.backgroundSince = nil
                if self.phase == .recording {
                    var line = "回到前景（離開 \(formatClock(away))）"
                    // 沒等到「打斷結束」的通知時，回到前景是最好接回來的時機
                    if let live = self.live, !live.micRunning {
                        line += "；麥克風停著，\(live.recover())"
                    }
                    self.log(line)
                }
                // v0.23.2：背景時沒回來的請求、該送的批，回到前景立刻補送
                self.reviewer?.kick()
                // v0.23.2：還有待傳的測試資料、上次試超過 10 分鐘就再試
                self.drive.retryIfDue()
                // 設定檔可能在「檔案」App 換過：不在錄音、轉文字時重讀
                if !self.isBusy { self.reloadSettings() }
            }
        }
    }

    private var backgroundSeconds: Double {
        backgroundTotal + (backgroundSince.map { Date().timeIntervalSince($0) } ?? 0)
    }

    // MARK: 紀錄（錯誤資料用，不放稿的字）

    /// toRun 是 false：還沒有這一場的稿（例如錄音開不起來），只記在這次開 App 的紀錄。
    private func log(_ line: String, toRun: Bool = true) {
        let entry = "\(Store.clock()) \(line)"
        launchLog.append(entry)
        guard toRun, run != nil else { return }
        sessionLog.append(entry)
        run?.log = sessionLog
    }

    // MARK: 預熱

    /// 開 App 和每次錄完都先熱好。失敗不擋錄音，只是第一個字比較晚。
    private func warmUp() {
        guard warm == nil, warmTask == nil else { return }
        warmNote = "預熱中…可以直接錄，字會晚一點"
        let started = Date()
        warmTask = Task { [weak self] in
            do {
                let locale = try await SpeechEngine.resolveTaiwanLocale()
                let ready = try await LiveSession.warmUp(locale: locale) { _ in }
                guard let self, !Task.isCancelled else { return }
                let seconds = Date().timeIntervalSince(started)
                self.warm = ready
                self.warmSeconds = seconds
                self.warmNote = String(format: "已就緒（預熱 %.1f 秒）", seconds)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.warmNote = "預熱沒成功，直接錄也可以：\(error.localizedDescription)"
                self.log("預熱沒成功：\(error.localizedDescription)", toRun: false)
            }
            self?.warmTask = nil
        }
    }

    private func noteFirstWord() {
        guard firstWordSeconds == nil, let pressedAt else { return }
        firstWordSeconds = Date().timeIntervalSince(pressedAt)
    }

    // MARK: 錄音

    /// 開始畫面的麥克風：錄新的一場。錄音中按就是停止。
    func recordButtonTapped() {
        if phase == .recording {
            stopRecording()
        } else if !isBusy {
            continuing = nil
            liveFixOff = []
            reviewBase = nil
            // v0.14：上課時段（前後幾分鐘，設定檔可調）按的，標題「11/10 幾何」、放進那一科的資料夾；不在上課時段照舊用時間
            // v0.23.2：開始前在 Haiku 圓鈕指定了「這場是哪門課」就用指定的（換回簡稱，標題、資料夾和上課時段錄的一樣）
            if let chosen = chosenCourse {
                pendingCourse = CourseSchedule.shortName(chosen)
                log("這場指定為「\(chosen)」", toRun: false)
            } else {
                pendingCourse = CourseSchedule.course(at: Date())
            }
            chosenCourse = nil
            startRecording(to: nil)
        }
    }

    /// v0.25 模擬上課：選來的檔當作錄音，4 倍速跑完整流程（Apple、Whisper、Haiku、匯出都和真的錄音一樣）。
    /// 課名照「下一場是哪門課」；沒指定 Haiku 會說沒有課名（可以錄音中再指定）。
    func simulate(_ url: URL) {
        guard !isBusy else { return }
        phase = .copying
        Task {
            do {
                let copy = try await Task.detached { try Store.copyToTemporary(url) }.value
                phase = .idle
                continuing = nil
                liveFixOff = []
                reviewBase = nil
                pendingCourse = chosenCourse.map(CourseSchedule.shortName)
                chosenCourse = nil
                simSource = copy
                startRecording(to: nil)
            } catch {
                log("模擬上課：選檔複製失敗（.\(url.pathExtension)）：\(error.localizedDescription)", toRun: false)
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// v0.25 模式 1：灰字＝Whisper 還沒轉到的 Apple 字（最多 200 字）
    private func refreshGray() {
        let covered = liveWhisper?.covered ?? 0
        applePieces.removeAll { $0.end < covered - 120 }
        let tail = applePieces.filter { $0.end > covered }.map(\.text).joined() + appleVolatile
        volatileText = TextCleanup.fix(String(tail.suffix(200)))
    }

    /// 結果畫面的麥克風：接著這一場往下錄。新的一段另存錄音檔，字接在原稿後面。
    func continueRecording() {
        // v0.16：電腦傳來的稿沒有手機的錄音（聲音在電腦），不能接著錄
        if run?.origin != nil {
            playNote = "這場是電腦傳來的稿，聲音在電腦上，不能接著錄。要錄新的一場先按 ✕"
            return
        }
        guard !isBusy, let base = run, !base.text.isEmpty else { return }
        let basePieces = Store.loadPieces(of: base)
        // v0.23.2：原場的改字紀錄（已學規則、這場不再改的詞、最大單位編號）讀回來；黑名單改存在這裡，App 重開後續錄也還在
        reviewBase = Store.loadReview(of: base)
        liveFixOff.formUnion(reviewBase?.off ?? [])
        let lastEnd = basePieces.last(where: { $0.end >= 0 })?.end ?? 0
        // 上次錄到一半被殺時 audioSeconds 可能沒更新，所以和最後一個字的時間取大的
        let offset = max(base.audioSeconds ?? 0, lastEnd)
        let part = (base.parts?.count ?? 1) + 1
        let file = Store.partFile(for: base, part: part)
        continuing = Continuation(
            base: base,
            head: PartJoin.head(base: base.text, part: part, offset: offset),
            basePieces: basePieces,
            offset: offset,
            part: part,
            file: file,
            stamp: Store.timestamp()
        )
        startRecording(to: file)
    }

    /// target 是 nil 就是新的一場；有值是續錄那段的檔（continuing 已經設好）。
    private func startRecording(to target: URL?) {
        // v0.23.5：下課 Whisper 讓路給錄音（標記留著，停止後接著轉）
        whisper.pause("開始錄音")
        player.unload()
        anchor = nil
        let url = target ?? Store.recordingsFolder(course: pendingCourse).appendingPathComponent("\(Store.timestamp()).caf")
        liveURL = url
        sessionLog = continuing?.base.log ?? []
        stopStamp = nil
        phase = .preparing  // 擋連按兩下
        // 還沒熱好就按：不等，馬上開始收音。熱好的那份這次不用，錄完再熱
        let ready = warm
        warm = nil
        pressedAt = Date()
        firstWordSeconds = nil
        liveInfo = ready == nil
            ? "按下時還沒預熱完"
            : String(format: "按下時已預熱（%.1f 秒）", warmSeconds ?? 0)
        if ready == nil {
            warmTask?.cancel()
            warmTask = nil
        }
        job = Task {
            do {
                let locale = try await SpeechEngine.resolveTaiwanLocale()
                beginRun(source: url.lastPathComponent, locale: locale)
                if let c = continuing {
                    log("續錄第 \(c.part) 段，從 \(formatClock(c.offset)) 接著錄；\(liveInfo ?? "")")
                } else {
                    log("開始錄音；\(liveInfo ?? "")")
                }
                // v0.24 即時模式 1：錄音中同時跑 Whisper（存檔那份聲音抄一份給它）
                liveWhisper?.cancel()
                liveWhisper = nil
                whisperMain = false
                applePieces = []
                appleVolatile = ""
                if liveMode == 1, let current = run {
                    let path = Store.reviewFile(of: current).path.replacingOccurrences(of: " 改字.json", with: " Whisper即時.txt")
                    let lw = LiveWhisper(offset: 0, saveTo: URL(fileURLWithPath: path))
                    lw.onPieces = { [weak self] new in
                        self?.appendLive(new)
                        self?.refreshGray()
                    }
                    lw.start()
                    liveWhisper = lw
                    whisperMain = true
                }
                let sim = simSource
                simSource = nil
                if let sim {
                    log("模擬上課：用選來的檔（.\(sim.pathExtension)）4 倍速當作錄音，Apple、Whisper、Haiku 照真的跑")
                }
                log("即時模式：\(Self.liveModeNames[min(max(liveMode, 0), 2)])")
                // v0.23.2：條件都符合（金鑰、課名、這門課開著、不是私人課程）才建審稿器；否則和 v0.22 一樣
                startReviewer(course: nil)
                UIApplication.shared.isIdleTimerDisabled = true
                live = try await LiveSession.start(
                    warm: ready,
                    locale: locale,
                    saveTo: url,
                    onDownload: { [weak self] fraction in
                        self?.phase = .downloading(fraction)
                    },
                    onFinal: { [weak self] new in
                        guard let self else { return }
                        self.noteFirstWord()
                        if self.whisperMain {
                            self.applePieces += new
                            self.appleVolatile = ""
                            self.refreshGray()
                            return
                        }
                        self.volatileText = ""
                        self.appendLive(new)
                    },
                    onVolatile: { [weak self] text in
                        guard let self else { return }
                        self.noteFirstWord()
                        if self.whisperMain {
                            self.appleVolatile = text
                            self.refreshGray()
                            return
                        }
                        self.volatileText = TextCleanup.fix(text)
                    },
                    onError: { [weak self] message in
                        self?.liveError = message
                        self?.log("錄音中語音引擎出錯：\(message)")
                    },
                    onEvent: { [weak self] line in
                        self?.log(line)
                    },
                    tap: liveWhisper?.tap,
                    simulate: sim,
                    onSimEnd: { [weak self] in
                        guard let self, self.phase == .recording else { return }
                        self.log("模擬上課：檔案放完，自動停止")
                        self.stopRecording()
                    }
                )
                phase = .recording
                startWatch()
            } catch {
                UIApplication.shared.isIdleTimerDisabled = false
                reviewer?.close()
                reviewer = nil
                liveWhisper?.cancel()
                liveWhisper = nil
                let message = error.localizedDescription
                log("\(continuing == nil ? "錄音" : "續錄")開不起來：\(message)", toRun: false)
                if let base = continuing?.base {
                    // 續錄沒開成：原稿照舊，不留分隔行
                    run = base
                    continuing = nil
                } else {
                    keepWhatWeHave()
                }
                phase = error is CancellationError ? .idle : .failed(message)
                warmUp()
            }
        }
    }

    /// 字已經邊講邊出來了，按停止只是收尾，不用再轉一次。
    private func stopRecording() {
        guard let session = live else {
            phase = .idle
            return
        }
        live = nil
        phase = .preparing
        // v0.23.5：定稿、Haiku 補送跑完前不開始下課 Whisper（最後 kick 時清掉）
        stopFlowActive = true
        // v0.20：先記下這段實際經過多久、停過幾次，再收麥克風
        let wall = partStartedAt.map { Date().timeIntervalSince($0) }
        let stalls = watch.stallCount
        stopWatch()
        job = Task {
            let seconds = await session.finish()
            // v0.25：Whisper 把剩下的聲音轉完（最多 60 秒）再收尾，主稿才完整；之後收掉，免得和下課 Whisper 同時佔記憶體
            if let lw = liveWhisper {
                lw.end()
                await lw.waitDone(60)
                log(lw.note)
            }
            // v0.23.2：停止餵字 → 還沒送的批補送，和整段重轉同時開始；包在背景時間裡最多等 60 秒（規格 A④）
            let review = reviewer
            var flush: Task<Int, Never>?
            if let review {
                beginReviewBackground()
                review.stopFeeding()
                // v0.26.0 模式 1：一張卡的回覆比較長、模擬上課 4 倍速會積幾批，最多等 180 秒
                let wait = review.cardMode ? 180.0 : 60.0
                flush = Task { await review.flush(seconds: wait) }
            }
            let ended = Store.timestamp()
            stopStamp = ended
            volatileText = ""
            UIApplication.shared.isIdleTimerDisabled = false
            run?.audioSeconds = (continuing?.offset ?? 0) + seconds
            run?.endedStamp = ended
            run?.finished = liveError == nil
            if let first = firstWordSeconds {
                liveInfo = (liveInfo ?? "") + String(format: "；第一個字 %.1f 秒", first)
            } else {
                liveInfo = (liveInfo ?? "") + "；錄音中沒有出字"
            }
            log("停止錄音：這段錄了 \(formatClock(seconds))；\(liveInfo ?? "")")
            if let wall {
                log(RecordWatch.stopLine(wall: wall, audio: seconds, stalls: stalls))
            }
            // 即時字先存；再用存下的錄音轉一次定稿（真機約 50 倍速）。定稿沒跑完就留即時字。
            let draft = run?.text.isEmpty == false ? run : nil
            // v0.23.5：下課 Whisper 的待辦先記在按停止的這場（定稿跑到一半 App 被收掉也留得住）；keepWhatWeHave 沒字時會換成上一場，要先拿
            let stopped = run
            let whisperQueued = whisper.enqueue(stopped)
            keepWhatWeHave()
            // v0.23.1：即時稿另存（live.txt）；要在定稿的 beginRun 清掉 pieces 之前
            if let draft {
                saveLiveDraft(draft)
            }
            finalDone = false
            if whisperMain {
                // v0.25 模式 1：主稿就是錄音中的 Whisper，不用 Apple 定稿換掉
                log("即時模式 1：主稿用錄音中的 Whisper，不跑 Apple 定稿")
                phase = .idle
            } else if let url = liveURL {
                await transcribe(audioURL: url, sourceName: url.lastPathComponent, draft: draft)
            } else {
                phase = .idle
            }
            // 新的一場的定稿是另一個檔名，即時稿複製一份過去，匯出定稿那場才帶得到
            if let draft, let finalRun = run, finalRun.startedStamp != draft.startedStamp {
                Store.copyLive(from: draft, to: finalRun)
            }
            // v0.23.5：定稿是另一場就把 Whisper 待辦搬過去（同一個錄音檔才搬）
            if whisperQueued {
                whisper.move(from: stopped, to: run)
            }
            // v0.23.2：定稿（或退回的即時稿）那場、定稿每小段先記下來；補送完再補定稿命中、寫改字紀錄（不擋下一場錄音）
            // 自動上傳等改字紀錄寫完才打包（fixes.json 才有定稿命中）；定稿失敗時傳的是退回的即時稿那場
            let uploadRun = run
            let uploadReport = errorReport()
            if let review, let flush {
                let finalRun = run
                let finalPieces = finalDone ? pieces : []
                let done = finalDone
                // v0.26.0 模式 1：續錄時原稿＋分隔行留著，只換這段（continuing 下面就清掉，先拿）
                let head = continuing?.head ?? ""
                Task {
                    let unsent = await flush.value
                    let swapped = await finishReview(review, unsent: unsent, finalRun: finalRun, finalPieces: finalPieces, finalDone: done, head: head)
                    autoUpload(swapped ?? uploadRun, fallbackReport: uploadReport)
                    // v0.23.5：定稿、Haiku 補送都結束才開始下課 Whisper
                    stopFlowActive = false
                    whisper.kick("停止後")
                }
            } else {
                autoUpload(uploadRun, fallbackReport: uploadReport)
                stopFlowActive = false
                whisper.kick("停止後")
            }
            continuing = nil
            warmUp()
        }
    }

    /// v0.23.2 自動上傳：這場要傳（不是私人課程、有課名、已登入、開著、client id 填了）就打包「匯出（不含錄音）」那一包，排進待傳清單。
    /// 打包在背景、失敗只記一行，不跳警告、不擋下一場錄音。錯誤資料（info.txt）用當下的；已經換到別場就用停止當下存的那份。
    private func autoUpload(_ target: SavedRun?, fallbackReport: String) {
        guard let target else { return }
        if let skip = DrivePlan.decide(configured: drive.configured, signedIn: drive.signedIn, enabled: drive.enabled, course: target.course) {
            // 沒設定、沒登入、關著不提；私人課程和沒課名在登入又開著時記一行，看得出為什麼沒傳
            if drive.configured, drive.signedIn, drive.enabled {
                log("自動上傳：這場不傳（\(skip.rawValue)）", toRun: false)
            }
            return
        }
        let report = run?.startedStamp == target.startedStamp ? errorReport() : fallbackReport
        let stamp = target.exportStamp
        Task {
            do {
                let zip = try await Task.detached {
                    try Store.makeExport(.session, run: target, report: report, stamp: stamp, scratch: "自動上傳")
                }.value
                drive.enqueue(zip: zip)
            } catch {
                log("自動上傳：打包失敗：\(error.localizedDescription)", toRun: false)
            }
        }
    }

    /// v0.23.1：按停止當下的即時稿存成「… 即時稿.txt」「… 即時時間.json」。續錄只存新的那段，接在原本的後面。
    /// 紀錄只寫字數，不寫稿的字。
    private func saveLiveDraft(_ live: SavedRun) {
        let body = PartJoin.split(live.text, head: continuing?.head ?? "").body
        let fresh = Array(pieces.dropFirst(continuing?.basePieces.count ?? 0))
        Store.saveLive(live, text: body, pieces: fresh, part: continuing?.part)
        log("即時稿另存：\(body.count) 字、\(fresh.count) 小段")
    }

    // MARK: v0.20 錄音看門狗

    /// 每秒看一次錄進檔的秒數有沒有在長：停了 10 秒就紅字、震一下、記一筆、試著接回麥克風；
    /// 停著時每 15 秒再試一次（別的 App 放掉聲音後才接得回來）；接回來記少了幾秒。
    /// 每 30 秒寫一次「錄音中」的閃退記號：App 在錄音中被系統關掉，下次打開會講停在錄音第幾分。
    private func startWatch() {
        watch = RecordWatch()
        partStartedAt = Date()
        stallNote = nil
        lastRecoverTry = .distantPast
        watchTask?.cancel()
        // v0.22：背景看門狗通知要的權限（第一次會問；拒絕了照樣錄音，只是不會通知）
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        watchTask = Task { [weak self] in
            var lastCrumb = -30.0
            var lastRearm = -WatchAlarm.rearmEvery
            var alerted = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.phase == .recording, let live = self.live, let started = self.partStartedAt else { return }
                let wall = Date().timeIntervalSince(started)
                let audio = live.seconds
                if let error = live.takeWriteError() {
                    self.log("錄音寫檔失敗（字照出，但錄音檔可能少一段）：\(error)")
                }
                switch self.watch.tick(wall: wall, audio: audio) {
                case .stalled(let at, let silent)?:
                    let spot = formatClock((self.continuing?.offset ?? 0) + at)
                    self.log("錄音停了：整場 \(spot) 起 \(Int(silent)) 秒沒有聲音進來（App 在\(self.backgroundSince == nil ? "前景" : "背景")，麥克風\(live.micRunning ? "開著但沒給聲音" : "被關了")）；\(live.recover())")
                    self.lastRecoverTry = Date()
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                case .resumed(let lost)?:
                    self.log("聲音又進來了：中間少了 \(formatClock(lost))")
                    self.stallNote = nil
                    alerted = false
                case nil:
                    break
                }
                if let silent = self.watch.silentFor(wall: wall) {
                    self.stallNote = RecordWatch.banner(silentFor: silent)
                    if Date().timeIntervalSince(self.lastRecoverTry) >= 15, !live.micRunning {
                        self.lastRecoverTry = Date()
                        let result = live.recover()
                        // 每 15 秒試一次；接不回來的同一句不重複寫，免得紀錄被洗掉
                        if !result.hasPrefix("接不回來") {
                            self.log("再試一次：\(result)")
                        }
                    }
                }
                // v0.22：錄音正常時每 15 秒把「一分鐘後提醒」往後延；App 在背景被暫停、延不了，提醒就會響。
                switch WatchAlarm.action(wall: wall, lastRearm: lastRearm, stalled: self.watch.stalled,
                                         inBackground: self.backgroundSince != nil, alerted: alerted) {
                case .rearm:
                    lastRearm = wall
                    self.armWatchAlarm(after: WatchAlarm.fireAfter)
                case .alertNow:
                    alerted = true
                    self.armWatchAlarm(after: 1)
                    self.log("背景中錄音停了：已送通知")
                case .none:
                    break
                }
                if wall - lastCrumb >= 30 {
                    lastCrumb = wall
                    Store.crumb("錄音中（整場 \(formatClock(self.recordingSeconds))）")
                }
            }
        }
    }

    /// v0.22：同一個 id 送新的就會蓋掉舊的，所以「延後」＝重送一個更晚的。
    private func armWatchAlarm(after seconds: Double) {
        let content = UNMutableNotificationContent()
        content.title = WatchAlarm.title
        content.body = WatchAlarm.body(course: run?.displayTitle)
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: WatchAlarm.identifier, content: content, trigger: trigger)
        )
    }

    private func stopWatch() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [WatchAlarm.identifier])
        watchTask?.cancel()
        watchTask = nil
        partStartedAt = nil
        stallNote = nil
        Store.crumb(nil)
    }

    private func beginRun(source: String, locale: Locale) {
        builder = LineBuilder()
        pieces = continuing?.basePieces ?? []
        totalSeconds = 0
        volatileText = ""
        liveError = nil
        if let c = continuing {
            // 續錄：同一場，稿頭、檔名都不變；新的字從分隔行後面開始
            var next = c.base
            next.text = c.head
            next.finished = false
            next.parts = (c.base.parts ?? [c.base.source]) + [c.file.lastPathComponent]
            // v0.14：記每段在整場的第幾秒開始，點一句播放時對得到第 2 段。v0.13 續錄過的舊稿沒有，播放時用長度加起來
            let firstOnly: [Double]? = (c.base.parts?.count ?? 1) == 1 ? [0] : nil
            let earlierStarts: [Double]? = c.base.partStarts ?? firstOnly
            next.partStarts = earlierStarts.map { $0 + [c.offset] }
            // v0.21：每段按下的時間（原始轉錄一段一個區塊）。舊稿沒存就從各步紀錄找，找不到就不記（匯出時整場一個區塊）
            let baseCount = c.base.parts?.count ?? 1
            let earlierStamps = ClassRecord.partStarts(
                stored: c.base.partStamps,
                first: c.base.recordedStamp ?? c.base.startedStamp,
                count: baseCount,
                log: c.base.log ?? []
            )
            next.partStamps = earlierStamps.map { $0 + [c.stamp] }
            next.endedStamp = stopStamp ?? c.base.endedStamp
            next.systemVersion = UIDevice.current.systemVersion
            next.appVersion = AppInfo.version
            next.log = sessionLog.isEmpty ? nil : sessionLog
            run = next
            return
        }
        var fresh = SavedRun(
            source: source,
            startedStamp: Store.timestamp(),
            engine: SpeechEngine.name,
            language: locale.identifier,
            systemVersion: UIDevice.current.systemVersion,
            audioSeconds: nil,
            convertSeconds: nil,
            finished: false,
            text: "",
            endedStamp: stopStamp,
            appVersion: AppInfo.version,
            log: sessionLog.isEmpty ? nil : sessionLog,
            course: pendingCourse
        )
        // v0.21：第 1 段的開始＝錄音檔名的時間（按下錄音）；選來的檔用轉成文字的時間
        fresh.partStamps = [fresh.recordedStamp ?? fresh.startedStamp]
        run = fresh
    }

    // MARK: 選檔

    func importFile(_ url: URL) {
        // v0.23.1：PDF 是投影片，不是要轉文字的錄音（「選檔案」和從「檔案」App 打開走同一條路）
        if url.pathExtension.lowercased() == "pdf" {
            importSlides(url)
            return
        }
        // 設定檔（課表、課程對照表）：檢查過才存進 Documents/設定/ 並套用；別的 .json 不收
        if url.pathExtension.lowercased() == "json" {
            importSettings(url)
            return
        }
        if simulateNext {
            simulateNext = false
            simulate(url)
            return
        }
        guard !isBusy else { return }
        continuing = nil
        // 選來的檔照舊用原檔名當標題，不照課表
        pendingCourse = nil
        player.unload()
        anchor = nil
        sessionLog = []
        stopStamp = nil
        phase = .copying
        job = Task {
            do {
                let copy = try await Task.detached { try Store.copyToTemporary(url) }.value
                defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
                await transcribe(audioURL: copy, sourceName: url.lastPathComponent)
            } catch {
                log("選檔複製失敗（.\(url.pathExtension)）：\(error.localizedDescription)", toRun: false)
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// 設定檔：檔名要是「轉文字設定」開頭的 .json（「檔案」App 重複時會叫「轉文字設定 2.json」）。
    /// 內容不寫進紀錄（有課名），只寫筆數。檢查沒過就不動原本的設定。
    func importSettings(_ url: URL) {
        guard url.deletingPathExtension().lastPathComponent.hasPrefix("轉文字設定") else {
            showBanner("只收「\(AppSettings.fileName)」這個設定檔；別的 .json 不收")
            return
        }
        guard !isBusy else {
            showBanner("錄音或轉文字中，等結束再匯入設定檔")
            return
        }
        Task {
            do {
                let data = try await Task.detached { () throws -> Data in
                    let copy = try Store.copyToTemporary(url)
                    defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
                    return try Data(contentsOf: copy)
                }.value
                let result = try AppSettings.install(data, root: Store.documents)
                log("匯入" + result.line, toRun: false)
                showBanner("已套用" + result.line)
                refreshCourseSettings()
            } catch {
                let line = error is AppSettings.Problem ? error.localizedDescription : "設定檔存不了：\(error.localizedDescription)"
                log("匯入設定檔失敗：\(line)", toRun: false)
                showBanner(line + "（沒有套用，原本的設定照舊）")
            }
        }
    }

    /// 重讀設定檔；內容變了才記一行、重讀課程選單
    private func reloadSettings() {
        let before = AppSettings.current
        let result = AppSettings.reload(root: Store.documents)
        guard AppSettings.current != before else { return }
        log(result.line, toRun: false)
        refreshCourseSettings()
    }

    /// v0.15 開始畫面的「連電腦」：沒在錄、沒在轉才開；先停播放（麥克風要換成收音）。
    func openLink() {
        guard !isBusy else { return }
        stopPlayback()
        log("開連電腦畫面", toRun: false)
        showLink = true
    }

    /// v0.16：電腦錄完（定稿或分好人）傳來的稿也存成手機上的一場，放逐字稿資料夾，
    /// 之後跟 App 自己錄的一樣能看全文、複製、長按匯出、點兩下標記。標題照 App 錄音的規則，用電腦按開始錄音的時間：
    /// 落在上課時段（前後幾分鐘）是「11/10 幾何」並放進那科的資料夾，不然「11/8 15:30」。
    /// 沒有錄音檔（聲音在電腦），所以點一句不能播、不能繼續錄。同一場再存一次蓋掉同一個檔（電腦上改過字、改過人再存）。
    /// 回傳給他看的一句話。
    func saveComputerRun(_ pc: PCTranscript) -> String {
        guard !isBusy else { return "手機正在錄音或轉文字，等一下再存" }
        guard pc.canSave, let stamp = pc.stamp else { return "電腦整理完（定稿或分好人）才能存" }
        let course = Self.date(fromStamp: stamp).flatMap { CourseSchedule.course(at: $0) }
        var saved = SavedRun(
            source: "\(stamp).電腦",
            startedStamp: stamp,
            engine: "電腦版「兩人對談轉文字」",
            language: "zh-TW",
            systemVersion: UIDevice.current.systemVersion,
            audioSeconds: pc.seconds > 0 ? pc.seconds : nil,
            convertSeconds: nil,
            finished: true,
            text: pc.finalText,
            speakers: pc.speakers.isEmpty ? nil : pc.speakers,
            speakerInfo: pc.speakerHow,
            appVersion: AppInfo.version,
            course: course
        )
        saved.origin = pc.originNote
        let entry = "\(Store.clock()) 存電腦傳來的稿：\(pc.lines.count) 句（\(pc.stage == "labelled" ? "分好人" : "定稿")）"
        launchLog.append(entry)
        sessionLog = [entry]
        saved.log = sessionLog
        player.unload()
        anchor = nil
        playNote = nil
        arrangeNote = nil
        exportNote = nil
        continuing = nil
        run = saved
        phase = .idle
        Store.saveTranscript(saved)
        let folder = course.map { "逐字稿／\(CourseSchedule.folderName($0))" } ?? "逐字稿"
        return "已存成「\(saved.displayTitle)」（\(folder) 資料夾）。關掉這個畫面就看得到，可以複製、長按匯出"
    }

    /// 20261108-153000 → 手機時區的那個時間（電腦送的是它的當地時間，沒有時區；手機和電腦在同一個地方）。
    private static func date(fromStamp stamp: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: stamp)
    }

    func importFailed(_ error: Error) {
        log("選檔失敗：\(error.localizedDescription)", toRun: false)
        phase = .failed(error.localizedDescription)
    }

    // MARK: v0.23.1 Haiku 金鑰、投影片、課程設定（錄音中送 Haiku 是 0.23.2）

    /// 選單上一門課的樣子。
    struct CourseSetting: Identifiable, Equatable {
        var id: String { course }
        /// 正式課名
        let course: String
        /// 「lecture-17（55 頁）」；nil＝還沒有投影片
        let slides: String?
        let haiku: Bool
        /// 私人課程（和不在設定檔的課）是 false：永遠不送、開關不能開
        let allowed: Bool
    }

    /// 不在上課時段匯入的投影片：字抽好了，等他選是哪門課才存。
    struct PendingSlides: Identifiable {
        let id = UUID()
        let source: String
        let pages: [String]
    }

    /// 鑰匙圈裡有金鑰時是 sk-ant-…末4碼；金鑰本身不放在畫面狀態裡。
    private(set) var haikuKeyLabel: String? = HaikuKey.read().map(HaikuKey.masked)
    /// 貼上、刪除、測試連線的結果（開始畫面小字）。
    private(set) var haikuNote: String?
    private(set) var haikuTesting = false
    /// 第一次貼金鑰前先講一次會送什麼。
    var showHaikuIntro = false
    /// 投影片匯入的結果（開始畫面小字），例：「解析幾何：lecture-17（55 頁）」。
    private(set) var slideNote: String?
    /// 有值就跳「這份投影片是哪門課」選單。
    var pendingSlides: PendingSlides?
    /// 每門課的投影片和要不要送 Haiku（開 App、匯入、切開關時重讀）。
    private(set) var courseSettings: [CourseSetting] = []
    /// 不在上課時段時，選單的「這門課」用最近匯入投影片的那門。
    private(set) var lastSlidesCourse: String?
    /// 畫面上方幾秒就消失的一行（投影片匯入結果、測試連線結果），哪個畫面都看得到。
    private(set) var banner: String?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?

    /// 課表上的課（正式課名、不重複、照課表順序）；includePrivate 是 false 時拿掉私人課程（投影片選課用）。
    static func scheduleCourses(includePrivate: Bool) -> [String] {
        var seen: [String] = []
        for slot in CourseSchedule.slots {
            let formal = CourseSchedule.formalName(slot.name)
            if seen.contains(formal) { continue }
            if !includePrivate, !CourseProfile.allowsUpload(course: formal) { continue }
            seen.append(formal)
        }
        return seen
    }

    /// Haiku 選單的「這門課」：現在是上課時段就是那門；不是就用最近匯入投影片的那門；都沒有是 nil。
    var currentCourse: String? {
        if let now = CourseSchedule.course(at: Date()) { return CourseSchedule.formalName(now) }
        return lastSlidesCourse
    }

    func refreshCourseSettings() {
        var newest: (course: String, at: String)?
        courseSettings = Self.scheduleCourses(includePrivate: true).map { course in
            let deck = SlideImport.latest(course: course)
            if let deck, deck.importedAt > (newest?.at ?? "") {
                newest = (course, deck.importedAt)
            }
            let profile = CourseProfile.load(course: course, root: Store.documents)
            return CourseSetting(
                course: course,
                slides: deck.map { "\($0.name)（\($0.pages.count) 頁）" },
                haiku: profile.haiku,
                allowed: CourseProfile.allowsUpload(course: course)
            )
        }
        lastSlidesCourse = newest?.course
    }

    func setHaiku(_ on: Bool, course: String) {
        guard CourseProfile.allowsUpload(course: course) else { return }
        var profile = CourseProfile.load(course: course, root: Store.documents)
        profile.haiku = on
        do {
            try profile.save(course: course, root: Store.documents)
            log("課程設定：\(course) \(on ? "送" : "不送") Haiku", toRun: false)
        } catch {
            haikuNote = "課程設定存不了：\(error.localizedDescription)"
        }
        refreshCourseSettings()
    }

    /// 選單的「貼上金鑰」：第一次先跳說明，按了「貼上」才讀剪貼簿。
    func pasteKeyTapped() {
        if UserDefaults.standard.bool(forKey: "haikuIntroShown") {
            pasteKey()
        } else {
            showHaikuIntro = true
        }
    }

    func confirmHaikuIntro() {
        UserDefaults.standard.set(true, forKey: "haikuIntroShown")
        pasteKey()
    }

    /// 讀剪貼簿 → 檢查 sk-ant- → 存鑰匙圈 → 清掉剪貼簿。紀錄和畫面只寫末 4 碼。
    private func pasteKey() {
        switch HaikuKey.paste(UIPasteboard.general.string) {
        case .failure(let problem):
            haikuNote = problem.message
            log("貼上金鑰沒存：\(problem.message)", toRun: false)
        case .success(let masked):
            // 金鑰不要留在剪貼簿（別的 App 讀得到）；只寫不讀，不會再跳「允許貼上」
            UIPasteboard.general.items = []
            haikuKeyLabel = masked
            haikuNote = "已存進鑰匙圈（\(masked)），剪貼簿已清空。按「測試連線」看能不能用"
            log("API 金鑰：已存（\(masked)）", toRun: false)
        }
    }

    func deleteKey() {
        HaikuKey.delete()
        haikuKeyLabel = nil
        haikuNote = "已刪除金鑰"
        log("API 金鑰：已刪除", toRun: false)
    }

    /// 送一句「回答：好」給 Haiku，看金鑰能不能用、要幾秒（15 秒逾時）。
    func testHaiku() {
        guard !haikuTesting else { return }
        guard let key = HaikuKey.read() else {
            haikuNote = "還沒有金鑰：先貼上金鑰"
            return
        }
        haikuTesting = true
        haikuNote = "測試連線中…"
        Task {
            let result = await HaikuClient.testConnection(key: key)
            haikuTesting = false
            haikuNote = result.line
            showBanner(result.line)
            log("測試連線：\(result.line)", toRun: false)
        }
    }

    /// PDF：複製到暫存、抽字（背景）；現在是上課時段就存進那門課，不是就問是哪門課。PDF 本身不留。
    func importSlides(_ url: URL) {
        let source = url.lastPathComponent
        slideNote = "讀投影片中…"
        Task {
            do {
                let pages = try await Task.detached { () throws -> [String] in
                    let copy = try Store.copyToTemporary(url)
                    defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
                    return try SlideImport.extractPages(copy)
                }.value
                let pending = PendingSlides(source: source, pages: pages)
                if let now = CourseSchedule.course(at: Date()), CourseProfile.allowsUpload(course: now) {
                    saveSlides(pending, course: CourseSchedule.formalName(now))
                } else {
                    slideNote = "\(pages.count) 頁的投影片：選是哪門課"
                    pendingSlides = pending
                }
            } catch {
                let line = "投影片讀不到：\(error.localizedDescription)"
                slideNote = line
                showBanner(line)
                // 檔名可能有人名，只寫副檔名
                log("投影片匯入失敗（.pdf）：\(error.localizedDescription)", toRun: false)
            }
        }
    }

    /// 存進這門課（course 給正式課名）。結果一行：「解析幾何：lecture-17（55 頁）」。
    func saveSlides(_ pending: PendingSlides, course: String) {
        pendingSlides = nil
        let pages = pending.pages
        let source = pending.source
        Task {
            do {
                let deck = try await Task.detached {
                    try SlideImport.save(pages: pages, source: source, course: course)
                }.value
                slideNote = deck.summary
                showBanner(deck.summary)
                log("匯入投影片：\(deck.course)，\(deck.pages.count) 頁（有字 \(deck.pagesWithText) 頁，估約 \(deck.estimatedTokens) token）", toRun: false)
                refreshCourseSettings()
            } catch {
                let line = "投影片存不了：\(error.localizedDescription)"
                slideNote = line
                showBanner(line)
                log("投影片存檔失敗：\(error.localizedDescription)", toRun: false)
            }
        }
    }

    /// 選了「其他」：不存。
    func skipSlides(_ pending: PendingSlides) {
        pendingSlides = nil
        slideNote = "投影片沒有存（選了其他）"
        showBanner("投影片沒有存（選了其他）")
    }

    private func showBanner(_ line: String) {
        banner = line
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    func dismissBanner() {
        bannerTask?.cancel()
        banner = nil
    }

    // MARK: 轉文字

    func cancel() {
        job?.cancel()
    }

    /// draft 是按停止時已存好的完整即時稿。定稿完整跑完才換掉它；中途被打斷（按停止、失敗、閃退）畫面和「最近一次」都留它。
    /// 續錄時只轉新的那段錄音，字接在原稿後面。
    private func transcribe(audioURL: URL, sourceName: String, draft: SavedRun? = nil) async {
        whisper.pause("轉文字")
        finalGuard.begin(draft: draft)
        defer { finalGuard.finish() }
        phase = .preparing
        Store.crumb("定稿")
        defer { Store.crumb(nil) }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        var extracted: URL?
        defer {
            if let extracted, extracted != audioURL {
                try? FileManager.default.removeItem(at: extracted)
            }
        }

        do {
            let locale = try await SpeechEngine.resolveTaiwanLocale()
            beginRun(source: sourceName, locale: locale)
            if let c = continuing {
                log("定稿開始：續錄第 \(c.part) 段的錄音")
            } else {
                log(audioURL == liveURL ? "定稿開始：這次的錄音" : "轉文字開始：選來的檔（.\(audioURL.pathExtension)）")
            }
            let readable = try await SpeechEngine.readableAudio(at: audioURL)
            extracted = readable
            let offset = continuing?.offset ?? 0

            let result = try await SpeechEngine.transcribe(
                audioURL: readable,
                locale: locale,
                onStart: { [weak self] seconds in
                    self?.totalSeconds = seconds
                    self?.run?.audioSeconds = offset + seconds
                    self?.phase = .transcribing(0)
                },
                onDownload: { [weak self] fraction in
                    self?.phase = .downloading(fraction)
                },
                onSegment: { [weak self] new, reached in
                    self?.append(new, reached: reached)
                }
            )
            run?.audioSeconds = offset + result.audioSeconds
            run?.convertSeconds = (continuing?.base.convertSeconds ?? 0) + result.convertSeconds
            run?.finished = true
            // 先算好再寫：右邊又讀 run 會和寫入重疊（v0.14.16 定稿閃退：Swift 執行期 exclusivity 檢查）
            let newLiveInfo = PartJoin.note(run?.liveInfo, part: continuing?.part, liveInfo)
            run?.liveInfo = newLiveInfo
            liveInfo = nil
            let speed = result.convertSeconds > 0 ? result.audioSeconds / result.convertSeconds : 0
            log(String(format: "定稿完成：音檔 %@，轉換 %.1f 秒（%.1f 倍速）", formatClock(result.audioSeconds), result.convertSeconds, speed))
            let fresh = PartJoin.split(run?.text ?? "", head: continuing?.head ?? "").body
            if fresh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let line = String(
                    format: "沒有辨識到文字（音檔 %@，轉換 %.1f 秒）",
                    formatClock(result.audioSeconds),
                    result.convertSeconds
                )
                log(line)
                keepAfterInterruption()
                phase = .failed(line)
            } else {
                finalGuard.finish()   // 定稿完整了，才可以換掉即時稿
                finalDone = true
                keepWhatWeHave()   // 沒分人的稿先存，分人出事也留得住
                await labelSpeakers(audioURL: readable)
                keepWhatWeHave()
                // v0.15：續錄不到 2 秒（多半是誤按）不跑校正：字太少，校了也只是多等、容易被收起打斷
                if continuing != nil, result.audioSeconds < 2 {
                    log(String(format: "續錄這段只有 %.1f 秒，沒跑校正", result.audioSeconds))
                } else {
                    await correctWithAppleAI()
                    await checkTermsWithWiki()
                }
                keepWhatWeHave()
                phase = .idle
            }
        } catch is CancellationError {
            log("定稿中途停止")
            keepAfterInterruption()
            phase = .idle
        } catch {
            log("定稿失敗：\(error.localizedDescription)")
            keepAfterInterruption()
            phase = .failed(error.localizedDescription)
        }
    }

    /// 定稿沒跑完。跑到一半的片段只留在它自己的檔，畫面和「最近一次」回到完整的即時稿。沒有即時稿（選檔）才留已出來的字。
    /// 續錄的定稿和原稿是同一個檔，跑到一半的片段不另存。
    private func keepAfterInterruption() {
        guard var draft = finalGuard.interrupt() else {
            keepWhatWeHave()
            return
        }
        if let partial = run, !partial.text.isEmpty, partial.startedStamp != draft.startedStamp {
            Store.saveTranscript(partial, pieces: pieces, updateLast: false)
        }
        draft.liveInfo = PartJoin.note(draft.liveInfo, part: continuing?.part, (liveInfo ?? "") + "；定稿沒跑完，這是錄音當下的字")
        draft.log = sessionLog.isEmpty ? nil : sessionLog
        liveInfo = nil
        pieces = []
        builder = LineBuilder()
        run = draft
        Store.saveTranscript(draft)
    }

    private func checkTermsWithWiki() async {
        guard fixMode == 2, let source = run else { return }
        // 續錄只查新的那段；原稿那段已經查過
        let parts = PartJoin.split(source.text, head: continuing?.head ?? "")
        guard !parts.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Store.crumb("智慧校正挑詞開始")
        phase = .correcting(0)
        let started = Date()
        let picked = await AppleAI.pickTerms(of: parts.body) { [weak self] fraction in
            guard let self, case .correcting = self.phase else { return }
            Store.crumb(String(format: "智慧校正挑詞 %.0f%%", fraction * 100))
            self.phase = .correcting(fraction * 0.5)
        }
        phase = .correcting(0.5)
        Store.crumb("智慧校正查維基")
        // 擋人名看整份稿：前面講過「王小明老師」，後面的「王小明」也不送
        let checked = await Wiki.check(picked.picks, transcript: source.text)
        run?.text = parts.head + TermCheck.annotate(checked.notes, in: parts.body)
        // 先算好再寫：右邊又讀 run 會和寫入重疊（v0.14.16 定稿閃退：Swift 執行期 exclusivity 檢查）
        let newNotes = (run?.notes ?? []) + checked.notes
        run?.notes = newNotes
        let count: (String) -> Int = { status in checked.notes.filter { $0.status == status }.count }
        var note = String(
            format: "智慧校正：維基有 %d、有提到 %d、未確認 %d、像人名沒送查 %d，%.0f 秒。字沒改；維基有不代表稿裡講的就是它",
            count("found"), count("judge"), count("none"), count("held"), Date().timeIntervalSince(started)
        )
        if picked.failed > 0 {
            note += "；挑詞失敗 \(picked.failed) 塊"
        }
        if picked.cancelled {
            note += "；已取消（後面的沒挑）"
        }
        if let error = picked.firstError ?? checked.error {
            note += "；\(error)"
        }
        log(note)
        // 先算好再寫：右邊又讀 run 會和寫入重疊（v0.14.16 定稿閃退：Swift 執行期 exclusivity 檢查）
        let newFixInfo = PartJoin.note(run?.fixInfo, part: continuing?.part, note)
        run?.fixInfo = newFixInfo
    }

    /// 校正失敗或中途停止都留著原稿，只在畫面上講原因。
    private func correctWithAppleAI() async {
        guard fixMode == 1, let source = run else { return }
        // 續錄只校新的那段；原稿那段的標註和提示照舊
        let parts = PartJoin.split(source.text, head: continuing?.head ?? "")
        guard !parts.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Store.crumb("離線校正開始")
        phase = .correcting(0)
        let started = Date()
        let outcome = await AppleAI.corrections(of: parts.body) { [weak self] fraction in
            guard let self, case .correcting = self.phase else { return }
            Store.crumb(String(format: "離線校正 %.0f%%", fraction * 100))
            self.phase = .correcting(fraction)
        }
        let hints = outcome.hints.flatMap(\.edits)
        run?.text = parts.head + TextMarker.mark(hints: outcome.hints, in: parts.body)
        // 先算好再寫：右邊又讀 run 會和寫入重疊（v0.14.16 定稿閃退：Swift 執行期 exclusivity 檢查）
        let newHints = (run?.hints ?? []) + hints
        run?.hints = newHints
        var summary = String(
            format: "離線校正：標 %d 個可能的錯字，字沒改，%.0f 秒（成功 %d 塊、失敗 %d 塊）",
            hints.count, Date().timeIntervalSince(started), outcome.succeeded, outcome.failed
        )
        // v0.15：按 ✕／停止造成的取消記「已取消」，不算失敗、不出英文錯誤句
        if outcome.cancelled {
            summary += "；已取消（後面的沒校）"
        }
        var note = summary
        if !hints.isEmpty {
            note += "：" + hints.prefix(8).map { "\($0.wrong)→\($0.right)？" }.joined(separator: "、")
        }
        if let error = outcome.firstError {
            note += "；\(error)"
        }
        // 紀錄裡不放標了哪些字（那是稿的內容）
        log(summary + (outcome.firstError.map { "；\($0)" } ?? ""))
        // 先算好再寫：右邊又讀 run 會和寫入重疊（v0.14.16 定稿閃退：Swift 執行期 exclusivity 檢查）
        let newFixInfo = PartJoin.note(run?.fixInfo, part: continuing?.part, note)
        run?.fixInfo = newFixInfo
    }

    /// 分人失敗或中途停止都留著原稿，只在畫面上講原因。
    /// 續錄只分新的那段（不重分整場）：原稿的 A、B 不動，新段自己從 A 開始，兩段的 A、B 不一定是同一人。
    private func labelSpeakers(audioURL: URL) async {
        let fresh = Array(pieces.dropFirst(continuing?.basePieces.count ?? 0))
        guard speakerMode != 0, !fresh.isEmpty else { return }
        Store.crumb("分人")
        phase = .separating(nil)
        let started = Date()
        let backgroundBefore = backgroundSeconds
        let part = continuing?.part
        do {
            let result = try await SpeakerEngine.run(
                audioURL: audioURL,
                count: speakerMode > 0 ? speakerMode : nil
            ) { [weak self] fraction in
                // 進度是另外排隊送來的，可能比結束還晚到；不是分人中就不理，畫面才不會卡住
                guard let self, case .separating = self.phase else { return }
                self.phase = .separating(fraction >= 1 ? nil : fraction)
            }
            try Task.checkCancellation()
            let turns = PartJoin.shift(result.turns, by: continuing?.offset ?? 0, part: part)
            let labeled = SpeakerLabeler.label(pieces: fresh, turns: turns)
            guard !labeled.names.isEmpty else {
                let line = "分人：沒有找到講話的段落，這\(part == nil ? "份" : "段")沒分人"
                log(line)
                // 先算好再寫：右邊又讀 run 會和寫入重疊（v0.14.16 定稿閃退：Swift 執行期 exclusivity 檢查）
                let newSpeakerInfo = PartJoin.note(run?.speakerInfo, part: part, line)
                run?.speakerInfo = newSpeakerInfo
                return
            }
            run?.text = (continuing?.head ?? "") + labeled.text
            // 先算好再寫：右邊又讀 run 會和寫入重疊（v0.14.16 定稿閃退：Swift 執行期 exclusivity 檢查）
            let newSpeakers = PartJoin.merge(run?.speakers, labeled.names)
            run?.speakers = newSpeakers
            let line = SpeakerReport.line(
                count: labeled.names.count,
                forced: speakerMode > 0,
                wall: Date().timeIntervalSince(started),
                timing: result.timing,
                background: backgroundSeconds - backgroundBefore
            )
            log(line)
            // 先算好再寫：右邊又讀 run 會和寫入重疊（v0.14.16 定稿閃退：Swift 執行期 exclusivity 檢查）
            let newSpeakerInfo = PartJoin.note(run?.speakerInfo, part: part, line)
            run?.speakerInfo = newSpeakerInfo
            if let run {
                let earlier = continuing == nil ? [] : Store.loadTurns(of: run)
                Store.saveTurns(run, turns: earlier + turns)
            }
        } catch is CancellationError {
            log("分人中途停止")
            // 先算好再寫：右邊又讀 run 會和寫入重疊（v0.14.16 定稿閃退：Swift 執行期 exclusivity 檢查）
            let newSpeakerInfo = PartJoin.note(run?.speakerInfo, part: part, "分人中途停止，這\(part == nil ? "份" : "段")沒分人")
            run?.speakerInfo = newSpeakerInfo
        } catch {
            log("分人失敗：\(error.localizedDescription)")
            // 先算好再寫：右邊又讀 run 會和寫入重疊（v0.14.16 定稿閃退：Swift 執行期 exclusivity 檢查）
            let newSpeakerInfo = PartJoin.note(run?.speakerInfo, part: part, "分人失敗，這\(part == nil ? "份" : "段")沒分人：\(error.localizedDescription)")
            run?.speakerInfo = newSpeakerInfo
        }
    }

    /// 有字就存；一個字都沒出來就回到上一次的結果，不要把舊稿蓋掉。
    private func keepWhatWeHave() {
        if let run, !run.text.isEmpty {
            Store.saveTranscript(run, pieces: pieces)
        } else {
            run = Store.loadLastRun()
        }
    }

    // MARK: v0.23.2 錄音中 Haiku 改字

    /// 錄音中 onFinal：append 前後各取字數，把這塊（時間加上續錄位移）交給審稿器。沒有審稿器時和 v0.22 一樣。
    private func appendLive(_ new: [TimedPiece]) {
        guard let review = reviewer else {
            append(new, reached: .nan)
            return
        }
        let before = run?.text.count ?? 0
        append(new, reached: .nan)
        let after = run?.text.count ?? 0
        review.add(PartJoin.shift(new, by: continuing?.offset ?? 0), offsetBefore: before, offsetAfter: after)
    }

    /// 建這場的審稿器。course 給正式課名＝錄音中才指定的（不改稿的課名和資料夾）；nil＝照這場的課名。
    /// 條件：有課名、不是私人課程、這門課的開關開著、鑰匙圈有金鑰。金鑰這時讀一次放記憶體。
    private func startReviewer(course chosen: String?) {
        reviewer = nil
        reviewNeedsCourse = false
        let formal = chosen ?? run?.course.map(CourseSchedule.formalName)
        let deck = formal.flatMap { SlideImport.latest(course: $0) }
        sessionSlides = deck?.name
        guard let formal, !formal.isEmpty else {
            reviewOffReason = "沒有課名，點這行指定"
            reviewNeedsCourse = true
            return
        }
        guard CourseProfile.allowsUpload(course: formal) else {
            reviewOffReason = CourseSchedule.isPrivate(formal) ? "私人課程不送" : "不在設定檔的課不送"
            return
        }
        guard CourseProfile.load(course: formal, root: Store.documents).haiku else {
            reviewOffReason = "這門課的開關關著"
            return
        }
        guard let key = HaikuKey.read() else {
            reviewOffReason = "沒有金鑰"
            return
        }
        guard let current = run else { return }
        let review = LiveReviewer(
            course: formal,
            deck: deck,
            key: key,
            base: reviewBase,
            file: Store.reviewFile(of: current),
            clock: { [weak self] in self?.recordingSeconds ?? 0 },
            onEvent: { [weak self] line in self?.log(line) }
        )
        if whisperMain {
            // 主稿是 Whisper：附同一段 Apple 的字（Haiku 的時間含續錄位移，Apple 的不含）
            // v0.26.0：每批一張卡（擴寫式校正＋重點＋整理版＋頁碼），不跑挑字改字；卡片另存「… 卡片.json」，續錄讀回前幾段的卡
            let shift = continuing?.offset ?? 0
            review.configure(bigBatch: true, referenceName: "Apple", cards: true, cardsFile: Store.cardsFile(of: current),
                             savedCards: Store.loadCards(of: current)) { [weak self] start, end in
                guard let self else { return "" }
                return self.applePieces.filter { $0.end > start - shift - 1 && $0.start < end - shift + 1 }.map(\.text).joined()
            }
        } else {
            review.configure(bigBatch: liveMode != 0)
        }
        review.start()
        reviewer = review
        // 投影片檔名可能有人名，紀錄只寫頁數
        log("Haiku 錄音中改字：開（\(formal)，\(deck.map { "投影片 \($0.pages.count) 頁" } ?? "沒有投影片")，金鑰 \(HaikuKey.masked(key))）")
    }

    /// 「這場是哪門課」（正式課名；nil＝照課表）。錄音前：下一場用（標題、資料夾、Haiku 都照它）；
    /// 錄音中而且是因為沒課名才沒送：只給 Haiku 用，稿的課名和資料夾不動（錄音檔已經在原本的資料夾）。
    func assignCourse(_ formal: String?) {
        if phase == .recording {
            guard reviewer == nil, let formal else { return }
            log("錄音中指定課名：\(formal)")
            startReviewer(course: formal)
            showBanner(reviewer == nil ? ReviewText.closed(reviewOffReason) : "這場的 Haiku 照「\(formal)」送")
        } else {
            chosenCourse = formal
            showBanner(formal.map { "下一場：\($0)（標題、資料夾、Haiku 都照這門課）" } ?? "下一場照課表")
        }
    }

    /// 錯誤資料的 Haiku 一行：錄音中看審稿器，之後讀這場的改字紀錄
    private var reviewSummary: String {
        if let review = reviewer {
            var line = review.log.summaryLine
            if let stop = review.stop {
                line += "；已停：" + stop.short
            }
            return line
        }
        if let current = run, let saved = Store.loadReview(of: current) {
            return saved.summaryLine
        }
        return "Haiku：這場沒有送（\(reviewOffReason)）"
    }

    /// 錄音畫面標題下那一行
    var reviewStatusLine: String {
        ReviewText.slides(reviewer?.deckName ?? sessionSlides) + "　" + (reviewer?.statusLine ?? ReviewText.closed(reviewOffReason))
            + (reviewer?.lastPage.map { "　投影片 p.\($0)" } ?? "")
            + (liveWhisper.map { "　" + $0.note } ?? "")
    }

    private func beginReviewBackground() {
        endReviewBackground()
        reviewBackground = UIApplication.shared.beginBackgroundTask(withName: "Haiku 補送") { [weak self] in
            MainActor.assumeIsolated {
                self?.endReviewBackground()
            }
        }
    }

    private func endReviewBackground() {
        guard reviewBackground != .invalid else { return }
        UIApplication.shared.endBackgroundTask(reviewBackground)
        reviewBackground = .invalid
    }

    /// 補送結束後：定稿完整就補定稿命中（規格 A③），改字紀錄寫到最後那場（即時那場錄音中已經每批寫過）。
    /// 定稿沒跑完退回即時稿時，最後那場就是即時那場，紀錄照樣留著。
    /// v0.26.0 模式 1：逐字稿換成各卡的擴寫接起來（原字照舊在「… 原文.txt」＝raw.txt），回傳換過的那場（自動上傳用）。
    @discardableResult
    private func finishReview(_ review: LiveReviewer, unsent: Int, finalRun: SavedRun?, finalPieces: [TimedPiece], finalDone: Bool,
                              head: String = "") async -> SavedRun? {
        if finalDone, !finalPieces.isEmpty {
            await review.annotateFinal(text: TextCleanup.fix(finalPieces.map(\.text).joined()), pieces: finalPieces)
        }
        await review.waitForSaves()
        let data = review.log
        if let finalRun {
            await Task.detached { Store.saveReview(data, of: finalRun) }.value
        }
        var swapped: SavedRun?
        if review.cardMode, let finalRun {
            let cards = review.cards
            let body = review.cardTranscript()
            let newText = head + body
            if !body.isEmpty {
                if run?.startedStamp == finalRun.startedStamp {
                    run?.text = newText
                    swapped = run
                } else {
                    // 已經開始下一場：只改存檔，不動畫面
                    var other = finalRun
                    other.text = newText
                    swapped = other
                }
            }
            let target = swapped
            await Task.detached {
                Store.saveCards(cards, of: finalRun)
                if let target {
                    Store.saveTranscript(target, updateLast: false)
                }
            }.value
            let doneCards = cards.filter { $0.state == .done }.count
            log("即時模式 1：逐字稿換成卡片的擴寫（\(doneCards)／\(cards.count) 張整理到，\(newText.count) 字；原字在原文檔）", toRun: run?.startedStamp == finalRun.startedStamp)
        }
        review.close()
        if reviewer === review {
            reviewer = nil
        }
        endReviewBackground()
        var line = "Haiku 停止後補送完：" + data.summaryLine
        if unsent > 0 {
            line += "；未送 \(unsent) 批"
        }
        if !finalDone {
            line += "；定稿沒跑完，沒算定稿命中"
        }
        // 已經開始下一場就只記在這次開 App 的紀錄
        if let finalRun, run?.startedStamp == finalRun.startedStamp, !isBusy {
            log(line)
            if let current = run {
                Store.saveTranscript(current)
                if swapped != nil { swapped = current }
            }
        } else {
            log(line, toRun: false)
        }
        return swapped
    }

    private func append(_ new: [TimedPiece], reached: Double) {
        guard run != nil else { return }
        let shifted = PartJoin.shift(new, by: continuing?.offset ?? 0)
        pieces += shifted
        builder.add(shifted)
        run?.text = (continuing?.head ?? "") + builder.text
        if totalSeconds > 0, reached.isFinite {
            phase = .transcribing(min(1, max(0, reached / totalSeconds)))
        }
        // 長檔中途當掉也留得住已出來的字。續錄的定稿和原稿同一個檔，跑到一半不寫（即時稿已存好）。
        if Date().timeIntervalSince(lastSave) > 30, continuing == nil || finalGuard.mayUpdateLast, let run {
            lastSave = Date()
            Store.saveTranscript(run, pieces: pieces, updateLast: finalGuard.mayUpdateLast)
        }
    }

    // MARK: 蘋果 AI 分段

    func arrangeWithAppleAI() {
        guard !isBusy, let source = run, !source.text.isEmpty else { return }
        sessionLog = source.log ?? []
        phase = .transcribing(0)
        job = Task {
            let started = Date()
            UIApplication.shared.isIdleTimerDisabled = true
            let outcome = await AppleAI.paragraphs(of: source.text) { [weak self] fraction in
                self?.phase = .transcribing(fraction)
            }
            UIApplication.shared.isIdleTimerDisabled = false
            run?.text = outcome.text
            var note = String(
                format: "蘋果 AI 分段：成功 %d 塊、改了字退回 %d 塊、失敗 %d 塊，%.0f 秒",
                outcome.succeeded, outcome.changedWords, outcome.failed, Date().timeIntervalSince(started)
            )
            if let error = outcome.firstError {
                note += "；\(error)"
            }
            arrangeNote = note
            log(note)
            keepWhatWeHave()
            phase = .idle
        }
    }

    // MARK: 收起

    /// 收起這一場、回開始畫面。不刪任何檔，只是下次開 App 不再自動打開它。
    func closeRun() {
        guard !isBusy else { return }
        player.unload()
        anchor = nil
        playNote = nil
        run = nil
        arrangeNote = nil
        exportNote = nil
        phase = .idle
        Store.forgetLastRun()
        log("收起這一場", toRun: false)
    }

    // MARK: 標題（v0.14）

    /// 標題預設：沒有課名就用時間；標題點了可以改。清空就回到自動的名字。檔名、資料夾不變。
    func rename(_ newTitle: String) {
        guard !isBusy, run != nil else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        run?.title = trimmed.isEmpty ? nil : String(trimmed.prefix(60))
        log("改標題")
        if let run {
            Store.saveTranscript(run)
        }
    }

    // MARK: 句子、播放、標記（v0.14）

    /// 稿上每一句和它在錄音的第幾秒。字變了才重算（續錄、分段之後）。
    var map: TranscriptMap {
        guard let run else { return .empty }
        if let cache = mapCache, cache.stamp == run.startedStamp, cache.text == run.text {
            return cache.map
        }
        let built = TranscriptMap(text: run.text, pieces: Store.loadPieces(of: run))
        mapCache = (run.startedStamp, run.text, built)
        return built
    }

    private var sessionKey: String? {
        run.map { "\($0.startedStamp)|\($0.source)|\($0.course ?? "")" }
    }

    /// 這一場標記的句子（標記.json）。
    var marks: [SentenceMark] {
        _ = marksVersion
        guard let run, let key = sessionKey else { return [] }
        if let cache = marksCache, cache.key == key {
            return cache.marks
        }
        let loaded = Store.loadMarks(of: run)
        marksCache = (key, loaded)
        return loaded
    }

    /// 畫面上要上底色的句子。
    var markedSentences: Set<Int> {
        let current = map
        return Set(marks.compactMap { current.sentence(containingContent: $0.at) })
    }

    /// 正在播（或暫停在）哪一句。
    var playingSentence: Int? {
        guard player.isActive else { return nil }
        let current = map
        guard let byTime = current.sentence(atTime: player.position) else { return anchor }
        if let anchor, anchor < current.sentences.count, byTime < current.sentences.count,
           let a = current.sentences[anchor].start, let b = current.sentences[byTime].start, abs(a - b) < 0.01 {
            return anchor
        }
        return byTime
    }

    private func preparePlayer(for run: SavedRun) {
        let files = Store.playbackFiles(of: run)
        let starts = run.partStarts.map { $0.map { String(format: "%.2f", $0) }.joined(separator: ",") } ?? ""
        player.load(key: "\(run.startedStamp)|\(run.source)|\(run.course ?? "")|\(files.count)|\(starts)", files: files)
    }

    /// iPad 右欄一打開就把錄音長度讀好，播放條才有總長。
    func loadPlayback() {
        guard !isBusy, let run else { return }
        preparePlayer(for: run)
    }

    /// 點一下：從那句播；正在播（或暫停在）同一句就暫停（或接著播）。
    func tapSentence(_ index: Int) {
        guard !isBusy, let run else { return }
        let current = map
        guard index >= 0, index < current.sentences.count else { return }
        // 整場播完停在最後時，點最後一句是重播那句，不是「接著播」
        let atEnd = !player.isPlaying && player.position >= player.total - 0.2
        if player.isActive, !atEnd, playingSentence == index {
            if player.isPlaying {
                player.pause()
            } else {
                player.resume()
            }
            return
        }
        guard let start = current.sentences[index].start else {
            playNote = "這句對不到錄音的時間"
            return
        }
        preparePlayer(for: run)
        guard player.hasAudio else {
            playNote = "這場的錄音不在 App 裡（選來的檔轉完就刪了），不能播"
            return
        }
        anchor = index
        playNote = player.play(from: start) ? nil : "錄音打不開"
    }

    /// 播放條上的播放／暫停。
    func togglePlayback() {
        guard !isBusy, let run else { return }
        preparePlayer(for: run)
        guard player.hasAudio else {
            playNote = "這場的錄音不在 App 裡（選來的檔轉完就刪了），不能播"
            return
        }
        anchor = nil
        playNote = nil
        player.toggle()
    }

    func seekPlayback(to seconds: Double) {
        anchor = nil
        player.seek(to: seconds)
    }

    func stopPlayback() {
        anchor = nil
        player.stop()
    }

    /// 點兩下：標記／取消標記這一句。
    func toggleMark(_ index: Int) {
        setMarks([index], by: "點兩下")
    }

    /// Pencil 畫過的那幾句：和點兩下一樣，都已經標了就取消，否則把還沒標的標上。
    func markStroke(_ indices: [Int]) {
        setMarks(indices, by: "Pencil")
    }

    private func setMarks(_ indices: [Int], by: String) {
        guard !isBusy, let run, let key = sessionKey else { return }
        let current = map
        let targets = Set(indices.filter { $0 >= 0 && $0 < current.sentences.count && !current.sentences[$0].isDivider })
        guard !targets.isEmpty else { return }
        var list = marks
        let markedNow = Set(list.compactMap { current.sentence(containingContent: $0.at) })
        if targets.isSubset(of: markedNow) {
            list.removeAll { mark in
                guard let index = current.sentence(containingContent: mark.at) else { return false }
                return targets.contains(index)
            }
        } else {
            let text = run.text as NSString
            for index in targets.sorted() where !markedNow.contains(index) {
                let sentence = current.sentences[index]
                guard sentence.end <= text.length else { continue }
                let words = text.substring(with: NSRange(location: sentence.location, length: sentence.length))
                list.append(SentenceMark(at: sentence.content, text: String(words.prefix(300)), start: sentence.start, by: by, made: Store.timestamp()))
            }
            list.sort { $0.at < $1.at }
        }
        marksCache = (key, list)
        Store.saveMarks(list, of: run)
        marksVersion += 1
    }

    /// 右欄點了：稿捲到那一句。
    func jumpTo(sentence index: Int) {
        let current = map
        guard index >= 0, index < current.sentences.count else { return }
        let sentence = current.sentences[index]
        jump = JumpRequest(range: NSRange(location: sentence.location, length: sentence.length))
    }

    // MARK: 複製

    /// localOnly：不經通用剪貼簿傳到其他 Apple 裝置。
    func copyText() {
        guard let run, !run.text.isEmpty else { return }
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: run.document]],
            options: [.localOnly: true]
        )
    }

    /// v0.21 錄音中複製（即時轉錄的用處就是邊錄邊拿到字）：
    /// 到目前為止的全文（續錄時含前面各段）＋灰字，格式和「複製全文」一樣，稿頭寫「錄音中，到 mm:ss」。
    /// 錄音不停、不定稿、run 的字不動。
    func copyWhileRecording() {
        guard phase == .recording, let current = run else { return }
        let at = recordingSeconds
        if let review = reviewer, review.cardMode {
            let text = CardText.copy(review.cards)
            guard !text.isEmpty else {
                flashLiveCopy("還沒有整理好的卡")
                return
            }
            UIPasteboard.general.setItems([[UTType.plainText.identifier: text]], options: [.localOnly: true])
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            // 紀錄只寫張數和字數，不放稿的字
            log("錄音中複製卡片：到 \(formatStamp(at))，\(review.cards.filter { $0.state == .done }.count) 張，\(text.count) 字")
            flashLiveCopy("已複製到 \(formatStamp(at))")
            return
        }
        let text = LiveCopy.join(final: current.text, volatile: volatileText)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            flashLiveCopy("還沒有字可以複製")
            return
        }
        var snapshot = current
        // v0.22：複製的是改過的字，原字放在［］裡（改字和原字標在一起）；run 的字不動
        let rules = liveFixRules
        snapshot.text = LiveFix.copyText(text, rules: rules)
        // 0.23.3：複製的稿要看得出這場有沒有帶投影片：稿頭最後多一行投影片和 Haiku 狀態
        let document = LiveCopy.addHeaderLine(snapshot.liveDocument(at: at), line: reviewStatusLine.replacingOccurrences(of: "　", with: "；"))
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: document]],
            options: [.localOnly: true]
        )
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // 紀錄只寫時間和字數，不放稿的字
        log("錄音中複製：到 \(formatStamp(at))，\(text.count) 字，即時改字 \(LiveFix.count(text, rules: rules)) 處")
        flashLiveCopy("已複製到 \(formatStamp(at))")
    }

    /// v0.22：點綠底字後按「這場不再改這個詞」。
    func turnOffLiveFix(_ wrong: String) {
        liveFixOff.insert(wrong)
        // v0.23.2：同時記進改字紀錄（userOff，續錄讀得回）；紀錄不寫是哪個詞（那是稿的字）
        reviewer?.userTurnedOff(wrong)
        log("這場不再自動改一個詞（這場共 \(liveFixOff.count) 個）")
    }

    private func flashLiveCopy(_ note: String) {
        liveCopyNote = note
        liveCopyTask?.cancel()
        liveCopyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.liveCopyNote = nil
        }
    }

    // MARK: 匯出

    /// v0.21「存成原始轉錄」分享出去的檔名（選單上顯示）
    var rawRecordName: String? {
        guard let run, !run.text.isEmpty else { return nil }
        return ClassRecord.rawFileName(stamp: run.exportStamp, course: run.course)
    }

    /// 匯出（含錄音）多大；nil 表示這場在 App 裡沒有錄音檔（選來的原檔轉完就刪了）。
    var audioSizeMB: Int? {
        guard let run else { return nil }
        let files = Store.audioFiles(of: run)
        return files.isEmpty ? nil : Store.megabytes(of: files)
    }

    /// 長按黑色鈕的選項；閃退那行的「傳錯誤資料」走 errorsOnly。打包好就跳系統分享畫面。
    func export(_ kind: Store.ExportKind) {
        guard !exporting else { return }
        if kind == .classRecord, run?.text.isEmpty != false {
            exportNote = "沒有稿可以存成原始轉錄"
            return
        }
        exporting = true
        exportNote = kind == .withAudio ? "打包中（含錄音，可能要幾秒）…" : "打包中…"
        let report = errorReport()
        let current = run
        let stamp = current?.exportStamp ?? Store.timestamp()
        // 原始轉錄區塊的引擎欄：裝置＋App 版本（例：iPhone 轉文字 0.21.24）
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let engine = "\(device) 轉文字 \(AppInfo.shortVersion)"
        Task {
            do {
                let url = try await Task.detached {
                    try Store.makeExport(kind, run: current, report: report, stamp: stamp, engine: engine)
                }.value
                exportNote = nil
                share = ShareFile(url: url)
            } catch {
                exportNote = "匯出失敗：\(error.localizedDescription)"
                log("匯出失敗：\(error.localizedDescription)", toRun: false)
            }
            exporting = false
        }
    }

    /// 錯誤資料：版本、裝置、閃退停在哪、這場的失敗訊息和各步耗時。不含稿的字和聲音，選來的檔只寫副檔名（檔名可能有人名）。
    func errorReport() -> String {
        let fixName = ["關閉", "離線", "智慧"][min(max(fixMode, 0), 2)]
        var lines = [
            "轉文字 錯誤資料（不含稿和錄音）",
            "產生時間：\(Store.timestamp())",
            "App：轉文字 \(AppInfo.version)",
            "裝置：\(AppInfo.deviceModel)（\(UIDevice.current.model)，記憶體 \(AppInfo.memoryGB)）",
            "iOS：\(UIDevice.current.systemVersion)",
            "語音引擎：\(warmNote)",
            appleAIStatus,
            "情境：\(speakerModeLabel)；校正：\(fixName)",
            // v0.23.1：只寫有沒有金鑰（末 4 碼），不寫金鑰本身
            "Haiku：金鑰\(haikuKeyLabel.map { "已設定（\($0)）" } ?? "未設定")",
            // v0.23.2：這場的 Haiku 摘要（批數、通過、擋下、費用、最後錯誤；不含稿的字、不含金鑰）
            reviewSummary,
            // v0.23.2：自動上傳的開關、上次結果（不含權杖、不含稿的字）
            drive.reportLine,
            // v0.23.5：下課 Whisper 開關、待轉幾場
            whisper.reportLine,
            "",
            "閃退：" + (crashStep.map { "上次停在「\($0)」" } ?? "這次打開 App 時沒有發現上次閃退"),
        ]
        if case .failed(let message) = phase {
            lines.append("畫面上的錯誤：\(message)")
        }
        if let liveError {
            lines.append("錄音中語音引擎的錯誤：\(liveError)")
        }
        var logged: [String] = []
        if let run {
            let kind = run.origin != nil ? "電腦傳來的稿（連電腦）"
                : Store.audioFiles(of: run).isEmpty && run.recordedStamp == nil
                ? "選來的檔（.\((run.source as NSString).pathExtension)）"
                : "App 錄音"
            let builtWith = run.appVersion ?? "v0.12 以前（沒有記）"
            let audio = run.audioSeconds.map(formatClock) ?? "?"
            let convert = run.convertSeconds.map { String(format: "%.1f 秒", $0) } ?? "?"
            let done = run.finished ? "有轉完" : "沒有轉完"
            let speakerCount = run.speakers?.count ?? 0
            lines += [
                "",
                "這一場：\(run.startedStamp)，\(kind)，共 \(run.parts?.count ?? 1) 段",
                "轉這場的 App：\(builtWith)；當時 iOS \(run.systemVersion)；\(run.engine) \(run.language)",
                "音檔 \(audio)；轉換 \(convert)；\(done)；講者 \(speakerCount) 人",
            ]
            if let info = run.liveInfo { lines.append("錄音：\(info)") }
            if let info = run.speakerInfo { lines.append(info) }
            logged = run.log ?? []
            lines += ["", "這一場的各步紀錄："]
            lines += logged.isEmpty ? ["（v0.12 以前的稿沒有紀錄）"] : logged
        } else {
            lines += ["", "現在沒有打開的稿"]
        }
        // v0.23.5：這場的下課 Whisper 紀錄（另存在「… Whisper紀錄.json」，App 重開、已換到別場轉的也在）
        var whisperLines: [String] = []
        if let run, let record = Store.loadWhisperRecord(of: run) {
            whisperLines = record.log
            lines += [""] + record.reportLines
        }
        let extra = launchLog.filter { !logged.contains($0) && !whisperLines.contains($0) }
        if !extra.isEmpty {
            lines += ["", "這次打開 App 以後的其他紀錄："] + extra
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: 模擬器截圖用假資料（Release 沒有這段）

    #if DEBUG
    private func applyDemo() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.first(where: { $0.hasPrefix("-demo-") }) else { return false }
        let sample = SavedRun(
            source: "示範錄音.m4a",
            startedStamp: "20261107-110000",
            engine: SpeechEngine.name,
            language: "zh_TW",
            systemVersion: "27.3",
            audioSeconds: 3_000,
            convertSeconds: 62.4,
            finished: true,
            text: "假資料，只用來看畫面。\n今天我們接著講向量空間，\n先看基底怎麼來。\n"
        )
        switch flag {
        case "-demo-recording": phase = .recording
        case "-demo-download": phase = .downloading(0.42)
        case "-demo-transcribing": run = sample; phase = .transcribing(0.37)
        case "-demo-done": run = sample
        case "-demo-failed": phase = .failed("沒有 zh-TW，沒有改用其他中文。這台的中文語言：zh_CN、zh_HK")
        default: break
        }
        return true
    }
    #endif
}
