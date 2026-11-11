import AVFoundation
import CryptoKit
import Foundation
import Network
import Observation
import Security
import UIKit

// v0.15 連電腦：App 內建掃 QR 碼直接連好的原生模式。
// 手機掃電腦「連手機」的 QR 碼 → 用 QR 裡的憑證指紋釘選電腦的自簽憑證（不關掉整體安全檢查）→
// WebSocket 把麥克風聲音（16 kHz 單聲道 16 位元、每包 100 毫秒、帶序號和時間戳）送給電腦。協定：電腦版的手機收音協定（文件不在這個倉庫）。
// 手機這邊不轉文字（電腦負責）；只顯示連線狀態、音量條、傳了多久、斷過幾次。
// v0.16（協定 v3，電腦版 v5.27 起）：電腦把即時稿傳回來，畫面顯示電腦的稿（黑字定稿、灰字還可能改），錄完可以存成手機上的一場。
// 開 UIBackgroundModes audio（Info.plist 原本就有）：麥克風一直開著，鎖螢幕 App 也繼續跑、繼續傳。
// v0.17（協定 v4，電腦版 v5.29 起）：電腦把叫 Claude 的對話也傳回來（他喊的、打的、Claude 的回覆、正在想、沒回成）；
// 可選用 iOS 內建聲音（v0.18 起預設跟系統朗讀設定一樣，可在選單改）念新回覆，念的時段告訴電腦（tts 訊息），那段聲音不寫進稿、不拿來叫 Claude。
// 連不上時看網路種類（NWPathMonitor）：只有行動網路就直接說「手機現在用 4G／行動網路」。
// v0.19（協定 v5，電腦版 v5.33）：開口就停（預設開）。念的時候把這則的編號和字送電腦；電腦用它的麥克風聽到他開口就回 tts_stop，
// 手機停念。手機不另外開麥克風、不改錄音的音訊設定（不開 voice processing），送給電腦的聲音跟以前一樣。

/// 單調、不會跳、睡眠也照走的微秒時鐘（Darwin 的 CLOCK_MONOTONIC＝mach_continuous_time）。整次連線 ping 和聲音都用它。
enum LinkClock {
    static func nowUs() -> Int64 {
        Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000)
    }
}

/// 核心送給畫面的事。
enum LinkEvent {
    case opening(attempt: Int)
    case open
    /// 對時第一次回來：電腦開始收這支手機的聲音。lostSamples：這次斷線少了多少（第一次連上是 0）。
    case ready(rttMs: Int, lostSamples: Int, wasLost: Bool)
    case rtt(Int)
    case recording(Bool)
    case lost(String)
    case ended(String)
    case warn(String)
    case meter(level: Double, sentSamples: Int64)
    /// v0.16：電腦的協定版本、會不會送稿（v3 起）。
    case welcome(version: Int, text: Bool)
    /// v0.16（協定 v2）：電腦算的「這次少幾秒、這場共少幾秒」。
    case gap(lostSec: Double, totalSec: Double, message: String)
    /// v0.16（協定 v3）：電腦的即時稿。
    case text(PCText)
    /// v0.17（協定 v4）：叫 Claude 的對話。
    case chat(PCChatMessage)
    /// v0.19（協定 v5）：電腦聽到他開口，叫手機停念。
    case ttsStop(id: Int?)
}

// MARK: 網路與時間戳（自己一條序列佇列；URLSession 的回呼也排在同一條上）

final class LinkCore: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let q = DispatchQueue(label: "lecturetext.link")
    private let target: LinkTarget
    private let device: String
    private let emit: @Sendable (LinkEvent) -> Void
    private var use: LinkUse

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    /// 第幾次連線；舊連線的回呼和計時器看到號碼不同就不做事。
    private var generation = 0
    private var attempt = 0
    private var isOpen = false
    /// 這條連線對過時了（電腦對時前收到的包會丟，所以對好時才送聲音、補送斷線時留的包）。
    private var synced = false
    private var stopped = false
    private var everReady = false
    private var lostSinceReady = false
    private var recording = false
    private var lastHeardUs: Int64 = 0

    private var stamper = LinkStamper()
    private var backlog = LinkBacklog()
    private var sentSamples: Int64 = 0
    private var lastMeterUs: Int64 = 0
    private var meterPeak = 0.0

    /// 釘選失敗、被拒（403）：不要重試，請他重掃。URLSession 的驗證回呼不一定在 q 上，用鎖。
    private let flagLock = NSLock()
    private var pinFailedFlag = false

    init(target: LinkTarget, use: LinkUse, device: String, emit: @escaping @Sendable (LinkEvent) -> Void) {
        self.target = target
        self.use = use
        self.device = device
        self.emit = emit
        super.init()
    }

    // MARK: 對外（主執行緒叫）

    func start() {
        q.async { [self] in
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.underlyingQueue = q
            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = false
            config.timeoutIntervalForRequest = 30
            session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            connect()
        }
    }

    func stop(sendOff: Bool) {
        q.async { [self] in
            guard !stopped else { return }
            if sendOff, isOpen, let task {
                task.send(.string(LinkOutgoing.off.text)) { _ in }
            }
            teardown()
        }
    }

    func setUse(_ newUse: LinkUse) {
        q.async { [self] in
            use = newUse
            if isOpen {
                send(.use(newUse))
            }
        }
    }

    /// 來電、Siri 等系統打斷（協定第 4 節）：送 pause；恢復時下一批重設起點、旗標 bit0。
    func interrupted(began: Bool) {
        q.async { [self] in
            if began, isOpen {
                send(.pause(why: "interrupted"))
            }
            stamper.reset()
        }
    }

    /// 麥克風來的一批（已換成 16 kHz）。在音訊執行緒叫，馬上排到 q。
    func took(_ samples: [Int16], nowUs: Int64, latencyUs: Int64) {
        q.async { [self] in
            handle(samples, nowUs: nowUs, latencyUs: latencyUs)
        }
    }

    /// v0.17：手機在念 Claude 的回覆（協定 v4 的 tts）。斷線時送不出去就算了（電腦照估的秒數收尾）。
    /// v0.19：barge 有值＝開口就停（協定 v5）。
    func speaking(_ playing: Bool, seconds: Double?, barge: LinkBarge?) {
        q.async { [self] in
            send(.tts(playing: playing, seconds: seconds, barge: barge))
        }
    }

    // MARK: 連線

    private func connect() {
        guard !stopped, let session, let url = target.micURL(device: device) else { return }
        generation += 1
        let gen = generation
        attempt += 1
        isOpen = false
        synced = false
        flagLock.lock()
        pinFailedFlag = false
        flagLock.unlock()
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        // 原生 App 不帶 Origin（協定 2）；URLSession 本來就不加
        let next = session.webSocketTask(with: request)
        task = next
        emit(.opening(attempt: attempt))
        next.resume()
        receive(next, gen)
        // 8 秒還沒開成就當失敗，重試
        after(8, gen) { [self] in
            if !isOpen {
                lost(gen, "連不上電腦")
            }
        }
    }

    private func receive(_ socket: URLSessionWebSocketTask, _ gen: Int) {
        socket.receive { [weak self] result in
            guard let self else { return }
            self.q.async {
                guard gen == self.generation, !self.stopped else { return }
                switch result {
                case .success(let message):
                    self.lastHeardUs = LinkClock.nowUs()
                    if case .string(let text) = message {
                        self.handle(LinkIncoming.parse(text), gen)
                    }
                    if gen == self.generation, !self.stopped {
                        self.receive(socket, gen)
                    }
                case .failure:
                    self.failed(gen)
                }
            }
        }
    }

    private func handle(_ message: LinkIncoming, _ gen: Int) {
        switch message {
        case .welcome(let isRecording, let version, let sendsText):
            setRecording(isRecording)
            emit(.welcome(version: version, text: sendsText))
        case .gap(let lostSec, let totalSec, let message):
            emit(.gap(lostSec: lostSec, totalSec: totalSec, message: message))
        case .text(let message):
            emit(.text(message))
        case .chat(let message):
            emit(.chat(message))
        case .ttsStop(let id):
            emit(.ttsStop(id: id))
        case .pong(let t1, let t2):
            let t3 = LinkClock.nowUs()
            send(.sync(t1: t1, t2: t2, t3: t3))
            let rtt = Int(max(0, t3 - t1) / 1_000)
            if !synced {
                synced = true
                // 對時送出去了才補送斷線時留的包：電腦在同一條連線上照順序處理，先有時差才收得下
                for data in backlog.drain(now: t3) {
                    sendData(data)
                    sentSamples += Int64(max(0, data.count - 24) / 2)
                }
                let dropped = backlog.takeDropped()
                emit(.ready(rttMs: rtt, lostSamples: dropped, wasLost: lostSinceReady))
                lostSinceReady = false
                everReady = true
                attempt = 0
            } else {
                emit(.rtt(rtt))
            }
        case .state(let isRecording, let pcOff, let message):
            if pcOff {
                end(message ?? "電腦這邊關掉了手機收音")
                return
            }
            setRecording(isRecording)
        case .warn(let text):
            emit(.warn(text))
        case .replaced(let text):
            end(text)
        case .bye(let text):
            end(text)
        case .other:
            break
        }
    }

    private func setRecording(_ value: Bool) {
        if value != recording {
            stamper.reset()
            if !value {
                backlog.clear()
            }
        }
        recording = value
        emit(.recording(value))
    }

    private func opened(_ gen: Int) {
        guard gen == generation, !stopped else { return }
        isOpen = true
        lastHeardUs = LinkClock.nowUs()
        emit(.open)
        // 連上第一件事送 hello（重連也要再送），接著連送 5 次 ping（間隔 200 毫秒）對時
        send(.hello(use: use, device: device))
        for i in 0..<5 {
            after(Double(i) * 0.2, gen) { [self] in
                send(.ping(t1: LinkClock.nowUs()))
            }
        }
        schedulePing(gen)
        scheduleHeartbeat(gen)
    }

    /// 之後每 5 秒一次 ping（電腦 20 秒沒收到東西就當斷了）。
    private func schedulePing(_ gen: Int) {
        after(5, gen) { [self] in
            send(.ping(t1: LinkClock.nowUs()))
            schedulePing(gen)
        }
    }

    /// 走遠、Wi-Fi 斷了時 TCP 不一定馬上報錯：每 2 秒送 WebSocket 的 ping（不影響對時），6 秒沒聽到電腦任何回應就當斷了。
    private func scheduleHeartbeat(_ gen: Int) {
        after(2, gen) { [self] in
            if LinkClock.nowUs() - lastHeardUs > 6_000_000 {
                lost(gen, "電腦沒有回應")
                return
            }
            task?.sendPing { [weak self] error in
                guard let self, error == nil else { return }
                self.q.async {
                    if gen == self.generation {
                        self.lastHeardUs = LinkClock.nowUs()
                    }
                }
            }
            scheduleHeartbeat(gen)
        }
    }

    private func failed(_ gen: Int) {
        guard gen == generation, !stopped else { return }
        flagLock.lock()
        let pinFailed = pinFailedFlag
        flagLock.unlock()
        if pinFailed {
            end("電腦的憑證和 QR 碼裡的不一樣（電腦換過憑證，或連到別台）。請在電腦按「連手機」，重新掃 QR 碼")
            return
        }
        if let response = task?.response as? HTTPURLResponse, response.statusCode == 403 {
            end("配對碼失效了（電腦重開過「連手機」）。請在電腦按「連手機」，重新掃 QR 碼")
            return
        }
        lost(gen, everReady ? "連線中斷" : "連不上電腦")
    }

    private func lost(_ gen: Int, _ why: String) {
        guard gen == generation, !stopped else { return }
        generation += 1          // 舊連線的回呼、計時器都作廢
        isOpen = false
        synced = false
        if everReady {
            lostSinceReady = true
        }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        let wait = LinkRetry.delay(attempt: attempt)
        let hint = everReady ? "" : "（手機和電腦要在同一個 Wi-Fi、電腦的「連手機」要開著；第一次連要按「允許」區域網路）"
        emit(.lost("\(why)，\(Int(wait)) 秒後重連\(hint)"))
        let retryGen = generation
        after(wait, retryGen) { [self] in
            connect()
        }
    }

    private func end(_ message: String) {
        guard !stopped else { return }
        teardown()
        emit(.ended(message))
    }

    private func teardown() {
        stopped = true
        generation += 1
        isOpen = false
        synced = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()   // URLSession 抓著 delegate，不放就不會釋放
        session = nil
        backlog.clear()
    }

    private func after(_ seconds: Double, _ gen: Int, _ work: @escaping () -> Void) {
        q.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, gen == self.generation, !self.stopped else { return }
            work()
        }
    }

    private func send(_ message: LinkOutgoing) {
        guard isOpen, let task else { return }
        task.send(.string(message.text)) { _ in }
    }

    private func sendData(_ data: Data) {
        guard isOpen, let task else { return }
        task.send(.data(data)) { _ in }
    }

    // MARK: 聲音

    private func handle(_ samples: [Int16], nowUs: Int64, latencyUs: Int64) {
        guard !stopped else { return }
        // 音量條每 0.1 秒更新一次（看最大的那批），電腦沒在錄也顯示，擺位置時看得到
        meterPeak = max(meterPeak, LinkLevel.meter(samples))
        if nowUs - lastMeterUs >= 100_000 {
            emit(.meter(level: meterPeak, sentSamples: sentSamples))
            meterPeak = 0
            lastMeterUs = nowUs
        }
        // 只有電腦在錄的時候才送聲音；麥克風一直開著但不送（協定 2.1）
        guard recording else {
            stamper.reset()
            return
        }
        let frames = stamper.feed(samples, nowUs: nowUs, latencyUs: latencyUs)
        for frame in frames {
            let data = frame.data
            if isOpen, synced {
                sendData(data)
                sentSamples += Int64(frame.samples.count)
            } else {
                backlog.push(data, samples: frame.samples.count, at: nowUs)
            }
        }
    }

    // MARK: URLSession 回呼（delegateQueue 的 underlyingQueue 是 q）

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        opened(generation)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task, !stopped else { return }
        // 被取代（4002）、電腦關掉連手機（1001）通常先收到 JSON 已經結束；沒收到就當斷線，照常重連
        if closeCode == .goingAway {
            end("電腦關掉了手機連線")
            return
        }
        failed(generation)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        failed(generation)
    }

    /// 憑證釘選（協定第 1 節）：伺服器給的第一張憑證 DER 取 SHA-256，跟 QR 碼的 fp 一樣才接受；不一樣就拒絕。
    /// 沒有關掉 App 整體的安全檢查（Info.plist 沒有放行任意連線，只放行區域網路），只對這台電腦、這張憑證放行。
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        judge(challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        judge(challenge)
    }

    private func judge(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            return (.performDefaultHandling, nil)
        }
        guard space.host == target.host,
              let trust = space.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            markPinFailed()
            return (.cancelAuthenticationChallenge, nil)
        }
        let der = SecCertificateCopyData(leaf) as Data
        let hex = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        guard target.accepts(fingerprint: hex) else {
            markPinFailed()
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    private func markPinFailed() {
        flagLock.lock()
        pinFailedFlag = true
        flagLock.unlock()
    }
}

// MARK: 麥克風（AVAudioEngine 只在主執行緒動；取樣在音訊執行緒換成 16 kHz 後交給 LinkCore）

final class LinkMic: @unchecked Sendable {
    private final class OneShot: @unchecked Sendable {
        var given = false
    }

    private let engine = AVAudioEngine()
    private var observers: [NSObjectProtocol] = []
    private let outFormat: AVAudioFormat
    private let onSamples: @Sendable ([Int16], Int64, Int64) -> Void
    private let onInterrupt: @Sendable (Bool) -> Void
    /// v0.17：要念 Claude 的回覆時用 playAndRecord（.record 不會出聲）；不念照舊 .record。只在主執行緒改。
    private(set) var playback = false
    private var running = false

    /// 兩個回呼都標 @Sendable：onSamples 在音訊執行緒叫，不能被推成主執行緒專用（Swift 執行期檢查會閃退）。
    init?(onSamples: @escaping @Sendable ([Int16], Int64, Int64) -> Void, onInterrupt: @escaping @Sendable (Bool) -> Void) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true) else {
            return nil
        }
        outFormat = format
        self.onSamples = onSamples
        self.onInterrupt = onInterrupt
    }

    /// 念回覆要喇叭：playAndRecord＋預設喇叭（接耳機、藍牙耳機就從耳機出來）；麥克風照樣是手機的。
    private static func setCategory(playback: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if playback {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        } else {
            try session.setCategory(.record, mode: .default)
        }
    }

    /// 連著時打開或關掉「念出回覆」：換類別，收音會停一下再接上（跟插拔耳機一樣，下一包重設起點）。
    func setPlayback(_ on: Bool) {
        guard on != playback else { return }
        playback = on
        guard running else { return }
        try? LinkMic.setCategory(playback: on)
        try? AVAudioSession.sharedInstance().setActive(true)
        restart()
        onInterrupt(false)
    }

    func start(playback wantPlayback: Bool = false) throws {
        playback = wantPlayback
        let session = AVAudioSession.sharedInstance()
        try LinkMic.setCategory(playback: wantPlayback)
        try session.setActive(true)
        try installTap()
        engine.prepare()
        try engine.start()
        running = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let kind = AVAudioSession.InterruptionType(rawValue: raw) else {
                return
            }
            if kind == .began {
                self?.onInterrupt(true)
            } else {
                try? AVAudioSession.sharedInstance().setActive(true)
                self?.restart()
                self?.onInterrupt(false)
            }
        })
        // 插拔耳機等：麥克風格式可能變，要重接
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
            self?.onInterrupt(false)
        })
        // 媒體服務重置（少見）：整個重開
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            try? LinkMic.setCategory(playback: self?.playback ?? false)
            try? AVAudioSession.sharedInstance().setActive(true)
            self?.restart()
            self?.onInterrupt(false)
        })
    }

    private func restart() {
        guard !engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        try? installTap()
        engine.prepare()
        try? engine.start()
    }

    private func installTap() throws {
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: outFormat) else {
            throw RecorderError.couldNotStart
        }
        converter.downmix = true
        let target = outFormat
        let latencyUs = Int64(max(0, AVAudioSession.sharedInstance().inputLatency) * 1_000_000)
        let deliver = onSamples
        // 約 100 毫秒一批（系統不一定照這個大小給）
        node.installTap(onBus: 0, bufferSize: AVAudioFrameCount(max(1024, format.sampleRate / 10)), format: format) { buffer, _ in
            let now = LinkClock.nowUs()
            guard let samples = LinkMic.convert(buffer, with: converter, to: target) else { return }
            deliver(samples, now, latencyUs)
        }
    }

    /// 裝置的取樣率（多半 48 kHz）換成 16 kHz 單聲道 int16。converter 只在音訊執行緒用，濾波器狀態接得上一批。
    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> [Int16]? {
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
        guard status != .error, failure == nil, output.frameLength > 0, let channel = output.int16ChannelData else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    func stop() {
        running = false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: v0.17 念 Claude 的回覆（AVSpeechSynthesizer，iOS 內建聲音；不送出去）

final class LinkSpeaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synth = AVSpeechSynthesizer()
    /// 開始念（true＋估的秒數＋念的字）、念完或被停（false）。在主執行緒叫。
    var onState: ((Bool, Double?, String) -> Void)?
    private var current: AVSpeechUtterance?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// v0.18：手機上的中文聲音（選單用）。Siri 的聲音 Apple 通常不列給 App，所以選單裡不會有。
    static func chineseVoices() -> [LinkVoiceOption] {
        let all = AVSpeechSynthesisVoice.speechVoices().map { v in
            LinkVoiceOption(id: v.identifier, name: v.name, language: v.language,
                            enhanced: v.quality == .enhanced || v.quality == .premium)
        }
        return LinkVoiceChoice.menu(all)
    }

    /// v0.18：savedID 空＝跟系統一樣：不指定哪個聲音，只說是中文（台灣），並請 iOS 套用
    /// 「設定 > 輔助使用 > 朗讀內容」的聲音和速度（prefersAssistiveTechnologySettings）。
    /// 那裡選了 App 拿不到的聲音（例如 Siri）時，iOS 自己退回，App 不猜。
    /// savedID 有值且手機上還有那個聲音 → 用它；被刪掉了 → 也是跟系統一樣。
    func speak(_ text: String, voiceID savedID: String) {
        let clean = LinkSpeech.clean(text)
        guard !clean.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: clean)
        if !savedID.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: savedID) {
            utterance.voice = chosen
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
            utterance.prefersAssistiveTechnologySettings = true
        }
        current = utterance
        synth.speak(utterance)
    }

    func stop() {
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
    }

    private func tell(_ utterance: AVSpeechUtterance, playing: Bool) {
        let spokenText = utterance.speechString
        let seconds = playing ? LinkSpeech.seconds(for: spokenText) : nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !playing, self.current !== utterance { return }      // 舊的那則被新的換掉：新的會自己講
            if !playing { self.current = nil }
            self.onState?(playing, seconds, spokenText)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        tell(utterance, playing: true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        tell(utterance, playing: false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        tell(utterance, playing: false)
    }
}

// MARK: 畫面用的狀態

@MainActor
@Observable
final class PhoneLink {
    enum Stage: Equatable {
        /// 開相機掃 QR 碼
        case scanning
        /// 掃到了，選用法
        case choosing
        /// 連電腦中（第一次）
        case connecting
        /// 連上了：電腦在錄就在傳，沒在錄就等
        case connected
        /// 中斷了，正在重連
        case lost
        /// 結束了（被取代、電腦關掉、憑證不符、配對碼失效、沒麥克風權限）
        case ended
    }

    private(set) var stage: Stage = .scanning
    private(set) var target: LinkTarget?
    private(set) var pcRecording = false
    /// 給他看的一句話（中斷原因、結束原因、電腦的提醒）。
    private(set) var note: String?
    private(set) var warning: String?
    private(set) var scanError: String?
    private(set) var level = 0.0
    private(set) var sentSeconds = 0.0
    private(set) var rttMs: Int?
    private(set) var lostSince: Date?
    private(set) var drops = 0
    private(set) var lostTotalSamples = 0
    /// 接上時：「手機收音接上了，中間少了約 N 秒」。
    private(set) var resumeNote: String?
    /// v0.16：電腦算的這場共少幾秒（協定 v2 的 gap）；nil＝電腦沒送（舊版），用手機自己算的。
    private(set) var pcLostTotal: Double?
    /// v0.16：電腦傳來的即時稿（協定 v3）。斷線重連時留著，電腦重送整份就換掉；停止後也留著，錄完的稿還能存。
    private(set) var pc = PCTranscript()
    /// v0.17：叫 Claude 的對話（協定 v4）。跟稿一樣：重連時電腦重送整份就換掉；停止後也留著看得到。
    private(set) var chat = PCChat()
    /// 正在想從什麼時候開始（畫面寫「想了 N 秒」，卡住看得出來）。
    private(set) var thinkingSince: Date?
    /// 電腦收不收手機念回覆的時段（協定 v4）。
    private(set) var pcTakesSpeech = false
    /// 電腦的協定版本（0＝還沒連上過）。v5 起電腦會在他開口時叫手機停（開口就停）。
    private(set) var pcVersion = 0
    /// v0.19：開口就停停過時的那句（下一則開始念就清掉）。
    private(set) var bargeNote: String?
    /// 手機現在的網路（連不上時講原因）。
    private(set) var network: LinkNetwork = .unknown
    /// v0.18：念回覆用哪個聲音；空字串＝跟系統一樣（預設）。存 AVSpeechSynthesisVoice 的 identifier。
    var speakVoice: String = UserDefaults.standard.string(forKey: LinkVoiceChoice.defaultsKey) ?? "" {
        didSet {
            let chosen = speakVoice
            UserDefaults.standard.set(chosen, forKey: LinkVoiceChoice.defaultsKey)
        }
    }

    /// v0.19 開口就停：預設開。開著時念的那則讓電腦盯，他一開口電腦就叫手機停。
    var stopOnVoice: Bool = LinkBargeRule.enabled(saved: UserDefaults.standard.object(forKey: LinkBargeRule.defaultsKey)) {
        didSet {
            let on = stopOnVoice
            UserDefaults.standard.set(on, forKey: LinkBargeRule.defaultsKey)
        }
    }

    /// 念出回覆：預設關；開了用 iPhone 的聲音（預設跟系統朗讀設定一樣）念每一則新回覆。
    var speakReplies: Bool = UserDefaults.standard.bool(forKey: "linkSpeakReplies") {
        didSet {
            UserDefaults.standard.set(speakReplies, forKey: "linkSpeakReplies")
            mic?.setPlayback(speakReplies)
            if !speakReplies {
                speaker?.stop()
            }
        }
    }

    var use: LinkUse = LinkUse(rawValue: UserDefaults.standard.string(forKey: "linkUse") ?? "") ?? .split {
        didSet { UserDefaults.standard.set(use.rawValue, forKey: "linkUse") }
    }

    @ObservationIgnored private var core: LinkCore?
    @ObservationIgnored private var mic: LinkMic?
    @ObservationIgnored private var speaker: LinkSpeaker?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    /// 連不上（第一次連、或斷線重連中）時最前面那句：手機在行動網路／沒網路就直接講。
    var networkHint: String? {
        guard stage == .connecting || stage == .lost else { return nil }
        return LinkHint.network(network)
    }

    var isActive: Bool {
        switch stage {
        case .connecting, .connected, .lost: return true
        default: return false
        }
    }

    // MARK: 掃碼

    func beginScan() {
        shutDown(sendOff: true)
        target = nil
        note = nil
        warning = nil
        scanError = nil
        stage = .scanning
    }

    func scanned(_ text: String) {
        switch LinkTarget.parse(text) {
        case .success(let found):
            target = found
            scanError = nil
            stage = .choosing
        case .failure(let error):
            scanError = error.message
        }
    }

    func scanFailed(_ message: String) {
        scanError = message
    }

    // MARK: 連線

    func connect(using chosen: LinkUse) {
        guard let target else {
            beginScan()
            return
        }
        use = chosen
        shutDown(sendOff: false)
        note = nil
        warning = nil
        resumeNote = nil
        pcLostTotal = nil
        pc = PCTranscript()
        chat = PCChat()
        thinkingSince = nil
        pcTakesSpeech = false
        pcRecording = false
        level = 0
        sentSeconds = 0
        rttMs = nil
        drops = 0
        lostTotalSamples = 0
        lostSince = nil
        stage = .connecting
        watchNetwork()
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                finish("沒有麥克風權限。到「設定 > 隱私權與安全性 > 麥克風」打開「轉文字」")
                return
            }
            guard stage == .connecting, core == nil else { return }
            start(target: target, use: chosen)
        }
    }

    private func start(target: LinkTarget, use chosen: LinkUse) {
        let device = UIDevice.current.model   // 「iPhone」「iPad」：不送手機的名字（可能有人名）
        // 回呼標 @Sendable：在 LinkCore 的佇列上叫，再自己排回主執行緒
        let newCore = LinkCore(target: target, use: chosen, device: device) { @Sendable [weak self] event in
            guard let owner = self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    owner.apply(event)
                }
            }
        }
        guard let newMic = LinkMic(
            onSamples: { @Sendable [weak newCore] samples, now, latency in
                newCore?.took(samples, nowUs: now, latencyUs: latency)
            },
            onInterrupt: { @Sendable [weak newCore] began in
                newCore?.interrupted(began: began)
            }
        ) else {
            finish("開不了收音")
            return
        }
        do {
            try newMic.start(playback: speakReplies)
        } catch {
            newMic.stop()
            finish("開不了收音：\(error.localizedDescription)")
            return
        }
        core = newCore
        mic = newMic
        newCore.start()
    }

    /// 換用法：電腦錄音中不接受（電腦會回提醒）。
    func change(to newUse: LinkUse) {
        use = newUse
        core?.setUse(newUse)
    }

    /// 結束後「再連一次」：同一個 QR 碼（配對碼還有效才連得上）。
    func reconnect() {
        connect(using: use)
    }

    /// 他按停止或關掉這個畫面。
    func stop() {
        shutDown(sendOff: true)
        if stage != .scanning && stage != .choosing {
            stage = .ended
            note = "已停止收音"
        }
    }

    private func finish(_ message: String) {
        shutDown(sendOff: false)
        stage = .ended
        note = message
    }

    private func shutDown(sendOff: Bool) {
        speaker?.stop()
        core?.stop(sendOff: sendOff)
        core = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        mic?.stop()
        mic = nil
        level = 0
        pcRecording = false
        lostSince = nil
    }

    private func apply(_ event: LinkEvent) {
        guard core != nil else { return }      // 停掉之後才到的
        switch event {
        case .opening:
            if stage != .lost {
                stage = .connecting
            }
        case .open:
            break
        case .ready(let rtt, let lostSamples, let wasLost):
            rttMs = rtt
            if wasLost {
                lostTotalSamples += lostSamples
                let seconds = lostSince.map { Date().timeIntervalSince($0) } ?? 0
                resumeNote = String(format: "接上了：斷了約 %.0f 秒，%@", seconds, LinkText.lost(samples: lostSamples))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            lostSince = nil
            note = nil
            stage = .connected
        case .rtt(let rtt):
            rttMs = rtt
        case .recording(let value):
            pcRecording = value
        case .lost(let why):
            // 連上過才算「中斷」；第一次還沒連上就停在「連電腦中」，下面寫原因和幾秒後重試
            if stage == .connected {
                drops += 1
                lostSince = Date()
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                stage = .lost
            }
            note = LinkHint.lostNote(why, network: network)
        case .ended(let message):
            speaker?.stop()
            core = nil
            mic?.stop()
            mic = nil
            level = 0
            pcRecording = false
            lostSince = nil
            stage = .ended
            note = message
        case .warn(let text):
            warning = text
        case .meter(let value, let sent):
            level = value
            sentSeconds = Double(sent) / Double(LinkStamper.rate)
        case .welcome(let version, let sendsText):
            pc.supported = sendsText
            // v4（電腦版 v5.29）起才送叫 Claude 的對話、收念回覆的時段；電腦有稿就有對話（同一個開關）
            chat.supported = PCChat.supported(version: version, chat: sendsText)
            pcTakesSpeech = version >= 4
            pcVersion = version
        case .gap(_, let totalSec, let message):
            // 少幾秒以電腦的為準（跟電腦提醒、稿頭同一個算法）；手機自己算的只在舊電腦時用
            if !message.isEmpty {
                resumeNote = message
            }
            pcLostTotal = totalSec
        case .text(let message):
            pc.apply(message)
        case .chat(let message):
            let wasThinking = chat.thinking
            let before = chat.newReplies
            chat.apply(message)
            if chat.thinking != wasThinking {
                thinkingSince = chat.thinking == nil ? nil : Date()
            }
            if chat.newReplies > before, let reply = chat.lastNewReply {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if speakReplies {
                    say(reply.text)
                }
            }
        case .ttsStop(let id):
            // v0.19 開口就停：同一則才停（上一則的停晚到不能停到下一則）；停了 LinkSpeaker 會回報念完，照常告訴電腦
            if LinkBargeRule.shouldStop(enabled: stopOnVoice, speakingID: speakingID, stopID: id) {
                speaker?.stop()
                bargeNote = "聽到你開口，先停了"
            }
        }
    }

    // MARK: v0.17 念回覆

    /// 念一則（新回覆，或他在對話裡按「念這則」）。念的時段照協定 v4 告訴電腦。
    func say(_ text: String) {
        let voice: LinkSpeaker
        if let existing = speaker {
            voice = existing
        } else {
            voice = LinkSpeaker()
            voice.onState = { [weak self] playing, seconds, text in
                MainActor.assumeIsolated {
                    self?.spoke(playing, seconds: seconds, text: text)
                }
            }
            speaker = voice
        }
        mic?.setPlayback(true)          // 沒開「念出回覆」時按「念這則」：先換成能出聲的類別
        if mic == nil {                 // 停了之後才按「念這則」：沒有收音，用一般播放的類別
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        let chosen = speakVoice
        voice.speak(text, voiceID: chosen)
    }

    func stopSpeaking() {
        speaker?.stop()
    }

    private(set) var speakingNow = false
    /// v0.19：現在念的是第幾則（開口就停對編號用）；沒在念＝nil。
    @ObservationIgnored private var speakingID: Int?
    @ObservationIgnored private var speakSeq = 0

    private func spoke(_ playing: Bool, seconds: Double?, text: String) {
        speakingNow = playing
        var barge: LinkBarge?
        if playing {
            speakSeq += 1
            let seq = speakSeq
            speakingID = seq
            bargeNote = nil
            if stopOnVoice {
                barge = LinkBarge(id: seq, text: text)
            }
        } else {
            speakingID = nil
        }
        if pcTakesSpeech {
            core?.speaking(playing, seconds: seconds, barge: barge)
        }
    }

    // MARK: v0.17 網路種類

    private func watchNetwork() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let kind = PhoneLink.kind(of: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.network = kind
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "lecturetext.path"))
        pathMonitor = monitor
    }

    nonisolated private static func kind(of path: NWPath) -> LinkNetwork {
        let types = path.availableInterfaces.map(\.type)
        if path.usesInterfaceType(.wifi) || types.contains(.wifi) {
            return .wifi
        }
        if path.usesInterfaceType(.wiredEthernet) || types.contains(.wiredEthernet) {
            return .wired
        }
        if path.usesInterfaceType(.cellular) || types.contains(.cellular) {
            return .cellular
        }
        return path.status == .satisfied ? .other : .none
    }
}
