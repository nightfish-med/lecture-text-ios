import AVFoundation
import Foundation
import Observation

/// v0.14：點一句從那裡播。
/// 時間.json 的秒數是整場的（續錄的第 2 段接著第 1 段算），這裡換成「第幾段錄音的第幾秒」。
/// 一段播完自動接下一段。播放時音訊設成 playback；開始錄音前一定先 stop()。
@MainActor
@Observable
final class Playback {
    struct Part {
        let url: URL
        /// 這段在整場的第幾秒開始
        let start: Double
        let duration: Double
    }

    private(set) var parts: [Part] = []
    private(set) var isPlaying = false
    /// 播過（下面要出播放條）
    private(set) var isActive = false
    /// 整場的第幾秒
    private(set) var position: Double = 0
    var total: Double { parts.last.map { $0.start + $0.duration } ?? 0 }
    var hasAudio: Bool { !parts.isEmpty }

    @ObservationIgnored private(set) var loadedKey: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var current = -1
    private let delegate = PlayerDelegate()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var sessionActive = false

    init() {
        delegate.onFinish = { [weak self] in
            self?.partFinished()
        }
    }

    /// files 照段的順序；start 是存下來的每段開頭（v0.14 起有），缺的話用前面幾段的長度加起來。
    func load(key: String, files: [(url: URL, start: Double?)]) {
        guard key != loadedKey else { return }
        stop()
        let given = files.allSatisfy { $0.start != nil }
        var result: [Part] = []
        var next = 0.0
        for file in files {
            let duration = Self.duration(of: file.url)
            let start = given ? (file.start ?? next) : next
            if duration > 0 {
                result.append(Part(url: file.url, start: start, duration: duration))
            }
            next = start + duration
        }
        parts = result
        loadedKey = key
    }

    private static func duration(of url: URL) -> Double {
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = file.fileFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : 0
    }

    private func locate(_ t: Double) -> (index: Int, local: Double)? {
        guard !parts.isEmpty else { return nil }
        let index = parts.lastIndex(where: { $0.start <= t + 0.01 }) ?? 0
        let part = parts[index]
        return (index, max(0, min(t - part.start, part.duration - 0.05)))
    }

    private func open(_ index: Int) -> Bool {
        if index == current, player != nil { return true }
        guard let next = try? AVAudioPlayer(contentsOf: parts[index].url) else { return false }
        player?.stop()
        next.delegate = delegate
        next.prepareToPlay()
        player = next
        current = index
        return true
    }

    /// 從整場的第 t 秒開始播。播不了回傳 false。
    @discardableResult
    func play(from t: Double) -> Bool {
        guard let spot = locate(t), open(spot.index), let player else { return false }
        activateSession()
        player.currentTime = spot.local
        guard player.play() else { return false }
        position = parts[spot.index].start + spot.local
        isPlaying = true
        isActive = true
        startTicker()
        return true
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.cancel()
        updatePosition()
    }

    func resume() {
        guard let player else {
            play(from: position)
            return
        }
        activateSession()
        if player.play() {
            isPlaying = true
            isActive = true
            startTicker()
        }
    }

    func toggle() {
        if isPlaying {
            pause()
        } else if position >= total - 0.1 {
            play(from: 0)
        } else {
            resume()
        }
    }

    /// 拖播放條：播放中就接著播，暫停就停在那裡。
    func seek(to t: Double) {
        let wasPlaying = isPlaying
        guard let spot = locate(t), open(spot.index), let player else { return }
        player.currentTime = spot.local
        position = parts[spot.index].start + spot.local
        if wasPlaying {
            _ = player.play()
        }
    }

    /// 收起播放條；錄音、選檔、換一場之前都要叫。
    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        current = -1
        isPlaying = false
        isActive = false
        position = 0
        if sessionActive {
            sessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// 換一場：連載入的錄音一起忘掉。
    func unload() {
        stop()
        parts = []
        loadedKey = nil
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        sessionActive = true
    }

    private func updatePosition() {
        guard let player, current >= 0, current < parts.count else { return }
        position = parts[current].start + player.currentTime
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.updatePosition()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func partFinished() {
        if current + 1 < parts.count {
            play(from: parts[current + 1].start)
        } else {
            isPlaying = false
            ticker?.cancel()
            position = total
        }
    }
}

/// AVAudioPlayer 的回呼不保證在主執行緒，轉回主執行緒再通知。
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (@MainActor () -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finish = onFinish
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                finish?()
            }
        }
    }
}
