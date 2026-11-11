import AVFoundation
import Foundation
import Speech

enum RecorderError: LocalizedError {
    case microphoneDenied
    case couldNotStart
    case noAudioFormat

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "沒有麥克風權限。到「設定 > 隱私權與安全性 > 麥克風」打開。"
        case .couldNotStart:
            return "錄音開不起來。"
        case .noAudioFormat:
            return "語音引擎沒有給可用的聲音格式。"
        }
    }
}

/// 麥克風的聲音同時送兩邊：存成檔案、餵給語音引擎，所以邊講邊出字，錄音也留著。
/// 檔案是 16 kHz 單聲道 16 位元 PCM 的 .caf，一小時約 115 MB。
/// 不用 m4a：m4a 要正常結束才寫得完索引，App 中途被殺整段可能開不了。
/// 開 UIBackgroundModes audio，鎖屏繼續錄。
/// 這個類別刻意不放 MainActor：麥克風的回呼不在主執行緒。
final class AudioPump: @unchecked Sendable {
    private final class OneShot: @unchecked Sendable {
        var given = false
    }

    private let engine = AVAudioEngine()
    private let fileFormat: AVAudioFormat
    private let analyzerFormat: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var toFile: AVAudioConverter?
    private var toAnalyzer: AVAudioConverter?
    private var framesWritten: AVAudioFramePosition = 0
    private var observers: [NSObjectProtocol] = []
    /// v0.20：打斷、換麥克風、接回來成不成，都講一聲（寫進這場的紀錄）。在主執行緒叫。
    private let onEvent: (String) -> Void
    /// v0.20：寫檔第一次失敗的原因（例如空間滿）；以前吞掉不講。
    private var writeError: String?

    var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(framesWritten) / fileFormat.sampleRate
    }

    init(
        saveTo url: URL,
        analyzerFormat: AVAudioFormat,
        input: AsyncStream<AnalyzerInput>.Continuation,
        onEvent: @escaping (String) -> Void
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            throw RecorderError.couldNotStart
        }
        self.fileFormat = format
        self.analyzerFormat = analyzerFormat
        self.input = input
        self.onEvent = onEvent
        self.file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
    }

    func start() throws {
        try installTap()
        engine.prepare()
        try engine.start()

        let center = NotificationCenter.default
        // 來電、Siri、鬧鐘、別的 App 要用聲音：iOS 先關掉我們的麥克風（began），用完才可能通知（ended）。
        // v0.20 以前只聽 ended、不記一筆；沒等到 ended（常見：別的 App 一直佔著）就一直停著，畫面照樣顯示錄音中。
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let kind = AVAudioSession.InterruptionType(rawValue: raw) else {
                return
            }
            if kind == .began {
                self.onEvent("錄音被打斷：\(Self.interruptionReason(note.userInfo))")
                return
            }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let mayResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            self.onEvent("打斷結束（系統\(mayResume ? "說可以接著錄" : "沒說可以接著錄，照樣試")）；\(self.recover())")
        })
        // 插拔耳機、連上或斷開藍牙：記是哪一種、現在用哪個麥克風（只記種類，不記裝置名稱：名稱常有人名）。
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
            // 類別改變是自己設的（開始錄音、連電腦念回覆），不記
            guard reason != .categoryChange else { return }
            self.onEvent("聲音路線換了：\(Self.routeReason(reason))；現在用\(Self.currentInput())")
        })
        // 麥克風格式可能變，要重接。
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onEvent("音訊設定變了，重接麥克風；\(self.recover())")
        })
        // 系統的聲音服務整個重開（少見）：類別要重設。
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            try? AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
            self.onEvent("系統聲音服務重開了；\(self.recover())")
        })
    }

    var isRunning: Bool { engine.isRunning }

    /// 把麥克風接回來，回傳一句結果（寫進紀錄）。v0.20：以前 try? 吞掉，接不回來也不知道。
    /// 被打斷、看門狗發現停了、回到前景都會叫。
    @discardableResult
    func recover() -> String {
        if engine.isRunning {
            return "麥克風還在收"
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            return "接不回來（聲音被別的 App 或系統佔著）：\(error.localizedDescription)"
        }
        engine.inputNode.removeTap(onBus: 0)
        do {
            try installTap()
            engine.prepare()
            try engine.start()
            return "已接回麥克風（\(Self.currentInput())）"
        } catch {
            return "接不回來：\(error.localizedDescription)"
        }
    }

    /// 寫檔第一次失敗的原因，讀了就清掉。
    func takeWriteError() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let error = writeError
        writeError = nil
        return error
    }

    private static func interruptionReason(_ info: [AnyHashable: Any]?) -> String {
        guard let raw = info?[AVAudioSessionInterruptionReasonKey] as? UInt,
              let reason = AVAudioSession.InterruptionReason(rawValue: raw) else {
            return "來電、Siri、鬧鐘或別的 App 要用聲音"
        }
        switch reason {
        case .default:
            return "來電、Siri、鬧鐘或別的 App 要用聲音"
        case .builtInMicMuted:
            return "內建麥克風被關掉（例如 iPad 闔上保護蓋）"
        default:
            return "系統原因代碼 \(raw)"
        }
    }

    private static func routeReason(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: return "接上新的耳機或麥克風"
        case .oldDeviceUnavailable: return "原本的耳機或麥克風不見了（拔掉、藍牙斷了）"
        case .override: return "被改用別的路線"
        case .wakeFromSleep: return "裝置醒來"
        case .noSuitableRouteForCategory: return "找不到能錄音的麥克風"
        case .routeConfigurationChange: return "路線設定變了"
        default: return "原因不明（代碼 \(reason.rawValue)）"
        }
    }

    private static func currentInput() -> String {
        guard let port = AVAudioSession.sharedInstance().currentRoute.inputs.first else {
            return "沒有麥克風"
        }
        switch port.portType {
        case .builtInMic: return "內建麥克風"
        case .headsetMic: return "有線耳機的麥克風"
        case .bluetoothHFP: return "藍牙耳機的麥克風"
        case .usbAudio: return "USB 麥克風"
        case .carAudio: return "車上的麥克風"
        default: return "麥克風（\(port.portType.rawValue)）"
        }
    }

    private func installTap() throws {
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let fileConverter = AVAudioConverter(from: format, to: fileFormat),
              let analyzerConverter = AVAudioConverter(from: format, to: analyzerFormat) else {
            throw RecorderError.couldNotStart
        }
        lock.lock()
        toFile = fileConverter
        toAnalyzer = analyzerConverter
        lock.unlock()
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, let toFile, let toAnalyzer else { return }
        if let converted = convert(buffer, with: toFile, to: fileFormat) {
            do {
                try file.write(from: converted)
                framesWritten += AVAudioFramePosition(converted.frameLength)
            } catch {
                // 寫檔失敗（例如空間滿）也不要停掉字幕；v0.20 起記第一次的原因
                if writeError == nil {
                    writeError = error.localizedDescription
                }
            }
        }
        if let converted = convert(buffer, with: toAnalyzer, to: analyzerFormat) {
            input.yield(AnalyzerInput(buffer: converted))
        }
    }

    private func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        let once = OneShot()
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, inputStatus in
            if once.given {
                inputStatus.pointee = .noDataNow
                return nil
            }
            once.given = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, failure == nil, output.frameLength > 0 else {
            return nil
        }
        return output
    }

    /// 收麥克風、關檔、告訴語音引擎聲音結束了。
    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        file = nil
        toFile = nil
        toAnalyzer = nil
        lock.unlock()
        input.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// 一次邊講邊出字的錄音。
/// 起因：v0.2–v0.4 沒開 fastResults，真機錄 7 秒畫面還是空的、字約 10 秒一批，不像即時。
/// 所以開 fastResults 求快（文件寫較不準），按停止後再用存下的錄音轉一次定稿。
@MainActor
final class LiveSession {
    private let analyzer: SpeechAnalyzer
    private let pump: AudioPump
    private let collector: Task<Void, Never>
    private let onError: @MainActor (String) -> Void

    var seconds: Double { pump.seconds }

    /// v0.20：看門狗發現停了、回到前景時試著接回麥克風；回傳一句結果。
    func recover() -> String { pump.recover() }
    var micRunning: Bool { pump.isRunning }
    func takeWriteError() -> String? { pump.takeWriteError() }

    private init(
        analyzer: SpeechAnalyzer,
        pump: AudioPump,
        collector: Task<Void, Never>,
        onError: @escaping @MainActor (String) -> Void
    ) {
        self.analyzer = analyzer
        self.pump = pump
        self.collector = collector
        self.onError = onError
    }

    /// 開頭先預熱、好了才開放錄音：反應要快，但品質不能妥協。
    /// 開 App 就把引擎載好（prepareToAnalyze：文件寫它把第一段聲音才做的準備提前做完）。
    /// modelRetention：這次用完模型留在記憶體，下一次錄音不用重載。
    struct Warm {
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let format: AVAudioFormat
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    private static func makeAnalyzer(_ transcriber: SpeechTranscriber) -> SpeechAnalyzer {
        SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
    }

    static func warmUp(
        locale: Locale,
        onDownload: @escaping @MainActor (Double) -> Void
    ) async throws -> Warm {
        let transcriber = makeTranscriber(locale: locale)
        try await SpeechEngine.installModelIfNeeded(for: transcriber, progress: onDownload)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw RecorderError.noAudioFormat
        }
        let analyzer = makeAnalyzer(transcriber)
        try await analyzer.prepareToAnalyze(in: format)
        return Warm(transcriber: transcriber, analyzer: analyzer, format: format)
    }

    /// warm 是 nil（還沒熱好就按了）也照樣開始：聲音馬上收進檔案和佇列，一個字都不掉，只是第一個字比較晚出來。
    static func start(
        warm: Warm?,
        locale: Locale,
        saveTo url: URL,
        onDownload: @escaping @MainActor (Double) -> Void,
        onFinal: @escaping @MainActor ([TimedPiece]) -> Void,
        onVolatile: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void,
        onEvent: @escaping @MainActor (String) -> Void
    ) async throws -> LiveSession {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw RecorderError.microphoneDenied
        }
        let transcriber = warm?.transcriber ?? makeTranscriber(locale: locale)
        if warm == nil {
            try await SpeechEngine.installModelIfNeeded(for: transcriber, progress: onDownload)
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        let analyzer = warm?.analyzer ?? makeAnalyzer(transcriber)
        var chosen = warm?.format
        if chosen == nil {
            chosen = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        }
        guard let format = chosen else {
            throw RecorderError.noAudioFormat
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        // 通知都在主執行緒送（observer 的 queue 是 .main）
        let pump = try AudioPump(saveTo: url, analyzerFormat: format, input: continuation) { line in
            MainActor.assumeIsolated { onEvent(line) }
        }

        // 先開始收結果，再餵聲音。
        let collector = Task { @MainActor in
            do {
                for try await result in transcriber.results {
                    if result.isFinal {
                        onFinal(SpeechEngine.pieces(of: result.text, fallback: result.range))
                    } else {
                        onVolatile(String(result.text.characters))
                    }
                }
            } catch {
                onError(error.localizedDescription)
            }
        }
        do {
            try pump.start()        // 先收音，引擎晚一點開始也不會掉字
            try await analyzer.start(inputSequence: stream)
        } catch {
            pump.stop()
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        return LiveSession(analyzer: analyzer, pump: pump, collector: collector, onError: onError)
    }

    /// 回傳錄了幾秒。還是灰字的部分會在這裡定稿。
    func finish() async -> Double {
        let total = pump.seconds
        pump.stop()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
            onError(error.localizedDescription)
        }
        await collector.value
        return total
    }
}
