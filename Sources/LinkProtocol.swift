import Foundation

// v0.15 連電腦：手機當電腦版（兩人對談轉文字 v5.25）的麥克風。
// 協定照電腦版的手機收音協定（v1；協定文件不在這個倉庫）。這個檔只放算的東西（解析 QR 碼、包的格式、時間戳、
// 斷線時留 3 秒、重試間隔、讀電腦的訊息），不碰相機、麥克風、網路，所以 tools/shape_check 在雲端 Mac 上不用手機就能測。
// v0.16：協定 v3（電腦版 v5.27）——電腦在同一條連線把即時稿傳回手機（`PCText`、`PCTranscript`），手機只收不改。
// hello 送 v=3；也照 v2 讀電腦回傳的 `gap`（這次少幾秒，跟電腦稿頭同一個算法）。
// v0.17：協定 v4（電腦版 v5.29）——叫 Claude 的對話也傳回來（`PCChatMessage`、`PCChat`）；手機念回覆時送 `tts`
// （念的時段電腦不寫進稿、不拿來叫 Claude）。hello 送 v=4。連不上時照網路種類講原因（`LinkNetwork`、`LinkHint`）。
// v0.19：協定 v5（電腦版 v5.33）——開口就停：念回覆時，使用者一開口就停下來。念的時候 `tts` 多帶
// stop_on_voice、這則的編號和字（`LinkBarge`）；電腦用自己的麥克風判斷他開口了就回 `tts_stop`（同一個編號），手機停念。
// 手機不另外開麥克風、不改錄音的設定：判斷全在電腦（`LinkBargeRule` 只管手機這邊要不要停、畫面怎麼寫）。

/// 兩種用法（協定第 5 節）。
enum LinkUse: String, CaseIterable {
    /// 分軌：電腦麥克風＝我、手機放對方旁邊＝對方。
    case split
    /// 只用手機：手機放兩人中間，電腦放遠處；電腦按結束後 AI 分人。
    case only

    var title: String {
        switch self {
        case .split: return "手機收對方（分軌）"
        case .only: return "只用手機收音"
        }
    }

    var detail: String {
        switch self {
        case .split: return "手機放對方旁邊，電腦麥克風收你。兩條軌分開，誰說的不用猜"
        case .only: return "手機放兩人中間，電腦放遠處。電腦按結束後再分人"
        }
    }
}

/// QR 碼裡的電腦：`https://<IP>:8793/?k=<配對碼>&fp=<憑證 SHA-256 指紋>`（協定第 1 節）。
struct LinkTarget: Equatable {
    let host: String
    let port: Int
    /// 配對碼：每次電腦按「連手機」都換新。
    let key: String
    /// 電腦自簽憑證 DER 的 SHA-256，64 個小寫十六進位字。
    let fp: String

    static let defaultPort = 8793

    enum ParseError: Error, Equatable {
        case notLink
        case noKey
        case noFingerprint
        case badFingerprint

        var message: String {
            switch self {
            case .notLink: return "這不是電腦版「連手機」的 QR 碼"
            case .noKey: return "QR 碼裡沒有配對碼，請在電腦重新按「連手機」"
            case .noFingerprint: return "QR 碼裡沒有憑證指紋：電腦版要 v5.25 以上"
            case .badFingerprint: return "QR 碼裡的憑證指紋格式不對，請重新掃"
            }
        }
    }

    static func parse(_ text: String) -> Result<LinkTarget, ParseError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty else {
            return .failure(.notLink)
        }
        let items = parts.queryItems ?? []
        let key = items.first(where: { $0.name == "k" })?.value ?? ""
        guard !key.isEmpty else {
            return .failure(.noKey)
        }
        let rawFp = items.first(where: { $0.name == "fp" })?.value ?? ""
        guard !rawFp.isEmpty else {
            return .failure(.noFingerprint)
        }
        guard let fp = normalizedFingerprint(rawFp) else {
            return .failure(.badFingerprint)
        }
        let port = parts.port ?? defaultPort
        guard port > 0, port < 65536 else {
            return .failure(.notLink)
        }
        return .success(LinkTarget(host: host, port: port, key: key, fp: fp))
    }

    /// 允許大寫、冒號分隔（有人手抄時常這樣），統一成 64 個小寫十六進位字；不是就回 nil。
    static func normalizedFingerprint(_ raw: String) -> String? {
        let cleaned = raw.lowercased().replacingOccurrences(of: ":", with: "")
        let hex = Set("0123456789abcdef")
        guard cleaned.count == 64, cleaned.allSatisfy({ hex.contains($0) }) else {
            return nil
        }
        return cleaned
    }

    /// 伺服器憑證算出來的指紋（小寫十六進位）跟 QR 碼的一樣才接受。
    func accepts(fingerprint: String) -> Bool {
        LinkTarget.normalizedFingerprint(fingerprint) == fp
    }

    /// 收音通道：`wss://<IP>:8793/mic?k=<配對碼>&client=app&device=<顯示用名字>`（協定第 2 節）。
    func micURL(device: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "wss"
        parts.host = host
        parts.port = port
        parts.path = "/mic"
        parts.queryItems = [
            URLQueryItem(name: "k", value: key),
            URLQueryItem(name: "client", value: "app"),
            URLQueryItem(name: "device", value: String(device.prefix(40))),
        ]
        return parts.url
    }

    /// 畫面上顯示用（不顯示配對碼）。
    var label: String { "\(host):\(port)" }
}

/// 一包聲音（協定 2.2）：TPA1、序號、第一個取樣的手機時間（微秒）、取樣數、旗標，後面 16 kHz 單聲道 int16，全部小端。
struct LinkFrame: Equatable {
    static let resumeFlag: UInt32 = 1
    let seq: UInt32
    let timestampUs: Int64
    let samples: [Int16]
    let flags: UInt32

    var data: Data {
        var out = Data(capacity: 24 + samples.count * 2)
        out.append(contentsOf: [0x54, 0x50, 0x41, 0x31])  // "TPA1"
        LinkFrame.put(seq, into: &out)
        LinkFrame.put(timestampUs, into: &out)
        LinkFrame.put(UInt32(samples.count), into: &out)
        LinkFrame.put(flags, into: &out)
        let little = samples.map { $0.littleEndian }
        little.withUnsafeBytes { bytes in
            out.append(contentsOf: bytes)
        }
        return out
    }

    private static func put<T: FixedWidthInteger>(_ value: T, into data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    /// 測試用：把包頭讀回來。
    static func header(of data: Data) -> (magic: String, seq: UInt32, timestampUs: Int64, count: UInt32, flags: UInt32)? {
        guard data.count >= 24 else { return nil }
        let bytes = [UInt8](data)
        func read<T: FixedWidthInteger>(_ offset: Int, _ type: T.Type) -> T {
            var value: T = 0
            for i in 0..<MemoryLayout<T>.size {
                value |= T(truncatingIfNeeded: bytes[offset + i]) << (8 * i)
            }
            return value
        }
        let magic = String(bytes: bytes[0..<4], encoding: .ascii) ?? ""
        return (magic, read(4, UInt32.self), read(8, Int64.self), read(16, UInt32.self), read(20, UInt32.self))
    }
}

/// 把麥克風一批一批的聲音（已換成 16 kHz）切成 100 毫秒一包，算每包的時間戳（協定 2.2 的「時鐘」）。
/// 時間戳用取樣數算，不每包重抓現在時間：ts＝起點＋已送取樣數／16000。
/// 起點＝第一批時「現在 − 這批的長度 − 輸入延遲」；手機時鐘跟取樣數差超過 0.2 秒（暫停過、被打斷）就重設起點，那包旗標 bit0。
struct LinkStamper {
    static let rate: Int64 = 16_000
    static let packetSamples = 1_600
    static let resetUs: Int64 = 200_000

    private(set) var anchorUs: Int64?
    /// 起點之後已經切成包的取樣數。
    private(set) var sent: Int64 = 0
    private(set) var pending: [Int16] = []
    private(set) var resume = true
    /// 序號：重連後接著數，整條連線（整次連電腦）不歸零。
    private(set) var seq: UInt32 = 0

    static func microseconds(ofSamples count: Int64) -> Int64 {
        count * 1_000_000 / rate
    }

    /// 電腦沒在錄、被系統打斷：丟掉還沒湊滿的，下一批重設起點（旗標 bit0）。序號不歸零。
    mutating func reset() {
        anchorUs = nil
        sent = 0
        pending = []
        resume = true
    }

    /// nowUs：收到這批的手機時間；latencyUs：系統說的輸入延遲。回傳湊滿的包。
    mutating func feed(_ samples: [Int16], nowUs: Int64, latencyUs: Int64) -> [LinkFrame] {
        guard !samples.isEmpty else { return [] }
        let incoming = Int64(samples.count)
        let queued = sent + Int64(pending.count) + incoming
        let drift: Int64
        if let anchor = anchorUs {
            drift = abs(anchor + LinkStamper.microseconds(ofSamples: queued) - nowUs)
        } else {
            drift = .max
        }
        if drift > LinkStamper.resetUs {
            anchorUs = nowUs - LinkStamper.microseconds(ofSamples: incoming) - max(0, latencyUs)
            sent = 0
            pending = []
            resume = true
        }
        pending.append(contentsOf: samples)
        var out: [LinkFrame] = []
        let anchor = anchorUs ?? nowUs
        while pending.count >= LinkStamper.packetSamples {
            let chunk = Array(pending.prefix(LinkStamper.packetSamples))
            pending.removeFirst(LinkStamper.packetSamples)
            let stamp = anchor + LinkStamper.microseconds(ofSamples: sent)
            let flags = resume ? LinkFrame.resumeFlag : 0
            out.append(LinkFrame(seq: seq, timestampUs: stamp, samples: chunk, flags: flags))
            seq = seq &+ 1
            sent += Int64(LinkStamper.packetSamples)
            resume = false
        }
        return out
    }
}

/// 斷線時留最近 3 秒的包，接上先補送；更早的電腦也會丟，不用留（協定第 4 節）。
/// 被擠掉的取樣數就是「中間少了幾秒」。
struct LinkBacklog {
    struct Item {
        let at: Int64
        let data: Data
        let samples: Int
    }

    let holdUs: Int64
    private(set) var items: [Item] = []
    private(set) var droppedSamples = 0

    init(holdUs: Int64 = 3_000_000) {
        self.holdUs = holdUs
    }

    mutating func push(_ data: Data, samples: Int, at nowUs: Int64) {
        items.append(Item(at: nowUs, data: data, samples: samples))
        trim(now: nowUs)
    }

    mutating func trim(now nowUs: Int64) {
        while let first = items.first, nowUs - first.at > holdUs {
            droppedSamples += first.samples
            items.removeFirst()
        }
    }

    /// 接上了：拿出還在 3 秒內的包（照順序），清空。
    mutating func drain(now nowUs: Int64) -> [Data] {
        trim(now: nowUs)
        let out = items.map(\.data)
        items = []
        return out
    }

    /// 這次斷線少了幾個取樣，拿了就歸零。
    mutating func takeDropped() -> Int {
        let dropped = droppedSamples
        droppedSamples = 0
        return dropped
    }

    mutating func clear() {
        items = []
        droppedSamples = 0
    }
}

/// 重連間隔：1、2、3、4 秒……最多每 4 秒一次（協定第 4 節）。
enum LinkRetry {
    static func delay(attempt: Int) -> Double {
        Double(min(max(attempt, 1), 4))
    }
}

/// 手機送給電腦的文字訊息（協定 2.1）。
enum LinkOutgoing {
    case hello(use: LinkUse, device: String)
    case use(LinkUse)
    case ping(t1: Int64)
    case sync(t1: Int64, t2: Int64, t3: Int64)
    case pause(why: String)
    case off
    /// v4：手機用自己的喇叭念 Claude 的回覆。playing＝開始念（seconds＝估要念幾秒）／念完或停了。
    /// v5：barge 有值＝開口就停（帶這則的編號和念的字，電腦判斷他開口就回 tts_stop）。
    case tts(playing: Bool, seconds: Double?, barge: LinkBarge? = nil)

    /// 手機這邊照的協定版本。v4：要電腦的叫 Claude 對話（協定第 7 節）。v5：開口就停（第 8 節）。
    static let version = 5

    var object: [String: Any] {
        switch self {
        case .hello(let use, let device):
            // v=5：要電腦的即時稿（協定第 6 節）、叫 Claude 的對話（第 7 節）、開口就停（第 8 節）。舊電腦看到 5 也照收（手機不要因為版本不同就拒絕，電腦也是）
            return ["type": "hello", "v": LinkOutgoing.version, "client": "app", "device": String(device.prefix(40)),
                    "use": use.rawValue, "rate": 16_000, "frame_ms": 100]
        case .use(let use):
            return ["type": "use", "use": use.rawValue]
        case .ping(let t1):
            return ["type": "ping", "t1": t1]
        case .sync(let t1, let t2, let t3):
            return ["type": "sync", "t1": t1, "t2": t2, "t3": t3]
        case .pause(let why):
            return ["type": "pause", "why": why]
        case .off:
            return ["type": "off"]
        case .tts(let playing, let seconds, let barge):
            var out: [String: Any] = ["type": "tts", "playing": playing]
            if playing, let seconds, seconds.isFinite, seconds > 0 {
                out["seconds"] = (min(seconds, 180) * 10).rounded() / 10
            }
            if playing, let barge {
                out["stop_on_voice"] = true
                out["id"] = barge.id
                out["text"] = String(barge.text.prefix(LinkBarge.maxChars))
            }
            return out
        }
    }

    var text: String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

/// 電腦送給手機的文字訊息（協定 2.1）。
enum LinkIncoming: Equatable {
    /// version：電腦的協定版本；text：電腦會不會送即時稿（v3 起，電腦版 v5.27）。
    case welcome(recording: Bool, version: Int, text: Bool)
    case pong(t1: Int64, t2: Int64)
    /// pcOff：use 是 null、沒在錄、有 message＝電腦按了「不用手機收音」。
    case state(recording: Bool, pcOff: Bool, message: String?)
    case warn(String)
    case replaced(String)
    case bye(String)
    /// v2：斷線接上後電腦算的「這次少幾秒、這場共少幾秒」（跟電腦稿頭同一個算法）。
    case gap(lostSec: Double, totalSec: Double, message: String)
    /// v3：電腦的即時稿。
    case text(PCText)
    /// v4：叫 Claude 的對話（協定第 7 節，電腦版 v5.29）。
    case chat(PCChatMessage)
    /// v5：電腦聽到他開口了，叫手機停念（id＝手機送 tts 時帶的那則；nil＝電腦沒帶）。
    case ttsStop(id: Int?)
    case other

    static func parse(_ text: String) -> LinkIncoming {
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let object = any as? [String: Any],
              let type = object["type"] as? String else {
            return .other
        }
        let message = object["message"] as? String
        let recording = (object["recording"] as? Bool) ?? ((object["recording"] as? NSNumber)?.boolValue ?? false)
        if let pc = PCText.parse(type: type, object) {
            return .text(pc)
        }
        if let chat = PCChatMessage.parse(type: type, object) {
            return .chat(chat)
        }
        switch type {
        case "welcome":
            let version = LinkJSON.int(object["v"]) ?? 1
            let sendsText = (object["text"] as? Bool) ?? false
            return .welcome(recording: recording, version: version, text: version >= 3 && sendsText)
        case "gap":
            return .gap(lostSec: LinkJSON.double(object["lost_sec"]) ?? 0, totalSec: LinkJSON.double(object["total_sec"]) ?? 0, message: message ?? "")
        case "pong":
            guard let t1 = number(object["t1"]), let t2 = number(object["t2"]) else { return .other }
            return .pong(t1: t1, t2: t2)
        case "state":
            let useIsNull = object["use"] == nil || object["use"] is NSNull
            let pcOff = useIsNull && !recording && !(message ?? "").isEmpty
            return .state(recording: recording, pcOff: pcOff, message: message)
        case "warn":
            return .warn(message ?? "")
        case "replaced":
            return .replaced(message ?? "另一支手機接手收音了")
        case "bye":
            return .bye(message ?? "電腦關掉了手機連線")
        case "tts_stop":
            return .ttsStop(id: LinkJSON.int(object["id"]))
        default:
            return .other
        }
    }

    private static func number(_ value: Any?) -> Int64? {
        if let n = value as? NSNumber {
            let d = n.doubleValue
            guard d.isFinite else { return nil }
            return n.int64Value
        }
        return nil
    }
}

/// 音量條：一批取樣的 RMS 換成 0–1（-60 dBFS 以下算 0）。
enum LinkLevel {
    static func meter(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for s in samples {
            let x = Double(s) / 32768.0
            sum += x * x
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 60) / 60))
    }
}

/// 畫面上的「少了幾秒」。
enum LinkText {
    static func lost(samples: Int) -> String {
        let seconds = Double(samples) / Double(LinkStamper.rate)
        if seconds < 0.05 { return "沒有少" }
        return String(format: "少了約 %.1f 秒", seconds)
    }
}

// MARK: v0.16 電腦傳來的即時稿（協定 v3 第 6 節，電腦版 v5.27 起）

/// JSON 的數字安全地拿出來：不是有限的數字就當沒有，怪數字不會讓 App 閃退。
enum LinkJSON {
    static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let d = number.doubleValue
        return d.isFinite ? d : nil
    }

    static func int(_ value: Any?) -> Int? {
        guard let d = double(value), abs(d) < 1e15 else { return nil }
        return Int(d)
    }
}

/// 電腦傳來的一行稿。
struct PCLine: Equatable {
    let id: Int
    /// me、other、room（還沒分人）；分好人後是 A、B…
    let track: String
    /// 顯示的講者：我、對方、分好人後的名字；現場那軌還沒分人時是空的。
    let who: String
    /// 錄音開始後第幾秒。
    let start: Double
    let end: Double
    let stamp: String
    let text: String

    init(id: Int, track: String, who: String, start: Double, end: Double, stamp: String = "", text: String) {
        self.id = id
        self.track = track
        self.who = who
        self.start = start
        self.end = max(start, end)
        self.stamp = stamp
        self.text = text
    }

    init?(_ value: Any?) {
        guard let object = value as? [String: Any], let id = LinkJSON.int(object["id"]) else { return nil }
        let start = LinkJSON.double(object["start"]) ?? 0
        self.init(
            id: id,
            track: object["track"] as? String ?? "",
            who: String((object["who"] as? String ?? "").prefix(40)),
            start: start,
            end: LinkJSON.double(object["end"]) ?? start,
            stamp: object["stamp"] as? String ?? "",
            text: object["text"] as? String ?? ""
        )
    }
}

/// 那一軌的灰字（電腦還可能改）。
struct PCDraft: Equatable {
    let track: String
    let text: String
    let start: Double?
}

/// 電腦的錄音狀態。
enum PCRec: String, Equatable {
    case recording
    case processing
    case idle
}

/// 一份整份稿（text_all）。
struct PCSnapshot: Equatable {
    var session: String?
    var started: String?
    var rec: PCRec
    var eta: Double?
    /// live（錄音中）、final（定稿）、labelled（分好人）；還沒錄過是 nil。
    var stage: String?
    var mode: String?
    var names: [String: String]
    var lines: [PCLine]
    var drafts: [PCDraft]
    var omitted: Int
}

/// 電腦送來跟稿有關的訊息（協定第 6 節）。
enum PCText: Equatable {
    case all(PCSnapshot)
    case add(PCLine)
    case draft(PCDraft)
    case remove(Int)
    case rec(PCRec, eta: Double?, session: String?, started: String?)

    /// 不是稿的訊息（或格式不對）回 nil。
    static func parse(type: String, _ object: [String: Any]) -> PCText? {
        let rec = PCRec(rawValue: object["rec"] as? String ?? "") ?? .idle
        let eta = LinkJSON.double(object["eta"])
        let session = object["session"] as? String
        let started = object["started"] as? String
        switch type {
        case "text_all":
            let lines = (object["lines"] as? [Any] ?? []).compactMap { PCLine($0) }
            let drafts = (object["drafts"] as? [Any] ?? []).compactMap { item -> PCDraft? in
                guard let d = item as? [String: Any], let track = d["track"] as? String else { return nil }
                return PCDraft(track: track, text: d["text"] as? String ?? "", start: LinkJSON.double(d["start"]))
            }
            var names: [String: String] = [:]
            for (key, value) in object["names"] as? [String: Any] ?? [:] {
                if let name = value as? String {
                    names[key] = name
                }
            }
            let snapshot = PCSnapshot(
                session: session, started: started, rec: rec, eta: eta,
                stage: object["stage"] as? String, mode: object["mode"] as? String, names: names,
                lines: lines, drafts: drafts, omitted: LinkJSON.int(object["omitted"]) ?? 0
            )
            return .all(snapshot)
        case "text_add":
            guard let line = PCLine(object["line"]) else { return nil }
            return .add(line)
        case "text_draft":
            guard let track = object["track"] as? String else { return nil }
            return .draft(PCDraft(track: track, text: object["text"] as? String ?? "", start: LinkJSON.double(object["start"])))
        case "text_del":
            guard let id = LinkJSON.int(object["id"]) else { return nil }
            return .remove(id)
        case "rec":
            return .rec(rec, eta: eta, session: session, started: started)
        default:
            return nil
        }
    }
}

/// 手機這邊的電腦稿：照協定第 6 節套用——text_all 整份換掉（重連也是，所以不會重複）、text_add 同一個 id 換掉不然照時間插進去、
/// 灰字一軌一段（空的＝清掉）、text_del 拿掉。手機只收不改。畫面跟 App 自己錄音時一樣：黑字定稿、灰字還可能改。
struct PCTranscript: Equatable {
    /// nil＝還沒收到 welcome；false＝電腦是舊版（協定 v1／v2），不會送稿。
    var supported: Bool?
    /// 收到過整份了。
    private(set) var received = false
    private(set) var session: String?
    private(set) var started: String?
    private(set) var rec: PCRec = .idle
    private(set) var eta: Double?
    private(set) var stage: String?
    private(set) var mode: String?
    private(set) var names: [String: String] = [:]
    private(set) var lines: [PCLine] = []
    private(set) var drafts: [PCDraft] = []
    /// 太長被電腦拿掉的最舊幾行（最近 2000 行、一則 800 KB）。
    private(set) var omitted = 0

    /// 同一個人停不到這麼久就接在同一段（跟電腦畫面一樣 1.5 秒）。
    static let joinGap = 1.5
    /// 段落到這麼長、又剛好講完一句就換段；再長也一定換（跟 App 自己的分段差不多：約 110 字、最多 180 字）。
    static let softChars = 110
    static let hardChars = 180
    /// 畫面最多放最後幾個字（跟 App 錄音中一樣）；整份存成一場再看。
    static let tailChars = 3000
    private static let enders: Set<Character> = ["。", "？", "！", "?", "!", "…"]

    mutating func apply(_ message: PCText) {
        switch message {
        case .all(let snapshot):
            received = true
            session = snapshot.session
            started = snapshot.started
            rec = snapshot.rec
            eta = snapshot.eta
            stage = snapshot.stage
            mode = snapshot.mode
            names = snapshot.names
            lines = snapshot.lines.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
            drafts = snapshot.drafts.filter { !$0.text.isEmpty }
            omitted = snapshot.omitted
        case .add(let line):
            var next = lines.filter { $0.id != line.id }
            let at = next.firstIndex { $0.start > line.start } ?? next.endIndex
            next.insert(line, at: at)
            lines = next
        case .draft(let draft):
            var next = drafts.filter { $0.track != draft.track }
            if !draft.text.isEmpty {
                next.append(draft)
            }
            drafts = next
        case .remove(let id):
            let next = lines.filter { $0.id != id }
            lines = next
        case .rec(let state, let newEta, let newSession, let newStarted):
            rec = state
            eta = newEta
            if let newSession {
                session = newSession
            }
            if let newStarted {
                started = newStarted
            }
            if state != .recording {
                drafts = []
            }
        }
    }

    /// 那一軌現在叫什麼：最近一行的講者 → 分好人的名字 → 我／對方；現場還沒分人是空的。
    func whoOf(track: String) -> String {
        if let line = lines.last(where: { $0.track == track }) {
            return line.who
        }
        if let name = names[track] {
            return name
        }
        switch track {
        case "me": return "我"
        case "other": return "對方"
        default: return ""
        }
    }

    /// 黑字：照時間排。同一個人、停不到 1.5 秒、段落還不長就接著寫；換人、停久了、段落夠長就空一行。
    /// 每段段首寫「誰：」（跟 App 分人後的稿一樣）；現場還沒分人不寫。
    var finalText: String { Self.render(lines) }

    static func render(_ lines: [PCLine]) -> String {
        var out = ""
        var length = 0
        var last: PCLine?
        for line in lines where !line.text.isEmpty {
            if let prev = last {
                let ended = prev.text.last.map { enders.contains($0) } ?? false
                let sameWho = prev.who == line.who
                let close = line.start - prev.end <= joinGap
                let roomy = length + line.text.count <= hardChars && !(ended && length >= softChars)
                if sameWho && close && roomy {
                    out += line.text
                    length += line.text.count
                    last = line
                    continue
                }
                out += "\n\n"
            }
            out += (line.who.isEmpty ? "" : "\(line.who)：") + line.text
            length = line.text.count
            last = line
        }
        return out
    }

    /// 灰字：接在黑字後面。同一個人、接得上就接在同一段，不然另起一段（段首寫「誰：」）。
    var volatileText: String {
        var out = ""
        var last = lines.last(where: { !$0.text.isEmpty })
        for draft in drafts.sorted(by: { ($0.start ?? 0) < ($1.start ?? 0) }) {
            let who = whoOf(track: draft.track)
            let start = draft.start ?? last?.end ?? 0
            if let prev = last {
                if !(prev.who == who && start - prev.end <= Self.joinGap) {
                    out += "\n\n" + (who.isEmpty ? "" : "\(who)：")
                }
            } else if !who.isEmpty {
                out += "\(who)："
            }
            out += draft.text
            last = PCLine(id: -1, track: draft.track, who: who, start: start, end: start, text: draft.text)
        }
        return out
    }

    var isEmpty: Bool { !lines.contains { !$0.text.isEmpty } && drafts.isEmpty }

    /// 講者（出現順序，沒有重複、沒有空的）。
    var speakers: [String] {
        var seen: [String] = []
        for line in lines where !line.who.isEmpty && !seen.contains(line.who) {
            seen.append(line.who)
        }
        return seen
    }

    /// 錄音多長：最後一句結束在第幾秒。
    var seconds: Double { lines.map(\.end).max() ?? 0 }

    /// 電腦錄完（定稿或分好人）、手機收到整份、有字，才能存成手機上的一場。
    var canSave: Bool {
        received && rec == .idle && (stage == "final" || stage == "labelled") && stamp != nil && lines.contains { !$0.text.isEmpty }
    }

    /// 電腦的錄音資料夾名 2026-11-08_153000 → App 錄音檔名的格式 20261108-153000（標題、課表都照這個算）。
    var stamp: String? { Self.stamp(fromSession: session) }

    static func stamp(fromSession value: String?) -> String? {
        guard let value, value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$", options: .regularExpression) != nil else {
            return nil
        }
        let c = Array(value)
        return String(c[0..<4]) + String(c[5..<7]) + String(c[8..<10]) + "-" + String(c[11..<17])
    }

    /// 存成一場時寫進稿頭：講者怎麼來的。
    var speakerHow: String? {
        guard !speakers.isEmpty else { return nil }
        if stage == "labelled" {
            return "電腦版按結束後依聲音分的，可能分錯；名字是電腦上取的"
        }
        return "兩條軌分開錄：「我」是電腦麥克風，另一軌是「對方」，不用猜"
    }

    /// 存成一場時寫進稿頭「來源」。
    var originNote: String {
        var note = "電腦版「兩人對談轉文字」連電腦時傳到手機的稿（\(stage == "labelled" ? "分好人" : "定稿")，\(lines.count) 句）；聲音在電腦，手機沒有錄音"
        if omitted > 0 {
            note += "；最前面 \(omitted) 句太長沒傳到手機，完整的在電腦的對談稿"
        }
        return note
    }
}

// MARK: v0.17 叫 Claude 的對話（協定 v4 第 7 節，電腦版 v5.29 起）
// 起因：錄音中喊「Hey Claude」問的問題，手機這邊看不到回答。

/// 電腦傳來的一則對話：他打字（me）、喊 Hey Claude（heard）、Claude 的回覆（claude）。
struct PCChatItem: Equatable, Identifiable {
    let id: Int
    let role: String
    var text: String
    /// 錄音開始後第幾秒；沒在錄音時是 nil。
    let start: Double?
    let stamp: String
    let heard: Bool
    let toClaude: Bool
    /// 交給 Claude 的那則：當時 Claude 那邊連著沒（false＝工作視窗沒開，訊息先留著）。
    let connected: Bool?
    let model: String?
    let carry: String?

    static let roles: Set<String> = ["me", "heard", "claude"]

    init(id: Int, role: String, text: String, start: Double? = nil, stamp: String = "", heard: Bool = false, toClaude: Bool = false,
         connected: Bool? = nil, model: String? = nil, carry: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.start = start
        self.stamp = stamp
        self.heard = heard
        self.toClaude = toClaude
        self.connected = connected
        self.model = model
        self.carry = carry
    }

    /// 看不懂的 role、id 不是數字：略過（回 nil）。
    init?(_ value: Any?) {
        guard let object = value as? [String: Any], let id = LinkJSON.int(object["id"]),
              let role = object["role"] as? String, PCChatItem.roles.contains(role) else { return nil }
        self.init(
            id: id, role: role, text: String((object["text"] as? String ?? "").prefix(8000)),
            start: LinkJSON.double(object["start"]), stamp: object["stamp"] as? String ?? "",
            heard: (object["heard"] as? Bool) ?? false, toClaude: (object["to_claude"] as? Bool) ?? false,
            connected: object["connected"] as? Bool, model: object["model"] as? String, carry: object["carry"] as? String
        )
    }

    var isClaude: Bool { role == "claude" }

    /// 模型 id → 畫面上的名字（跟電腦網頁一樣）。工作視窗回的沒有模型。
    var modelLabel: String? {
        guard let model, !model.isEmpty else { return nil }
        let names = ["claude-haiku-5-5": "Haiku 5.5", "claude-sonnet-5-5": "Sonnet 5.5", "claude-opus-5-5": "Opus 5.5", "claude-fable-5-1": "Fable 5.1"]
        return names[model] ?? model
    }

    /// 泡泡上方的小字：叫 Claude 的時間；回覆的模型和帶了多少稿。
    var caption: String {
        var parts: [String] = []
        if isClaude {
            if let label = modelLabel { parts.append(label) } else { parts.append("工作視窗") }
            if let carry, !carry.isEmpty { parts.append("帶稿：\(carry)") }
        } else {
            parts.append(role == "heard" ? "叫 Claude" : (toClaude ? "打字問 Claude" : "打字"))
            if !stamp.isEmpty { parts.append(stamp) }
            if toClaude, connected == false { parts.append("Claude 還沒連線，訊息先留著") }
        }
        return parts.joined(separator: " · ")
    }
}

/// 電腦送來跟叫 Claude 有關的訊息（協定第 7 節）。
enum PCChatMessage: Equatable {
    case all(items: [PCChatItem], thinking: Int?, omitted: Int)
    case add(PCChatItem)
    case text(id: Int, text: String)
    case think(id: Int, on: Bool, route: String?)
    case fail(id: Int, message: String)

    static func parse(type: String, _ object: [String: Any]) -> PCChatMessage? {
        switch type {
        case "chat_all":
            let items = (object["items"] as? [Any] ?? []).compactMap { PCChatItem($0) }
            return .all(items: items, thinking: LinkJSON.int(object["thinking"]), omitted: LinkJSON.int(object["omitted"]) ?? 0)
        case "chat_add":
            guard let item = PCChatItem(object["item"]) else { return nil }
            return .add(item)
        case "chat_text":
            guard let id = LinkJSON.int(object["id"]) else { return nil }
            return .text(id: id, text: String((object["text"] as? String ?? "").prefix(8000)))
        case "chat_think":
            guard let id = LinkJSON.int(object["id"]) else { return nil }
            return .think(id: id, on: (object["on"] as? Bool) ?? false, route: object["route"] as? String)
        case "chat_fail":
            guard let id = LinkJSON.int(object["id"]) else { return nil }
            return .fail(id: id, message: String((object["message"] as? String ?? "").prefix(300)))
        default:
            return nil
        }
    }
}

/// 手機這邊的叫 Claude 對話：chat_all 整份換掉（重連也是）、chat_add 同一個 id 換掉不然加在最後、chat_text 換字、
/// chat_think 正在想（收到 Claude 的回覆也算想完）、chat_fail 記在那則下面。手機只收不改。
struct PCChat: Equatable {
    /// nil＝還沒收到 welcome；false＝電腦是舊版（v5.28 以前），不會送 Claude 的回覆。
    var supported: Bool?
    private(set) var received = false
    private(set) var items: [PCChatItem] = []
    /// 正在想的那則 id。
    private(set) var thinking: Int?
    /// chat（軟體內聊天模型）或 window（工作視窗）。
    private(set) var thinkingRoute: String?
    private(set) var fails: [Int: String] = [:]
    private(set) var omitted = 0
    /// 新回覆來了幾次（chat_add 來一則沒看過的 Claude 回覆就加 1；重連的整份不算）。畫面靠它浮出最新一則、念出來。
    private(set) var newReplies = 0
    private(set) var lastNewReply: PCChatItem?

    /// 手機最多留幾則（電腦連上時送最近 50 則，連著久了會累積）。
    static let keep = 200

    /// welcome 的版本 → 電腦會不會送對話（協定 v4 起）。
    static func supported(version: Int, chat: Bool) -> Bool { version >= 4 && chat }

    mutating func apply(_ message: PCChatMessage) {
        switch message {
        case .all(let all, let think, let cut):
            received = true
            items = all
            thinking = think
            thinkingRoute = nil
            omitted = cut
            let ids = Set(all.map(\.id))
            fails = fails.filter { ids.contains($0.key) }
        case .add(let item):
            received = true
            let isNew = !items.contains { $0.id == item.id }
            if let at = items.firstIndex(where: { $0.id == item.id }) {
                items[at] = item
            } else {
                items.append(item)
                if items.count > PCChat.keep {
                    let cut = items.count - PCChat.keep
                    items.removeFirst(cut)
                    omitted += cut
                }
            }
            if item.isClaude {
                thinking = nil
                thinkingRoute = nil
                if isNew && !item.text.isEmpty {
                    newReplies += 1
                    lastNewReply = item
                }
            }
        case .text(let id, let text):
            if let at = items.firstIndex(where: { $0.id == id }) {
                items[at].text = text
            }
        case .think(let id, let on, let route):
            if on {
                thinking = id
                thinkingRoute = route
            } else if thinking == id {
                thinking = nil
                thinkingRoute = nil
            }
        case .fail(let id, let message):
            fails[id] = message
            if thinking == id {
                thinking = nil
                thinkingRoute = nil
            }
        }
    }

    var latest: PCChatItem? { items.last }

    /// 最新一則 Claude 的回覆。
    var latestReply: PCChatItem? { items.last { $0.isClaude } }

    /// 底部那一條要顯示的一句：正在想、最新一則（回覆直接寫；他問的寫「你：」）、還沒叫過。
    var preview: String {
        if let last = latest {
            let text = last.text.replacingOccurrences(of: "\n", with: " ")
            if let fail = fails[last.id] { return "沒回成：\(fail)" }
            return last.isClaude ? text : "你：\(text)"
        }
        return "還沒叫 Claude。錄音中喊「Hey Claude」或在電腦打 @claude，回覆會出現在這裡"
    }

    var thinkingText: String { thinkingRoute == "window" ? "工作視窗在想…" : "Claude 正在想…" }
}

// MARK: v0.17 念 Claude 的回覆（跟電腦版網頁手機頁 phonespeak.js 一樣的清理）
// v0.18：聲音預設「跟系統一樣」（iPhone「設定 > 輔助使用 > 朗讀內容」選的聲音和速度），不再寫死美佳；選單可改成手機上任一個中文聲音。

enum LinkSpeech {
    static let maxChars = 400

    /// 網址、路徑、Markdown 符號不念；太長只念前面（念到一句結尾），後面請看畫面。
    static func clean(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: #"https?://\S+|www\.\S+"#, with: "（連結看畫面）", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[A-Za-z]:\\[^\s，。、；：）)」]+"#, with: "（路徑看畫面）", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s*(?:[-•‧]|\d+[.)、])\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[*_`#>|~]+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(t)
        guard chars.count > maxChars else { return t }
        let enders: Set<Character> = ["。", "！", "？", "!", "?", "；"]
        let head = chars.prefix(maxChars)
        let cut = head.lastIndex { enders.contains($0) } ?? -1
        let keep = cut > maxChars / 3 ? cut + 1 : maxChars
        return String(chars.prefix(keep)) + "後面請看畫面。"
    }

    /// 估要念幾秒（中文約每秒 4 字）：告訴電腦這段時間的聲音別寫進稿。念完會再送一則 playing=false。
    static func seconds(for text: String) -> Double {
        min(180, Double(text.count) / 4 + 1)
    }
}

// MARK: v0.18 念回覆用哪個聲音（不寫死某個聲音；預設跟系統設定一樣）

/// 手機上的一個中文聲音（從 AVSpeechSynthesisVoice 抄出來；這裡不用 AVFoundation，shape_check 才測得到）。
struct LinkVoiceOption: Equatable, Identifiable {
    let id: String
    let name: String
    let language: String
    /// 加強版或高品質版（要另外下載的那種）。
    let enhanced: Bool

    var label: String {
        name + (enhanced ? "（加強版）" : "") + "・" + LinkVoiceChoice.place(language)
    }
}

enum LinkVoiceChoice {
    /// UserDefaults 的鍵；存空字串或沒存＝跟系統一樣。
    static let defaultsKey = "linkSpeakVoice"
    static let systemLabel = "跟系統一樣（預設）"

    static func place(_ language: String) -> String {
        switch language {
        case "zh-TW": return "台灣"
        case "zh-HK": return "香港"
        case "zh-CN": return "中國大陸"
        default: return language
        }
    }

    /// 選單列的聲音：只留中文，台灣、香港、中國大陸、其他依序，同地區照名字；同一個 id 只留一次。
    static func menu(_ all: [LinkVoiceOption]) -> [LinkVoiceOption] {
        let order = ["zh-TW": 0, "zh-HK": 1, "zh-CN": 2]
        var seen = Set<String>()
        var picked: [LinkVoiceOption] = []
        for v in all where v.language.hasPrefix("zh") {
            if seen.insert(v.id).inserted {
                picked.append(v)
            }
        }
        return picked.sorted { a, b in
            let oa = order[a.language] ?? 3
            let ob = order[b.language] ?? 3
            if oa != ob { return oa < ob }
            if a.name != b.name { return a.name < b.name }
            return a.enhanced && !b.enhanced
        }
    }

    /// 存的那個聲音還在手機上就用它；沒存、空的、或已經被刪掉 → nil＝跟系統一樣。
    static func pick(saved: String?, from all: [LinkVoiceOption]) -> LinkVoiceOption? {
        guard let saved, !saved.isEmpty else { return nil }
        return all.first { $0.id == saved }
    }

    /// 畫面上那句：現在用哪個聲音。
    static func note(saved: String?, from all: [LinkVoiceOption]) -> String {
        if let v = pick(saved: saved, from: all) {
            return "用 \(v.label) 念"
        }
        let system = "聲音和速度跟 iPhone「設定 > 輔助使用 > 朗讀內容」一樣；那裡選的若是 Siri 的聲音，Apple 可能不讓 App 用，iPhone 會自己換一個中文聲音"
        if let saved, !saved.isEmpty {
            return "之前選的聲音不在這支手機上了，改用跟系統一樣：" + system
        }
        return system
    }
}

// MARK: v0.19 開口就停（協定 v5，電腦版 v5.33）

/// 念一則時告訴電腦：要開口就停，這則的編號和念的字（電腦拿字比對：辨識出的字不在回覆裡＝他在講話）。
struct LinkBarge: Equatable {
    static let maxChars = 2000
    let id: Int
    let text: String
}

enum LinkBargeRule {
    /// UserDefaults 的鍵；沒存＝開（預設開）。
    static let defaultsKey = "linkStopOnVoice"

    static func enabled(saved: Any?) -> Bool {
        (saved as? Bool) ?? true
    }

    /// 電腦說停：開關開著、正在念、而且是同一則（上一則的停晚到，不能停到下一則）才停。
    static func shouldStop(enabled: Bool, speakingID: Int?, stopID: Int?) -> Bool {
        guard enabled, let speakingID else { return false }
        return stopID == nil || stopID == speakingID
    }

    /// 開關下面那行小字。
    static func caption(pcVersion: Int, enabled: Bool) -> String {
        if pcVersion > 0 && pcVersion < 5 {
            return "電腦版要 v5.33 以上才會開口就停；現在的電腦不會叫手機停"
        }
        if !enabled {
            return "關著：每則念完才停；要停就關掉「念出新回覆」"
        }
        return "念的時候你一說話就停。電腦用它的麥克風判斷（比喇叭聲大很多，或聽到的字不在回覆裡），電腦在錄音時才聽得到你"
    }
}

// MARK: v0.17 連不上時照網路種類講（手機在 4G 時，原本只寫「要在同一個 Wi-Fi」，沒直接說是在用 4G）

enum LinkNetwork: String, Equatable {
    case unknown
    case wifi
    case wired
    /// 只有行動網路（4G／5G），沒連 Wi-Fi。
    case cellular
    /// 沒有網路。
    case none
    case other
}

enum LinkHint {
    /// 連不上時最前面寫的那一句；Wi-Fi、有線、還不知道就不寫（照原本的提示）。
    static func network(_ kind: LinkNetwork) -> String? {
        switch kind {
        case .cellular:
            return "手機現在用 4G／行動網路，沒連 Wi-Fi：請連跟電腦同一個 Wi-Fi，或開個人熱點讓電腦連（已經開熱點的話，確認電腦連的是這支手機的熱點）"
        case .none:
            return "手機現在沒有網路（沒連 Wi-Fi）：請連跟電腦同一個 Wi-Fi，或開個人熱點讓電腦連"
        default:
            return nil
        }
    }

    /// 斷線／連不上的那句（LinkCore 給的，後面可能帶「（手機和電腦要在同一個 Wi-Fi…）」）：
    /// 在行動網路／沒網路時拿掉通用提示，原因由畫面上 `network` 那一句直接講（跟著網路即時換，連上 Wi-Fi 就不寫了）。
    static func lostNote(_ why: String, network kind: LinkNetwork) -> String {
        guard network(kind) != nil, let open = why.firstIndex(of: "（") else { return why }
        return String(why[..<open])
    }
}
