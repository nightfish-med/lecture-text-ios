import AVFoundation
import Foundation

// 用法：diarize_check 輸出.wav A:片段1.wav B:片段2.wav A:片段3.wav …
// 把片段接成一個檔，答案就是每段是誰。全是合成語音，只驗路接得通，不能代表真人準確度。
let arguments = Array(CommandLine.arguments.dropFirst())
let output = URL(fileURLWithPath: arguments[0])
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
var truth: [SpeakerTurn] = []
var position = 0.0
do {
    let file = try AVAudioFile(forWriting: output, settings: format.settings)
    for item in arguments.dropFirst() {
        let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
        let source = try AVAudioFile(forReading: URL(fileURLWithPath: parts[1]), commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(source.length))!
        try source.read(into: buffer)
        try file.write(from: buffer)
        let seconds = Double(buffer.frameLength) / 16000
        truth.append(SpeakerTurn(speaker: parts[0], start: position, end: position + seconds))
        position += seconds
    }
}

let started = Date()
let diarized = try await SpeakerEngine.run(audioURL: output, count: 2) { _ in }
let turns = diarized.turns
print(String(format: "音檔 %.1f 秒，分人 %.1f 秒，得到 %d 段", position, Date().timeIntervalSince(started), turns.count))
if let timing = diarized.timing {
    print(String(format: "細項：載入 %.1f、切段 %.1f、聲紋 %.1f、分群 %.1f", timing.load, timing.segment, timing.embed, timing.cluster))
}
for turn in turns {
    print(String(format: "  %@ %.1f–%.1f", turn.speaker, turn.start, turn.end))
}

// 每段答案配一小片字，看貼回去的字對不對
let pieces = truth.enumerated().map { index, segment in
    TimedPiece(text: "第\(index + 1)段\(segment.speaker)。", start: segment.start, end: segment.end)
}
let labeled = SpeakerLabeler.label(pieces: pieces, turns: turns)
print("貼回字：\n\(labeled.text)")

// 重疊秒數，答案的 A、B 和模型的名字取比較好的那種對法
func overlap(_ a: SpeakerTurn, _ b: SpeakerTurn) -> Double { max(0, min(a.end, b.end) - max(a.start, b.start)) }
let names = Array(Set(turns.map(\.speaker))).sorted()
var best = 0.0
if names.count >= 1 {
    let first = names[0]
    for mapA in [true, false] {
        var right = 0.0
        for segment in truth {
            for turn in turns {
                let sameName = (turn.speaker == first) == mapA
                if (segment.speaker == "A") == sameName { right += overlap(segment, turn) }
            }
        }
        best = max(best, right)
    }
}
print(String(format: "對的時間比例 %.3f（合成語音，只驗路接得通）", best / max(position, 0.001)))

// 同一個合成語音單獨一個檔：指定 2 人是不是會被拆、自動判幾人。只看合成語音，不能代表真人。
let solo = output.deletingLastPathComponent().appendingPathComponent("solo.wav")
do {
    let file = try AVAudioFile(forWriting: solo, settings: format.settings)
    for item in arguments.dropFirst() where item.hasPrefix("A:") {
        let path = String(item.dropFirst(2))
        let source = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(source.length))!
        try source.read(into: buffer)
        try file.write(from: buffer)
    }
}
let soloCases: [(String, Int?)] = [("指定 2 人", 2), ("自動", nil)]
for (name, count) in soloCases {
    let result = try await SpeakerEngine.run(audioURL: solo, count: count) { _ in }
    print("單人檔，\(name)：分出 \(Set(result.turns.map(\.speaker)).count) 人")
}
