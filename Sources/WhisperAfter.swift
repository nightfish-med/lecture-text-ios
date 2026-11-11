import Foundation
import Observation
import UIKit
import WhisperKit

// v0.23.5 下課後用 Whisper 再轉一份（星星選單開關，預設關）。
// iPad 實驗模式實測：Whisper 英文術語比 Apple 好，但會鬼打牆；而且下課常直接闔上 iPad（App 進背景）。
// 流程：按停止 → 替這場留待辦標記（「… Whisper待辦.json」）→ 定稿、Haiku 補送都跑完才開始 →
//       一段錄音每 5 分鐘一窗、每窗存進度 → 全部轉完濾鬼打牆、存「… Whisper稿.txt」「… Whisper時間.json」→ 刪標記。
// 錄音、轉文字（定稿、選檔）、實驗模式在跑時不跑；開始錄音、開始轉文字立刻暫停（標記留著）。
// App 回到前景、下次打開、停止錄音後都會接著轉。可以在背景跑一下（beginBackgroundTask），但不靠它。
// 任何失敗只寫進這場的 Whisper 紀錄（info.txt 會帶），不跳警告、不動錄音和定稿。
// 同一場失敗或轉到一半 App 在前景被關掉（多半是記憶體）算一次，滿 3 次就不再自動試，免得每次開 App 都閃退。

@MainActor
@Observable
final class WhisperAfter {
    var enabled: Bool = UserDefaults.standard.bool(forKey: "whisperAfterStop") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "whisperAfterStop")
            if enabled {
                kick("打開開關")
            } else {
                pause("關掉開關")
                refreshStatus()
            }
        }
    }
    /// 星星選單開關下面那行
    private(set) var statusLine: String?

    /// 現在能不能跑（不在錄音、不在轉文字、實驗模式沒在跑）；AppModel 設
    @ObservationIgnored var canRun: () -> Bool = { false }
    /// 每一行紀錄也交給 AppModel（錯誤資料「這次打開 App 以後的其他紀錄」）
    @ObservationIgnored var onLog: ((String) -> Void)?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var background: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var pauseReason: String?
    @ObservationIgnored private var job: WhisperJob?
    @ObservationIgnored private var marker: URL?
    @ObservationIgnored private var pipe: WhisperKit?
    @ObservationIgnored private var loadSeconds: Double?
    @ObservationIgnored private var lastMark = Date()
    /// 這一窗從頭到尾都在前景才算數：在背景時 WhisperKit 窗內出錯不會丟錯誤、只會少字，切過背景的窗丟掉重做
    @ObservationIgnored private var windowClean = true
    @ObservationIgnored private var lastResult: String?

    private enum Outcome { case done, skip, stop }

    private enum Failure: LocalizedError {
        case missingAudio(String)
        case tooFew(Int, Double)
        var errorDescription: String? {
            switch self {
            case .missingAudio(let name): return "找不到錄音檔 \(name)"
            case .tooFew(let chars, let seconds):
                return "轉完幾乎沒有字（\(chars) 字／錄音 \(formatStamp(seconds))），多半是 Whisper 中途出錯，當作失敗、下次從頭重轉"
            }
        }
    }

    /// 錯誤資料開頭一行
    var reportLine: String {
        let count = Store.whisperMarkers().count
        return "下課 Whisper：\(enabled ? "開" : "關")；待轉 \(count) 場" + (task != nil ? "；轉換中" : "")
    }

    // MARK: 排進來

    /// 按停止當下（定稿之前）就替這場留待辦：定稿跑到一半 App 被收掉也留得住。只寫標記，不開始跑。
    /// 回傳有沒有排進去（開關關著、沒有錄音、早就轉完都不排）。
    @discardableResult
    func enqueue(_ run: SavedRun?) -> Bool {
        guard enabled, let run, let fresh = Store.whisperJob(for: run) else { return false }
        let url = Store.whisperFile(fresh.stem, WhisperFiles.pending)
        let pending = Store.loadWhisperJob(url)
        let record = Store.loadWhisperRecord(stem: fresh.stem)
        guard let job = WhisperJob.merge(new: fresh, pending: pending, record: record) else { return false }
        // 續錄後只轉新的段：進度從已經轉好、濾過的稿開始
        if pending == nil, job.part > 0 {
            let done = Store.loadPieces(at: Store.whisperFile(job.stem, WhisperFiles.times))
            Store.savePieces(done, to: Store.whisperFile(job.stem, WhisperFiles.progress))
        }
        Store.saveWhisperJob(job, to: url)
        note("排進待轉：\(job.title)，共 \(job.parts.count) 段" + (job.part > 0 ? "，從第 \(job.part + 1) 段起" : ""), stem: job.stem)
        refreshStatus()
        return true
    }

    /// 定稿是另一場（新的開始時間、檔名不同）：待辦和紀錄跟著搬到定稿那場，匯出定稿才帶得到。
    /// 只搬同一個錄音檔的（定稿失敗退回上一場時不搬）。
    func move(from old: SavedRun?, to new: SavedRun?) {
        guard let old, let new, old.source == new.source, old.startedStamp != new.startedStamp else { return }
        let oldStem = Store.whisperStem(of: old)
        let newStem = Store.whisperStem(of: new)
        let oldURL = Store.whisperFile(oldStem, WhisperFiles.pending)
        guard oldStem != newStem, var moved = Store.loadWhisperJob(oldURL), marker != oldURL else { return }
        moved.stem = newStem
        moved.title = new.displayTitle
        Store.saveWhisperJob(moved, to: Store.whisperFile(newStem, WhisperFiles.pending))
        try? FileManager.default.removeItem(at: oldURL)
        let manager = FileManager.default
        for suffix in [WhisperFiles.record, WhisperFiles.progress] {
            let from = Store.whisperFile(oldStem, suffix)
            let to = Store.whisperFile(newStem, suffix)
            guard manager.fileExists(atPath: from.path) else { continue }
            try? manager.removeItem(at: to)
            try? manager.moveItem(at: from, to: to)
        }
    }

    // MARK: 開始、暫停

    /// 有待辦、開關開著、現在能跑就開始；不能跑就一分鐘後再看一次。
    func kick(_ reason: String) {
        guard enabled, task == nil else { return }
        // 只在前景開始（背景出錯只會少字、不會報錯）；回到前景會再叫
        guard UIApplication.shared.applicationState != .background else { return }
        guard !Store.whisperMarkers().isEmpty else {
            refreshStatus()
            return
        }
        guard canRun() else {
            scheduleRetry()
            refreshStatus()
            return
        }
        pauseReason = nil
        task = Task { [weak self] in
            await self?.runQueue()
        }
    }

    /// 開始錄音、開始轉文字、實驗模式、背景時間用完：停下來，標記留著，之後接著轉。
    func pause(_ reason: String) {
        guard let task else { return }
        pauseReason = reason
        task.cancel()
    }

    /// App 切到背景：記一行；這之後 App 被系統收掉不算失敗次數
    func enteredBackground() {
        guard task != nil, var current = job else { return }
        windowClean = false
        current.running = false
        job = current
        saveJob()
        note("切到背景：這一窗轉完不算（背景出錯只會少字），回到前景重做這一窗")
    }

    private func scheduleRetry() {
        guard retry == nil else { return }
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self else { return }
            self.retry = nil
            self.kick("一分鐘後再看")
        }
    }

    // MARK: 跑

    private func runQueue() async {
        beginBackground()
        // 轉換中螢幕不自動鎖（和實驗模式、定稿一樣），一次轉完；按電源鍵或闔上還是會暫停
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        let sampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                self?.sample()
            }
        }
        var skipped: Set<URL> = []
        queue: while enabled, !Task.isCancelled, canRun() {
            guard let next = Store.whisperMarkers().first(where: { !skipped.contains($0) }) else { break queue }
            let outcome = await process(next)
            switch outcome {
            case .done: break
            case .skip: skipped.insert(next)
            case .stop: break queue
            }
        }
        sampler.cancel()
        if let loaded = pipe {
            await loaded.unloadModels()
        }
        pipe = nil
        job = nil
        marker = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
        // 被開始錄音、定稿叫停時不還原：那邊自己設了不鎖，這裡改回去會讓錄音中螢幕自動鎖
        if canRun() { UIApplication.shared.isIdleTimerDisabled = false }
        endBackground()
        task = nil
        refreshStatus()
    }

    private func process(_ url: URL) async -> Outcome {
        guard var current = Store.loadWhisperJob(url) else {
            try? FileManager.default.removeItem(at: url)
            return .skip
        }
        marker = url
        if current.running {
            current.attempts += 1
            note("上次轉到一半 App 在前景被關掉（多半是記憶體不夠），算第 \(current.attempts) 次", stem: current.stem)
        }
        if current.attempts >= WhisperPlan.maxAttempts {
            giveUp(current, url, "試了 \(current.attempts) 次都沒轉完，不再自動試")
            return .skip
        }
        current.running = UIApplication.shared.applicationState != .background
        job = current
        saveJob()
        let place = UIApplication.shared.applicationState == .active ? "前景" : "背景"
        let resume = current.part > 0 || current.at > 0 ? "，從\(current.progressLine)接著轉" : ""
        note("開始（\(place)，\(Store.timestamp())）：\(current.title)，共 \(current.parts.count) 段\(resume)；\(conditions)")
        do {
            let loaded = try await loadedPipe()
            while let now = job, now.part < now.parts.count {
                let name = now.parts[now.part]
                let audio = Store.documents.appendingPathComponent(now.audioFolder + "/" + name)
                guard FileManager.default.fileExists(atPath: audio.path) else { throw Failure.missingAudio(name) }
                let readable = try await SpeechEngine.readableAudio(at: audio)
                defer {
                    if readable != audio { try? FileManager.default.removeItem(at: readable) }
                }
                let length = try WhisperRunner.duration(of: readable)
                let offset = now.offset(of: now.part)
                statusLine = "轉換中：\(now.title) \(now.progressLine)／\(formatStamp(length))"
                lastMark = Date()
                windowClean = UIApplication.shared.applicationState == .active
                try await WhisperRunner.transcribeFile(loaded, url: readable, from: now.at, prompt: nil) { [weak self] pieces, reached in
                    self?.saveWindow(pieces, offset: offset, reached: reached, length: length) ?? false
                }
                if var next = job {
                    next.part += 1
                    next.at = 0
                    next.doneAudio += length
                    job = next
                    saveJob()
                }
            }
            try finish(url)
            return .done
        } catch {
            let stopped = error is CancellationError || Task.isCancelled
            let inBackground = UIApplication.shared.applicationState != .active
            guard var failed = job else { return .stop }
            failed.running = false
            if stopped {
                job = failed
                saveJob()
                note("暫停（\(pauseReason ?? "被取消")），停在\(failed.progressLine)；之後接著轉")
                return .stop
            }
            if inBackground {
                job = failed
                saveJob()
                note("在背景出錯，當作暫停、不算次數：\(error.localizedDescription)")
                return .stop
            }
            failed.attempts += 1
            job = failed
            saveJob()
            note("失敗（第 \(failed.attempts) 次）：\(error.localizedDescription)")
            lastResult = "上次失敗：\(error.localizedDescription)"
            if failed.attempts >= WhisperPlan.maxAttempts {
                giveUp(failed, url, "失敗 \(failed.attempts) 次，不再自動試")
            }
            return .skip
        }
    }

    private func loadedPipe() async throws -> WhisperKit {
        if let pipe { return pipe }
        statusLine = "載入模型…"
        let loaded = try await WhisperRunner.load { [weak self] text in
            self?.statusLine = text
        }
        pipe = loaded.pipe
        loadSeconds = loaded.seconds
        note("載入模型 \(Int(loaded.seconds.rounded())) 秒（\(loaded.cached ? "用已下載的模型" : "含下載")）")
        return loaded.pipe
    }

    /// 每轉完一窗：小段（加上這段在整場的位置）接進進度檔、記轉到哪裡和花了多久
    /// 回傳 false：這一窗中途切過背景，不存、停下來（回到前景重做這一窗）
    private func saveWindow(_ pieces: [TimedPiece], offset: Double, reached: Double, length: Double) -> Bool {
        guard var current = job else { return false }
        guard windowClean else {
            pauseReason = "這一窗中途切過背景，不算，回到前景重做"
            return false
        }
        let shifted = pieces.map { TimedPiece(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
        let progressURL = Store.whisperFile(current.stem, WhisperFiles.progress)
        Store.savePieces(Store.loadPieces(at: progressURL) + shifted, to: progressURL)
        let now = Date()
        current.spent += now.timeIntervalSince(lastMark)
        lastMark = now
        current.at = reached
        current.running = UIApplication.shared.applicationState != .background
        job = current
        saveJob()
        statusLine = "轉換中：\(current.title) \(current.progressLine)／\(formatStamp(length))"
        windowClean = UIApplication.shared.applicationState == .active
        return true
    }

    /// 全部段轉完：濾鬼打牆、存稿和時間、寫紀錄、刪標記和進度檔
    private func finish(_ url: URL) throws {
        guard let done = job else { return }
        let progressURL = Store.whisperFile(done.stem, WhisperFiles.progress)
        let raw = Store.loadPieces(at: progressURL)
        let filtered = WhisperClean.clean(raw)
        let pieces = WhisperText.spaced(filtered.pieces)
        // 幾乎沒有字：不寫「完成」，進度清掉、下次從頭重轉（算一次失敗）
        let chars = pieces.reduce(0) { total, piece in total + piece.text.filter { c in !c.isWhitespace }.count }
        if WhisperPlan.tooFew(chars: chars, audioSeconds: done.doneAudio) {
            var restart = done
            restart.part = 0
            restart.at = 0
            restart.doneAudio = 0
            restart.spent = 0
            restart.priorRuns = 0
            restart.priorRemoved = 0
            restart.priorLoops = 0
            restart.priorHallucinations = 0
            restart.priorSeconds = 0
            job = restart
            saveJob()
            try? FileManager.default.removeItem(at: progressURL)
            throw Failure.tooFew(chars, done.doneAudio)
        }
        var record = Store.loadWhisperRecord(stem: done.stem) ?? WhisperRecord()
        record.model = WhisperPlan.model
        record.prompt = false
        record.parts = done.parts
        record.audioSeconds = done.doneAudio
        record.seconds = done.priorSeconds + done.spent
        record.loadSeconds = loadSeconds
        record.runs = done.priorRuns + filtered.runs
        record.removed = done.priorRemoved + filtered.removed
        record.loops = done.priorLoops + filtered.loops
        record.hallucinations = done.priorHallucinations + filtered.hallucinations
        let finished = Store.timestamp()
        record.result = "完成（\(finished)）"
        Store.saveWhisperRecord(record, stem: done.stem)
        let text = WhisperText.header(title: done.title, record: record, app: AppInfo.version, finished: finished)
            + WhisperText.body(pieces, partStarts: done.partStarts ?? [0])
        try? text.write(to: Store.whisperFile(done.stem, WhisperFiles.text), atomically: true, encoding: .utf8)
        Store.savePieces(pieces, to: Store.whisperFile(done.stem, WhisperFiles.times))
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: progressURL)
        // 整段判成迴圈、幻覺句：每處記一行（時間和字數，不寫稿的字），最多 30 行
        for event in filtered.events.prefix(30) {
            note(event.line)
        }
        if filtered.events.count > 30 {
            note("還有 \(filtered.events.count - 30) 處沒列")
        }
        let speed = WhisperPlan.speed(audio: record.audioSeconds, took: record.seconds)
        let place = UIApplication.shared.applicationState == .active ? "結束時在前景" : "結束時在背景"
        note("完成（\(finished)）：錄音 \(formatStamp(record.audioSeconds))，轉換 \(Int(record.seconds.rounded())) 秒（\(speed)），\(place)；這次壓縮重複 \(filtered.runs) 處、少 \(filtered.removed) 字，整段迴圈 \(filtered.loops) 段，幻覺句 \(filtered.hallucinations) 段；\(conditions)")
        lastResult = "上次：\(done.title) 完成（\(formatStamp(record.audioSeconds)) 錄音轉 \(Int(record.seconds)) 秒）"
        job = nil
        marker = nil
    }

    private func giveUp(_ failed: WhisperJob, _ url: URL, _ why: String) {
        var record = Store.loadWhisperRecord(stem: failed.stem) ?? WhisperRecord()
        record.result = "放棄：\(why)"
        Store.saveWhisperRecord(record, stem: failed.stem)
        note("放棄：\(why)；已轉的部分丟掉（錄音和定稿都沒動）", stem: failed.stem)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: Store.whisperFile(failed.stem, WhisperFiles.progress))
        lastResult = "上次放棄：\(failed.title)"
        job = nil
        marker = nil
    }

    // MARK: 紀錄

    private var conditions: String {
        let device = UIDevice.current
        let charging = device.batteryState == .charging || device.batteryState == .full
        return "熱：\(WhisperPlan.thermalName(ProcessInfo.processInfo.thermalState))，\(WhisperPlan.batteryText(level: device.batteryLevel, charging: charging))"
    }

    /// 每分鐘一次：熱和電量
    private func sample() {
        guard job != nil else { return }
        note("每分鐘：\(conditions)")
    }

    private func saveJob() {
        guard let job, let marker else { return }
        Store.saveWhisperJob(job, to: marker)
    }

    /// 寫進這場的 Whisper 紀錄（info.txt 會帶），也交給 AppModel。不含稿的字。
    private func note(_ line: String, stem: String? = nil) {
        let entry = "\(Store.clock()) Whisper：\(line)"
        if let target = stem ?? job?.stem {
            var record = Store.loadWhisperRecord(stem: target) ?? WhisperRecord()
            record.log.append(entry)
            if record.log.count > 400 {
                record.log.removeFirst(record.log.count - 400)
            }
            Store.saveWhisperRecord(record, stem: target)
        }
        onLog?(entry)
    }

    func refreshStatus() {
        if task != nil, let current = job {
            statusLine = "轉換中：\(current.title) \(current.progressLine)"
            return
        }
        let count = Store.whisperMarkers().count
        if !enabled {
            statusLine = count > 0 ? "關著；有 \(count) 場還沒轉" : nil
        } else if count > 0 {
            statusLine = "待轉 \(count) 場（不在錄音、轉文字時自動開始）"
        } else {
            statusLine = lastResult
        }
    }

    // MARK: 背景時間

    private func beginBackground() {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "Whisper 下課轉檔") { [weak self] in
            MainActor.assumeIsolated {
                self?.pause("背景時間用完")
                self?.endBackground()
            }
        }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }
}
