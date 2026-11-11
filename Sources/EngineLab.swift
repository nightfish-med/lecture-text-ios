import AVFoundation
import Foundation
import Observation
import Speech
import UIKit
import WhisperKit

// v0.23.4 實驗模式：選一個錄音檔，依序給幾個引擎各轉一次，存成一個資料夾（檔案 App › 轉文字 › 實驗）。
// 目的：手機上也能選用 Whisper 來比較；把模擬做成一種模式，選一個語音檔就自動依序跑完。
// 三個引擎：
//  1. Apple SpeechTranscriber（App 現在用的，對照組）
//  2. Apple DictationTranscriber＋關鍵字（contextualStrings；Apple 工程師在論壇說 SpeechTranscriber 不吃關鍵字，只有這個吃）
//  3. Whisper large-v3 turbo（WhisperKit，裝置上跑；第一次從 Hugging Face 下載約 600 MB 模型）
// 錄音不上傳；Whisper 只下載模型。稿的字不送任何地方。
// v0.23.5：Apple 聽寫預設關（實測一份課堂錄音，0 或 100 個關鍵字都只出「多少？」兩字）；Whisper 提示詞改成開關、預設關
// （實測加提示詞鬼打牆約 970 字、不加約 226 字，各一次樣本）；Whisper 計時從模型載入完才算，載入另列；
// 字數不到 Apple 現用 10% 的寫「疑似失敗」。Whisper 呼叫和下課轉檔共用 WhisperRunner.swift。
// v0.23.5：多一個引擎「Whisper 切句（照電腦版，模擬邊錄邊轉）」，預設開：人聲偵測切句、每句單獨送 Whisper，
// 量錄音中邊錄邊轉會落後多少、鬼打牆多少（LiveCutRunner.swift、LiveCutPlan.swift）。原本的 Whisper 改叫「Whisper（整檔）」。

@MainActor
@Observable
final class EngineLab {
    enum Engine: String, CaseIterable, Identifiable {
        case apple, dictation, whisper, whisperLive
        var id: String { rawValue }
        var name: String {
            switch self {
            case .apple: return "Apple 現用"
            case .dictation: return "Apple 聽寫＋關鍵字"
            case .whisper: return "Whisper（整檔）"
            case .whisperLive: return "Whisper 切句"
            }
        }
        var file: String {
            switch self {
            case .apple: return "1_Apple現用"
            case .dictation: return "2_Apple聽寫加關鍵字"
            case .whisper: return "3_Whisper"
            case .whisperLive: return "4_Whisper切句"
            }
        }
    }

    struct Row: Identifiable, Equatable {
        let id: Engine
        var text: String
    }

    static let whisperModel = WhisperPlan.model

    var showSheet = false
    private(set) var fileName = ""
    private(set) var fileURL: URL?
    /// 關鍵字取自哪門課（正式課名）；打開實驗畫面時換成課表上第一門（沒有設定檔就是空的）
    var course = ""
    /// v0.23.5：已知失靈（實測一份課堂錄音只出 2 字），預設關
    var useDictation = false
    var useWhisper = true
    /// v0.23.5：Whisper 切句（照電腦版，模擬邊錄邊轉），預設開
    var useWhisperLive = true
    /// v0.23.5：Whisper 加關鍵字提示詞，預設關（加了鬼打牆比較多）
    var whisperPrompt = false
    /// v0.23.5：開始／結束時通知 AppModel（實驗模式跑 Whisper 時，下課 Whisper 要讓開，兩個模型同時載入記憶體不夠）
    @ObservationIgnored var onRunning: ((Bool) -> Void)?
    private(set) var rows: [Row] = []
    private(set) var running = false
    private(set) var report: String?
    private(set) var reportURL: URL?
    private(set) var folderName: String?
    private(set) var note: String?
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var collected: [TimedPiece] = []

    /// 這門課會用到的關鍵字（畫面上先讓他看到幾個）
    var keywords: [String] {
        let pages = SlideImport.latest(course: course)?.pages ?? []
        let rights = (LiveFix.byCourse[course] ?? []).map(\.right)
        return LabKeywords.pick(pages: pages, glossaryRights: rights)
    }

    var keywordNote: String {
        let deck = SlideImport.latest(course: course)
        let list = keywords
        let head = deck.map { "投影片：\($0.name)（\($0.pages.count) 頁）" } ?? "這門課還沒有投影片"
        guard !list.isEmpty else { return head + "；沒有關鍵字，引擎 2、3 等於不加關鍵字" }
        return head + "；關鍵字 \(list.count) 個：" + list.prefix(8).joined(separator: "、") + (list.count > 8 ? "…" : "")
    }

    func picked(_ url: URL) {
        note = "複製檔案中…"
        Task {
            do {
                let copy = try await Task.detached { try Store.copyToTemporary(url) }.value
                if let old = fileURL { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
                fileURL = copy
                fileName = url.lastPathComponent
                note = nil
                report = nil
                reportURL = nil
                rows = []
            } catch {
                note = "讀不到這個檔：\(error.localizedDescription)"
            }
        }
    }

    func start() {
        guard let file = fileURL, !running else { return }
        var engines: [Engine] = [.apple]
        if useDictation { engines.append(.dictation) }
        if useWhisper { engines.append(.whisper) }
        if useWhisperLive { engines.append(.whisperLive) }
        rows = engines.map { Row(id: $0, text: "等待") }
        report = nil
        reportURL = nil
        note = nil
        running = true
        UIApplication.shared.isIdleTimerDisabled = true
        onRunning?(true)
        let course = self.course, name = fileName, words = keywords
        job = Task {
            await run(file: file, name: name, course: course, keywords: words, engines: engines)
            UIApplication.shared.isIdleTimerDisabled = false
            running = false
            onRunning?(false)
        }
    }

    func cancel() {
        job?.cancel()
        note = "已停止；已經跑完的引擎結果照樣存"
    }

    private func set(_ engine: Engine, _ text: String) {
        if let i = rows.firstIndex(where: { $0.id == engine }) { rows[i].text = text }
    }

    private func run(file: URL, name: String, course: String, keywords: [String], engines: [Engine]) async {
        var results: [LabResult] = []
        var audioSeconds = 0.0
        var readable = file
        do {
            readable = try await SpeechEngine.readableAudio(at: file)
            let f = try AVAudioFile(forReading: readable)
            audioSeconds = f.processingFormat.sampleRate > 0 ? Double(f.length) / f.processingFormat.sampleRate : 0
        } catch {
            note = "讀不出聲音：\(error.localizedDescription)"
            return
        }
        for engine in engines {
            if Task.isCancelled {
                set(engine, "沒跑（已停止）")
                continue
            }
            collected = []
            set(engine, "開始…")
            let clock = ContinuousClock()
            var started = clock.now
            var seconds: Double? { started.duration(to: clock.now).seconds }
            var loadSeconds: Double?
            var live: LiveCutSummary?
            do {
                let detail: String
                switch engine {
                case .apple:
                    let locale = try await SpeechEngine.resolveTaiwanLocale()
                    _ = try await SpeechEngine.transcribe(
                        audioURL: readable, locale: locale,
                        onStart: { _ in },
                        onDownload: { [weak self] p in self?.set(.apple, "下載語言模型 \(Int(p * 100))%") },
                        onSegment: { [weak self] pieces, reached in
                            self?.collected += pieces
                            self?.set(.apple, "轉到 \(LabReport.clock(reached))")
                        })
                    detail = "SpeechTranscriber，\(locale.identifier)，沒有關鍵字（這個引擎不吃關鍵字）"
                case .dictation:
                    let locale = try await Self.dictationLocale()
                    try await Self.dictate(audioURL: readable, locale: locale, keywords: keywords,
                                           onDownload: { [weak self] p in self?.set(.dictation, "下載語言模型 \(Int(p * 100))%") },
                                           onSegment: { [weak self] pieces, reached in
                                               self?.collected += pieces
                                               self?.set(.dictation, "轉到 \(LabReport.clock(reached))")
                                           })
                    detail = "DictationTranscriber timeIndexedLongDictation，\(locale.identifier)，contextualStrings \(keywords.count) 個"
                case .whisper:
                    // 和下課轉檔同一套（WhisperRunner）：載入模型另計，載入完才開始算轉換時間
                    let loaded = try await WhisperRunner.load { [weak self] state in
                        self?.set(.whisper, state)
                    }
                    loadSeconds = loaded.seconds
                    try Task.checkCancellation()
                    let prompt = whisperPrompt ? WhisperRunner.prompt(loaded.pipe, keywords: keywords) : nil
                    set(.whisper, "轉換中（長錄音要幾分鐘，螢幕不要關）")
                    started = clock.now
                    do {
                        try await WhisperRunner.transcribeFile(loaded.pipe, url: readable, prompt: prompt) { [weak self] pieces, reached in
                            self?.collected += pieces
                            self?.set(.whisper, "轉到 \(LabReport.clock(reached))")
                            return true
                        }
                    } catch {
                        await loaded.pipe.unloadModels()
                        throw error
                    }
                    await loaded.pipe.unloadModels()
                    collected = WhisperText.spaced(collected)
                    detail = "WhisperKit \(WhisperPlan.model)，語言 zh，每 5 分鐘一窗（切在最安靜處）、窗內 VAD 切段，"
                        + (prompt == nil ? "沒有提示詞" : "提示詞放前 60 個關鍵字") + "，簡轉繁；沒有過濾鬼打牆"
                case .whisperLive:
                    // 1. 人聲偵測（先做完、放掉偵測模型，再載 Whisper，記憶體才夠）
                    let detection = try await LiveCutRunner.detect(url: readable) { [weak self] state in
                        self?.set(.whisperLive, state)
                    }
                    try Task.checkCancellation()
                    // 2. 載入 Whisper（另計），載入完才開始算轉換時間
                    let loaded = try await WhisperRunner.load { [weak self] state in
                        self?.set(.whisperLive, state)
                    }
                    loadSeconds = loaded.seconds
                    UIDevice.current.isBatteryMonitoringEnabled = true
                    let batteryStart = Self.battery()
                    started = clock.now
                    let outcome: LiveCutRunner.Outcome
                    do {
                        outcome = try await LiveCutRunner.transcribe(loaded.pipe, url: readable, detection: detection, audioSeconds: audioSeconds) { [weak self] index, count, at in
                            self?.set(.whisperLive, "第 \(index + 1)／\(count) 句（錄音 \(LabReport.clock(at))）")
                        }
                    } catch {
                        await loaded.pipe.unloadModels()
                        UIDevice.current.isBatteryMonitoringEnabled = false
                        throw error
                    }
                    await loaded.pipe.unloadModels()
                    var summary = outcome.summary
                    summary.batteryStart = batteryStart
                    summary.batteryEnd = Self.battery()
                    UIDevice.current.isBatteryMonitoringEnabled = false
                    live = summary
                    collected = WhisperText.spaced(outcome.pieces)
                    detail = "WhisperKit \(WhisperPlan.model)，語言 zh，人聲偵測切句（照電腦版 engine.py）、每句單獨送，"
                        + "每句 token 上限 16＋每秒 15（最多 224），沒有提示詞，每句過濾鬼打牆，簡轉繁；人聲偵測：\(summary.detector)"
                        + (summary.stoppedAt.map { "；被停在第 \($0) 句" } ?? "")
                }
                let pieces = collected
                let text = TextCleanup.fix(pieces.map(\.text).joined())
                let took = seconds
                // 第一個是 Apple 現用（對照組）：別的引擎字數不到它的 10% 就寫「疑似失敗」
                let baseline = results.first.flatMap { $0.error == nil ? LabMetrics.normalize($0.text).count : nil }
                results.append(LabResult(name: engine.name, note: detail, pieces: pieces, text: text, seconds: took, error: nil, loadSeconds: loadSeconds, live: live))
                var status = LabReport.rowStatus(seconds: took ?? 0, load: loadSeconds, chars: LabMetrics.normalize(text).count, baseline: baseline)
                if let live {
                    status += "，\(live.sentences.count) 句" + (live.stoppedAt != nil ? "（已停止，只跑一部分）" : "")
                }
                set(engine, status)
            } catch {
                let message = Task.isCancelled ? "已停止" : error.localizedDescription
                results.append(LabResult(name: engine.name, note: "", pieces: [], text: "", seconds: nil, error: message))
                set(engine, "失敗：\(message)")
            }
        }
        if readable != file { try? FileManager.default.removeItem(at: readable) }
        await save(name: name, course: course, keywords: keywords, results: results, audioSeconds: audioSeconds, engines: engines)
    }

    private func save(name: String, course: String, keywords: [String], results: [LabResult], audioSeconds: Double, engines: [Engine]) async {
        note = "算比較數字中…"
        let app = AppInfo.version
        let (markdown, html) = await Task.detached {
            (LabReport.markdown(file: name, course: course, audioSeconds: audioSeconds, keywords: keywords, results: results, app: app),
             LabReport.sideBySide(file: name, results: results, audioSeconds: audioSeconds))
        }.value
        let base = (name as NSString).deletingPathExtension
        let folderTitle = Store.timestamp() + " " + CourseSchedule.folderName(base)
        let folder = Store.folder("實驗/" + folderTitle)
        try? markdown.write(to: folder.appendingPathComponent("報告.md"), atomically: true, encoding: .utf8)
        try? html.write(to: folder.appendingPathComponent("每分鐘對照.html"), atomically: true, encoding: .utf8)
        try? keywords.joined(separator: "\n").write(to: folder.appendingPathComponent("關鍵字.txt"), atomically: true, encoding: .utf8)
        for (engine, r) in zip(engines, results) where r.error == nil {
            try? r.text.write(to: folder.appendingPathComponent(engine.file + ".txt"), atomically: true, encoding: .utf8)
            if let data = try? JSONEncoder().encode(r.pieces) {
                try? data.write(to: folder.appendingPathComponent(engine.file + "_時間.json"))
            }
            // v0.23.5：切句的每句起訖、運算秒數、字數（報告的數字都能從這裡重算）
            if let live = r.live {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(live) {
                    try? data.write(to: folder.appendingPathComponent(engine.file + "_每句.json"))
                }
            }
        }
        report = markdown
        reportURL = folder.appendingPathComponent("報告.md")
        folderName = folderTitle
        note = nil
    }

    /// 電量（實驗模式切句用；isBatteryMonitoringEnabled 要先開）
    static func battery() -> String {
        let device = UIDevice.current
        let charging = device.batteryState == .charging || device.batteryState == .full
        return WhisperPlan.batteryText(level: device.batteryLevel, charging: charging)
    }

    // MARK: 引擎 2：Apple DictationTranscriber＋關鍵字

    static func dictationLocale() async throws -> Locale {
        let wanted = Locale(identifier: "zh-TW")
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: wanted), locale.region?.identifier == "TW" {
            return locale
        }
        let chinese = await DictationTranscriber.supportedLocales.map(\.identifier).filter { $0.hasPrefix("zh") }
        throw EngineError.noTaiwanChinese(available: chinese)
    }

    static func dictate(audioURL: URL, locale: Locale, keywords: [String],
                        onDownload: @escaping @MainActor (Double) -> Void,
                        onSegment: @escaping @MainActor ([TimedPiece], Double) -> Void) async throws {
        let preset = DictationTranscriber.Preset.timeIndexedLongDictation
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: preset.contentHints,
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions,
            attributeOptions: preset.attributeOptions.union([.audioTimeRange])
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await onDownload(0)
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !keywords.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: keywords]
            try await analyzer.setContext(context)
        }
        let collector = Task {
            for try await result in transcriber.results {
                await onSegment(SpeechEngine.pieces(of: result.text, fallback: result.range), result.range.end.seconds)
            }
        }
        do {
            try await withTaskCancellationHandler {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                try await collector.value
                try Task.checkCancellation()
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
    }
}

private extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
