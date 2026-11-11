import AVFoundation
import Foundation
import Observation
import WhisperKit

// v0.24「即時模式」第 2 種：錄音中同時跑 Whisper（畫面照舊只顯示 Apple＋Haiku 綠字），Haiku 每 60 秒一批、附上同一段的 Whisper 稿當證據。
// 聲音：AudioPump 存檔那份（16 kHz 單聲道）同時抄一份到 SampleTap；這裡每秒拿走，滿 25 秒（多看 5 秒找最安靜處切）送 Whisper 一次。
// 每段過濾鬼打牆、幻覺句（WhisperClean，和下課轉檔同一套）。Whisper 稿另存「… Whisper即時.txt」，不上傳。
// 在背景時 iOS 可能不給跑：那段失敗就留著，5 秒後再試，聲音不丟（最多留 20 分鐘）。

/// 麥克風回呼（不在主執行緒）寫、LiveWhisper 讀。編號＝這段錄音的第幾個樣本。
final class SampleTap: @unchecked Sendable {
    static let cap = 16_000 * 60 * 20
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var base = 0

    func append(_ pcm: AVAudioPCMBuffer) {
        guard let data = pcm.int16ChannelData else { return }
        let count = Int(pcm.frameLength)
        let p = data[0]
        lock.lock()
        defer { lock.unlock() }
        buffer.reserveCapacity(buffer.count + count)
        for i in 0..<count { buffer.append(Float(p[i]) / 32768) }
        if buffer.count > Self.cap {
            let drop = buffer.count - Self.cap
            buffer.removeFirst(drop)
            base += drop
        }
    }

    /// 拿走目前全部：第一個樣本的編號、樣本
    func take() -> (start: Int, samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        let out = (base, buffer)
        base += buffer.count
        buffer = []
        return out
    }
}

@MainActor
@Observable
final class LiveWhisper {
    static let window = 25.0, search = 5.0
    /// Haiku 那批的 Whisper 還沒轉到時最多等幾秒（牆上時間）
    static let waitSeconds = 40.0

    let tap = SampleTap()
    /// 續錄位移（秒）：時間和 Apple 那邊一樣加上去
    private let offset: Double
    private let saveTo: URL?
    private(set) var pieces: [TimedPiece] = []
    /// 已經轉到第幾秒（含續錄位移）
    private(set) var covered: Double
    private(set) var finished = false
    private(set) var note = "Whisper：載入模型"
    @ObservationIgnored private var pending: [Float] = []
    @ObservationIgnored private var pendingStart = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var ending = false
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var compute = 0.0
    @ObservationIgnored private var lines: [String] = []

    init(offset: Double, saveTo: URL?) {
        self.offset = offset
        self.covered = offset
        self.saveTo = saveTo
    }

    func start() {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await WhisperRunner.load { [weak self] text in self?.note = "Whisper：" + text }
                await self.run(loaded.pipe)
            } catch {
                self.note = "Whisper 載不起來（這場只用 Apple）：\(error.localizedDescription)"
            }
            self.finished = true
        }
    }

    /// 錄音停了：剩下的聲音轉完就結束
    func end() { ending = true }

    func cancel() {
        task?.cancel()
        task = nil
        finished = true
    }

    private func run(_ pipe: WhisperKit) async {
        let rate = WhisperPlan.sampleRate
        let need = Int((Self.window + Self.search) * rate)
        note = "Whisper：跟著錄音轉"
        while !Task.isCancelled {
            let got = tap.take()
            if got.start != pendingStart + pending.count {
                // 落後超過 20 分鐘、最舊的聲音被丟了：從還在的地方接著轉
                pending = []
                pendingStart = got.start
            }
            pending += got.samples
            let last = ending
            guard pending.count >= need || (last && !pending.isEmpty) else {
                if last { break }
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let cut = pending.count >= need ? WhisperPlan.quietCut(Array(pending[0..<need]), from: Int(Self.window * rate)) : pending.count
            let chunk = Array(pending[0..<cut])
            let at = offset + Double(pendingStart) / rate
            let clock = Date()
            do {
                let raw = try await WhisperRunner.transcribe(pipe, samples: chunk, offset: at, prompt: nil)
                compute += Date().timeIntervalSince(clock)
                let kept = WhisperClean.clean(raw).pieces
                pieces += kept
                pending.removeFirst(cut)
                pendingStart += cut
                covered = at + Double(cut) / rate
                lines += kept.map { "[\(formatStamp($0.start))] " + $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                save()
                let behind = max(0, offset + Double(pendingStart + pending.count) / rate - covered)
                note = String(format: "Whisper：落後 %.0f 秒，運算÷錄音 %.2f", behind, compute / max(covered - offset, 1))
            } catch {
                if Task.isCancelled { break }
                failures += 1
                note = "Whisper：這段沒轉成（第 \(failures) 次，多半是 App 在背景），5 秒後再試"
                try? await Task.sleep(for: .seconds(5))
            }
        }
        save()
    }

    private func save() {
        guard let saveTo else { return }
        let text = lines.joined(separator: "\n") + "\n"
        Task.detached { try? text.write(to: saveTo, atomically: true, encoding: .utf8) }
    }

    /// 這段時間（秒，含續錄位移）的 Whisper 字，前後各多帶 1 秒；最多 1500 字
    func text(from start: Double, to end: Double) -> String {
        let joined = pieces.filter { $0.end > start - 1 && $0.start < end + 1 }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined()
        return String(joined.prefix(1500))
    }

    /// 附在 Haiku 新稿後面的一段（系統提示詞不動，快取照舊）
    static func referenceBlock(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        return "\n\nWhisper 同一段（另一個辨識器，只當證據，不准改這段、不准問這段）：\n\(text)\n"
            + "新稿和 Whisper 寫得不一樣、而 Whisper 的寫法明顯比較合理（術語、英文、同音字）時可以改新稿，evidence 寫「Whisper」。Whisper 也會重複、漏字、亂寫，兩邊都不合理就不要改。"
    }
}
