import Foundation
import os

/// 全部放 App 自己的 Documents，看得到也刪得掉（檔案 > 我的 iPhone > 轉文字），
/// 而且標成不進 iCloud 備份：聲音和文字不離開手機。App 不會自己刪錄音和逐字稿。
enum Store {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    static func folder(_ name: String) -> URL {
        var url = documents.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    static var recordings: URL { folder("錄音") }
    static var transcripts: URL { folder("逐字稿") }

    /// v0.14：照課表命名的場放進以課名命名的子資料夾（錄音、逐字稿兩邊都有），檔案 App 裡一科一個資料夾。沒有課名就放原本的地方。
    static func recordingsFolder(course: String?) -> URL {
        guard let course, !course.isEmpty else { return recordings }
        return folder("錄音/" + CourseSchedule.folderName(course))
    }

    static func transcriptsFolder(course: String?) -> URL {
        guard let course, !course.isEmpty else { return transcripts }
        return folder("逐字稿/" + CourseSchedule.folderName(course))
    }
    private static var lastRunFile: URL { transcripts.appendingPathComponent(".最近一次.json") }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// 選來的檔先複製進暫存再轉；雲端硬碟裡的檔由 NSFileCoordinator 先抓下來。
    /// 不要放 MainActor 跑。
    static func copyToTemporary(_ source: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped { source.stopAccessingSecurityScopedResource() }
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                try FileManager.default.copyItem(at: readable, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        return destination
    }

    /// 修過字的稿是主檔；引擎原本的字和每段時間另存，修錯時對得回去，之後分人也要用。
    /// updateLast 是 false 時只寫這份自己的檔，不動「最近一次」：定稿跑到一半不能蓋掉完整的即時稿。
    static func saveTranscript(_ run: SavedRun, pieces: [TimedPiece] = [], updateLast: Bool = true) {
        try? run.document.write(to: file(of: run, ".txt"), atomically: true, encoding: .utf8)
        if !pieces.isEmpty {
            try? pieces.map(\.text).joined().write(to: file(of: run, " 原文.txt"), atomically: true, encoding: .utf8)
            let times = file(of: run, " 時間.json")
            if let data = try? JSONEncoder().encode(pieces) {
                try? data.write(to: times, options: .atomic)
            }
        }
        if updateLast, let data = try? JSONEncoder().encode(run) {
            try? data.write(to: lastRunFile, options: .atomic)
        }
    }

    /// v0.23.1：按停止當下畫面上的即時稿另存（「… 即時稿.txt」純文字、「… 即時時間.json」每段 text/start/end）。
    /// 定稿會重轉一次、字不一樣，之後的改字（0.23.2 起）是照即時稿改的，要留著對答案。
    /// part 是續錄第幾段（2 起）：用「——第N段即時稿——」接在原本的即時稿後面，時間也接在後面；nil 是新的一場，整份寫。
    static func saveLive(_ run: SavedRun, text: String, pieces: [TimedPiece], part: Int?) {
        let textURL = file(of: run, " 即時稿.txt")
        let timesURL = file(of: run, " 即時時間.json")
        var fullText = text
        var allPieces = pieces
        if let part {
            let earlier = (try? String(contentsOf: textURL, encoding: .utf8)) ?? ""
            let divider = "——第\(part)段即時稿——"
            fullText = earlier.isEmpty ? "\(divider)\n\n\(text)" : "\(earlier)\n\n\(divider)\n\n\(text)"
            if let data = try? Data(contentsOf: timesURL),
               let before = try? JSONDecoder().decode([TimedPiece].self, from: data) {
                allPieces = before + pieces
            }
        }
        try? fullText.write(to: textURL, atomically: true, encoding: .utf8)
        if let data = try? JSONEncoder().encode(allPieces) {
            try? data.write(to: timesURL, options: .atomic)
        }
    }

    /// v0.23.1：新的一場的定稿是另一個 SavedRun（開始時間不同、檔名不同），即時稿兩個檔複製一份給定稿那場，匯出定稿才帶得到。
    /// 同一個檔（續錄、定稿沒跑完退回即時稿）就不用。
    static func copyLive(from live: SavedRun, to final: SavedRun) {
        let manager = FileManager.default
        for suffix in [" 即時稿.txt", " 即時時間.json"] {
            let source = file(of: live, suffix)
            let target = file(of: final, suffix)
            guard source != target, manager.fileExists(atPath: source.path) else { continue }
            try? manager.removeItem(at: target)
            try? manager.copyItem(at: source, to: target)
        }
    }

    /// v0.23.2：錄音中 Haiku 改字紀錄（ReviewLog）。錄音中每批之後寫在即時那場；停止後補完定稿命中，再寫一份在最後那場。
    static func reviewFile(of run: SavedRun) -> URL {
        file(of: run, " 改字.json")
    }

    static func encodeReview(_ review: ReviewLog) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(review)
    }

    static func saveReview(_ review: ReviewLog, of run: SavedRun) {
        if let data = encodeReview(review) {
            try? data.write(to: reviewFile(of: run), options: .atomic)
        }
    }

    static func loadReview(of run: SavedRun) -> ReviewLog? {
        guard let data = try? Data(contentsOf: reviewFile(of: run)) else { return nil }
        return try? JSONDecoder().decode(ReviewLog.self, from: data)
    }

    /// v0.26.0 即時模式 1：每批一張卡（「… 卡片.json」；raw、expanded 是稿的字，只存在這個檔）
    static func cardsFile(of run: SavedRun) -> URL {
        file(of: run, " 卡片.json")
    }

    static func encodeCards(_ cards: [LiveCard]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(cards)
    }

    static func saveCards(_ cards: [LiveCard], of run: SavedRun) {
        if let data = encodeCards(cards) {
            try? data.write(to: cardsFile(of: run), options: .atomic)
        }
    }

    static func loadCards(of run: SavedRun) -> [LiveCard] {
        guard let data = try? Data(contentsOf: cardsFile(of: run)) else { return [] }
        return (try? JSONDecoder().decode([LiveCard].self, from: data)) ?? []
    }

    /// 分人的原始結果另存，之後校準或改人用。
    static func saveTurns(_ run: SavedRun, turns: [SpeakerTurn]) {
        if let data = try? JSONEncoder().encode(turns) {
            try? data.write(to: file(of: run, " 分人.json"), options: .atomic)
        }
    }

    /// 這一場的檔：「開始轉的時間 來源檔名」＋後綴。續錄沿用同一個名字，所以還是同一份稿。
    /// v0.14 起照課表命名的場在課名子資料夾裡；檔名不變（改標題也不改檔名）。
    static func file(of run: SavedRun, _ suffix: String) -> URL {
        let name = (run.source as NSString).deletingPathExtension
        return transcriptsFolder(course: run.course).appendingPathComponent("\(run.startedStamp) \(name)\(suffix)")
    }

    /// v0.14：點兩下或 Pencil 標的句子，每場一個「標記.json」。
    static func loadMarks(of run: SavedRun) -> [SentenceMark] {
        guard let data = try? Data(contentsOf: file(of: run, " 標記.json")) else { return [] }
        return (try? JSONDecoder().decode([SentenceMark].self, from: data)) ?? []
    }

    static func saveMarks(_ marks: [SentenceMark], of run: SavedRun) {
        let url = file(of: run, " 標記.json")
        guard !marks.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(marks) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func loadPieces(of run: SavedRun) -> [TimedPiece] {
        guard let data = try? Data(contentsOf: file(of: run, " 時間.json")) else { return [] }
        return (try? JSONDecoder().decode([TimedPiece].self, from: data)) ?? []
    }

    static func loadTurns(of run: SavedRun) -> [SpeakerTurn] {
        guard let data = try? Data(contentsOf: file(of: run, " 分人.json")) else { return [] }
        return (try? JSONDecoder().decode([SpeakerTurn].self, from: data)) ?? []
    }

    /// 續錄那段另存：「原錄音檔名 第2段.caf」。同名的檔已經在（上次續錄沒開成）就加上時間，不蓋掉。
    static func partFile(for run: SavedRun, part: Int) -> URL {
        let name = (run.source as NSString).deletingPathExtension
        let folder = recordingsFolder(course: run.course)
        let url = folder.appendingPathComponent("\(name) 第\(part)段.caf")
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        return folder.appendingPathComponent("\(name) 第\(part)段 \(timestamp()).caf")
    }

    /// 這一場在 App 裡的錄音（選來的原檔轉完就刪了，不在這裡）。
    static func audioFiles(of run: SavedRun) -> [URL] {
        playbackFiles(of: run).map { $0.url }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 播放用：每段錄音和它在整場的開頭秒數（v0.14 起才存；沒存是 nil，播放時用前面幾段的長度加起來）。
    static func playbackFiles(of run: SavedRun) -> [(url: URL, start: Double?)] {
        let names = run.parts ?? [run.source]
        let folder = recordingsFolder(course: run.course)
        let starts: [Double]? = run.partStarts.flatMap { $0.count == names.count ? $0 : nil }
        return names.enumerated().map { index, name -> (url: URL, start: Double?) in
            (folder.appendingPathComponent(name), starts?[index])
        }
    }

    static func megabytes(of urls: [URL]) -> Int {
        let bytes = urls.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return Int((Double(bytes) / 1_048_576).rounded())
    }

    /// 收起這一場：只是下次開 App 不再自動打開，檔案都還在。
    static func forgetLastRun() {
        try? FileManager.default.removeItem(at: lastRunFile)
    }

    static func clock() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    // MARK: 匯出

    enum ExportKind: Sendable {
        /// classRecord：v0.21「存成原始轉錄」，一個 txt（原始轉錄格式）
        case session, withAudio, errorsOnly, classRecord
    }

    /// 校正紀錄另存一份給程式讀（稿尾已經有一份給人讀）。
    private struct Corrections: Encodable {
        let hints: [TextEdit]?
        let notes: [TermNote]?
        let edits: [TextEdit]?
        let fixInfo: String?
    }

    /// 長按匯出。檔案先放進暫存的一個資料夾，再請系統壓成一個 zip：
    /// NSFileCoordinator 用 forUploading 讀資料夾時會交出壓好的 zip（系統內建，不用加套件）；那份 zip 離開區塊就會被刪，所以先搬出來。
    /// zip 裡的檔名用英文：iPhone、Mac 壓的 zip 中文檔名到 Windows 常變亂碼。
    /// v0.21 匯出檔名照原始轉錄的規則：YYYYMMDD_<正式課名>_App匯出_HHMM.zip（HHMM＝錄音開始），錯誤資料、原始轉錄同一套（ClassRecord）。
    /// 只傳錯誤資料、存成原始轉錄都是一個 .txt，不用解壓。不要放 MainActor 跑（含錄音時要處理上百 MB）。
    /// engine：原始轉錄區塊第一行的「引擎」（例：iPhone 轉文字 0.21.24），只有 classRecord 用。
    /// scratch：暫存資料夾名。v0.23.2 自動上傳用「自動上傳」，和手動匯出的「匯出」分開，兩邊同時打包不會互刪。
    static func makeExport(_ kind: ExportKind, run: SavedRun?, report: String, stamp: String, engine: String = "", scratch: String = "匯出") throws -> URL {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(scratch, isDirectory: true)
        try? manager.removeItem(at: root)   // 上一次匯出的暫存
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        if kind == .classRecord, let run {
            let file = root.appendingPathComponent(ClassRecord.rawFileName(stamp: stamp, course: run.course))
            try run.rawTranscript(engine: engine).write(to: file, atomically: true, encoding: .utf8)
            return file
        }

        guard kind != .errorsOnly, kind != .classRecord, let run else {
            let file = root.appendingPathComponent(ClassRecord.exportFileName(.errors, stamp: stamp, course: run?.course))
            try report.write(to: file, atomically: true, encoding: .utf8)
            return file
        }

        let folder = root.appendingPathComponent("LectureText-\(stamp)", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var listing = [
            "轉文字 匯出 \(stamp)",
            "transcript.txt  逐字稿（含稿頭，和複製全文一樣；即時模式 1 是各卡的擴寫式校正接起來，原字在 raw.txt）",
        ]
        try run.document.write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        let copies = [
            (" 原文.txt", "raw.txt", "語音引擎原本的字（修字前）"),
            (" 時間.json", "times.json", "每一小段字的開始、結束秒數"),
            (" 分人.json", "speakers.json", "分人模型的原始結果"),
            (" 標記.json", "marks.json", "點兩下或用 Pencil 標記的句子（at＝從稿頭數第幾個非空白字、text＝那句、start＝錄音第幾秒）"),
            // v0.23.1：按停止當下的即時稿（定稿前、錄音中畫面上的黑字；畫面上的即時改字沒套，是原字）
            (" 即時稿.txt", "live.txt", "錄音當下的即時稿（按停止時存的，定稿前的字；續錄的每段用「——第N段即時稿——」分開）"),
            (" 即時時間.json", "live_times.json", "即時稿每一小段字的開始、結束秒數（續錄從第一段開頭算）"),
            // v0.23.2：錄音中 Haiku 改字紀錄
            (" 改字.json", "fixes.json", "錄音中 Haiku 紀錄：每批送了哪些單位、花多少、每條改字的判定與定稿命中、每批判出的投影片頁碼 pages（unitText、context、finalWindow 是稿的字）"),
            // v0.26.0：即時模式 1 每批一張卡
            (" 卡片.json", "cards.json", "即時模式 1 每批一張卡：start、end（錄音秒數）、page（投影片頁碼）、key（一句重點）、tidy（整理版）、unsure（不確定的詞）、raw（送出的 Whisper 原稿）、expanded（Haiku 擴寫式校正的全文，逐字稿就是這些接起來）、costUSD（這張卡花的美元）、state（done／failed＝沒整理到）"),
            // v0.23.5：下課後用 Whisper 在裝置上再轉的一份（開關在星星選單，預設關；轉完才有）
            (WhisperFiles.text, "whisper.txt", "下課後在這台裝置上用 Whisper 再轉的一份（稿頭寫模型、轉多久、濾掉幾處鬼打牆；續錄的每段用分隔行分開）"),
            (WhisperFiles.times, "whisper_times.json", "Whisper 稿每一小段字的開始、結束秒數（格式同 times.json，續錄從第一段開頭算）"),
        ]
        for (suffix, name, meaning) in copies {
            let source = file(of: run, suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            try manager.copyItem(at: source, to: folder.appendingPathComponent(name))
            listing.append("\(name)  \(meaning)")
        }
        // v0.26.0：即時模式 1 的整理版（每張卡的時間、頁碼、重點、整理版、不確定的詞）
        let cards = loadCards(of: run)
        if !cards.isEmpty {
            try CardText.tidyFile(cards).write(to: folder.appendingPathComponent("tidy.txt"), atomically: true, encoding: .utf8)
            listing.append("tidy.txt  整理版：每張卡（約 60 秒）的時間、投影片頁碼、一句重點、整理版、不確定的詞；沒整理到的卡寫「（沒整理到）」")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let corrections = Corrections(hints: run.hints, notes: run.notes, edits: run.edits, fixInfo: run.fixInfo)
        try encoder.encode(corrections).write(to: folder.appendingPathComponent("corrections.json"))
        listing.append("corrections.json  校正紀錄（離線校正提示、智慧校正查維基的結果）")
        try report.write(to: folder.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)
        listing.append("info.txt  版本、裝置、各步耗時、這場的錯誤紀錄（不含稿）")
        // v0.23.2：Haiku 摘要與費用一行（不含稿的字、不含金鑰）
        if let review = loadReview(of: run) {
            listing.append("")
            listing.append(review.summaryLine)
        }

        if kind == .withAudio {
            for (index, audio) in audioFiles(of: run).enumerated() {
                let target = folder.appendingPathComponent("audio-\(index + 1).\(audio.pathExtension)")
                // 同一個磁碟上用硬連結，不多佔空間；不行才複製
                do {
                    try manager.linkItem(at: audio, to: target)
                } catch {
                    try manager.copyItem(at: audio, to: target)
                }
                listing.append("\(target.lastPathComponent)  錄音第 \(index + 1) 段（\(audio.lastPathComponent)）")
            }
        }
        try (listing.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        // v0.21：zip 檔名照原始轉錄的規則（正式課名、錄音開始的日期與時分）
        let zip = root.appendingPathComponent(ClassRecord.exportFileName(kind == .withAudio ? .withAudio : .session, stamp: stamp, course: run.course))
        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordinationError) { zipped in
            do {
                try manager.moveItem(at: zipped, to: zip)
            } catch {
                do {
                    try manager.copyItem(at: zipped, to: zip)
                } catch {
                    moveError = error
                }
            }
        }
        try? manager.removeItem(at: folder)
        if let coordinationError { throw coordinationError }
        if let moveError { throw moveError }
        return zip
    }

    // MARK: v0.23.5 下課後用 Whisper 再轉一份（檔名後綴在 WhisperPlan.swift 的 WhisperFiles）

    /// Documents 底下的子資料夾路徑（和 transcriptsFolder／recordingsFolder 同一套）
    static func subfolder(_ root: String, course: String?) -> String {
        guard let course, !course.isEmpty else { return root }
        return root + "/" + CourseSchedule.folderName(course)
    }

    /// 「逐字稿/課名/開始時間 來源檔名」：加後綴就是 file(of:) 那些檔
    static func whisperStem(of run: SavedRun) -> String {
        let name = (run.source as NSString).deletingPathExtension
        return subfolder("逐字稿", course: run.course) + "/\(run.startedStamp) \(name)"
    }

    static func whisperFile(_ stem: String, _ suffix: String) -> URL {
        documents.appendingPathComponent(stem + suffix)
    }

    /// 這場要轉的錄音（App 自己錄的才有；電腦傳來的稿、選來的檔沒有錄音就 nil）
    static func whisperJob(for run: SavedRun) -> WhisperJob? {
        guard run.origin == nil else { return nil }
        let names = run.parts ?? [run.source]
        let audio = subfolder("錄音", course: run.course)
        let manager = FileManager.default
        guard names.contains(where: { manager.fileExists(atPath: documents.appendingPathComponent(audio + "/" + $0).path) }) else { return nil }
        let starts: [Double]? = run.partStarts.flatMap { $0.count == names.count ? $0 : nil } ?? (names.count == 1 ? [0] : nil)
        return WhisperJob(stem: whisperStem(of: run), audioFolder: audio, parts: names, partStarts: starts,
                          title: run.displayTitle, queued: timestamp())
    }

    /// 全部待辦標記，照檔名（開始時間）舊到新
    static func whisperMarkers() -> [URL] {
        guard let walker = FileManager.default.enumerator(at: transcripts, includingPropertiesForKeys: nil) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker where url.lastPathComponent.hasSuffix(WhisperFiles.pending) {
            found.append(url)
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func loadWhisperJob(_ url: URL) -> WhisperJob? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WhisperJob.self, from: data)
    }

    static func saveWhisperJob(_ job: WhisperJob, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(job) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func loadWhisperRecord(stem: String) -> WhisperRecord? {
        guard let data = try? Data(contentsOf: whisperFile(stem, WhisperFiles.record)) else { return nil }
        return try? JSONDecoder().decode(WhisperRecord.self, from: data)
    }

    static func loadWhisperRecord(of run: SavedRun) -> WhisperRecord? {
        loadWhisperRecord(stem: whisperStem(of: run))
    }

    static func saveWhisperRecord(_ record: WhisperRecord, stem: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = whisperFile(stem, WhisperFiles.record)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(record) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func loadPieces(at url: URL) -> [TimedPiece] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TimedPiece].self, from: data)) ?? []
    }

    static func savePieces(_ pieces: [TimedPiece], to url: URL) {
        if let data = try? JSONEncoder().encode(pieces) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 閃退時程式來不及講話。每一步先寫檔，下次開 App 還在就代表死在那一步。
    /// 順便記剩多少記憶體：分得出是 iOS 因記憶體殺掉，還是程式出錯。
    private static var crumbFile: URL { documents.appendingPathComponent(".最後一步.txt") }

    static func crumb(_ step: String?) {
        guard let step else {
            try? FileManager.default.removeItem(at: crumbFile)
            return
        }
        let left = os_proc_available_memory() / 1_048_576
        try? "\(step)（當時還剩 \(left) MB 可用）".write(to: crumbFile, atomically: true, encoding: .utf8)
    }

    /// 讀了就清掉，同一次閃退只講一次。
    static func takeCrumb() -> String? {
        let text = try? String(contentsOf: crumbFile, encoding: .utf8)
        try? FileManager.default.removeItem(at: crumbFile)
        return text
    }

    static func loadLastRun() -> SavedRun? {
        guard let data = try? Data(contentsOf: lastRunFile) else { return nil }
        return try? JSONDecoder().decode(SavedRun.self, from: data)
    }
}

/// 一次轉換的文字和畫面要顯示的數字。
struct SavedRun: Codable {
    var source: String
    var startedStamp: String
    var engine: String
    var language: String
    var systemVersion: String
    var audioSeconds: Double?
    var convertSeconds: Double?
    var finished: Bool
    var text: String
    /// 分出來的人（A、B…）；nil 表示沒分。
    var speakers: [String]? = nil
    /// 分人花多久或為什麼失敗，顯示在畫面上。
    var speakerInfo: String? = nil
    /// v0.12 以前的舊稿才有：校正直接改了字。新版不再寫這欄。
    var edits: [TextEdit]? = nil
    /// 離線校正的提示：模型覺得可能是同音錯字。字沒改，只在稿裡加〔…？〕。複製時附在稿後，別的 AI 才知道。
    var hints: [TextEdit]? = nil
    var fixInfo: String? = nil
    /// 預熱和第一個字花多久：要靠真機數字判斷即時夠不夠。
    var liveInfo: String? = nil
    /// 智慧校正的查證結果。
    var notes: [TermNote]? = nil
    /// v0.13 起：這一場的錄音檔，續錄過才有第二個以上；nil 表示只有 source 一個。
    var parts: [String]? = nil
    /// v0.13 起：最後一次按停止的時間（yyyyMMdd-HHmmss）。選檔沒有。
    var endedStamp: String? = nil
    /// v0.13 起：轉這場的 App 版本（含 build）。
    var appVersion: String? = nil
    /// v0.13 起：各步做了什麼、花多久、哪裡失敗。不含稿的字，錯誤資料就是從這裡來的。
    var log: [String]? = nil
    /// v0.14 起：照課表對到的課（也是子資料夾名）；nil 是不在上課時段或選來的檔。
    var course: String? = nil
    /// v0.14 起：他自己改的標題；nil 用自動的（課名或時間）。
    var title: String? = nil
    /// v0.14 起：每段錄音在整場的第幾秒開始（和 parts 一一對應），播放時用。
    var partStarts: [Double]? = nil
    /// v0.16 起：電腦傳來的稿（連電腦、協定 v3）才有，寫「從哪裡來」；nil 是手機自己轉的。這種場沒有錄音、不能繼續錄。
    var origin: String? = nil
    /// v0.21 起：每段錄音按下的時間（yyyyMMdd-HHmmss，和 parts 一一對應），原始轉錄每段一個區塊用。舊稿沒有，從各步紀錄找。
    var partStamps: [String]? = nil
    /// v0.27.0 起：錄音時的場景（lecture／discussion／chat，RecordScene）；nil＝舊稿或選來的檔
    var scene: String? = nil

    /// 畫面最上面的標題：改過的 → 「11/10 幾何」（照課表）→ 「11/10 10:20」（App 錄的、不在上課時段）→ 選來的檔用原檔名。
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let stamp = recordedStamp { return CourseSchedule.title(stamp: stamp, course: course) }
        return (source as NSString).deletingPathExtension
    }

    /// App 自己錄的檔，檔名就是按下錄音的時間；選來的檔不知道是什麼時候錄的。
    var recordedStamp: String? {
        let name = (source as NSString).deletingPathExtension
        return name.range(of: "^[0-9]{8}-[0-9]{6}$", options: .regularExpression) != nil ? name : nil
    }

    /// 匯出的檔名用錄音時間；選檔用轉成文字的時間。
    var exportStamp: String { recordedStamp ?? startedStamp }

    /// 複製和存檔用：稿頭＋有時間的稿，格式跟電腦版對談稿一樣，直接丟給 AI 也看得懂。
    var document: String { makeDocument(recordingAt: nil) }

    /// v0.21 錄音中複製：格式和「複製全文」一樣，稿頭寫「錄音中，到 mm:ss」，不寫結束時間。
    func liveDocument(at seconds: Double) -> String { makeDocument(recordingAt: seconds) }

    /// v0.21「存成原始轉錄」：原始轉錄格式，每段錄音一個區塊；原文不含〔…〕標註和續錄分隔行，講者標籤留著。
    /// 時間來源、引擎裡不放「，」「）」：電腦版和別的 AI 照【…開始（時間來源：…，引擎：…）｜…】切欄位。
    func rawTranscript(engine: String) -> String {
        let count = parts?.count ?? 1
        let firstSource: String
        let id: String
        if origin != nil {
            firstSource = "連電腦時電腦開始錄音"
            id = recordedStamp ?? startedStamp
        } else if let stamp = recordedStamp {
            firstSource = "App 錄音"
            id = stamp
        } else {
            firstSource = "選檔轉成文字的時間而非錄音時間"
            id = startedStamp
        }
        let starts = ClassRecord.partStarts(stored: partStamps, first: id, count: count, log: log ?? [])
        let engineLabel = origin != nil ? "電腦版兩人對談轉文字，存於 \(engine)" : engine
        return ClassRecord.rawTranscript(text: text, id: id, starts: starts, partCount: count, engine: engineLabel, firstSource: firstSource)
    }

    private func makeDocument(recordingAt: Double?) -> String {
        let partCount = parts?.count ?? 1
        var head = ["---"]
        var titleLine = "標題：\(displayTitle)"
        if (title ?? "").isEmpty, course != nil {
            titleLine += "（照課表自動命名）"
        }
        head.append(titleLine)
        // v0.12 以前寫的是按停止後開始定稿的時間；應該寫開始錄的時間
        if let start = recordedStamp {
            var line = "日期：\(Self.readableDate(start)) 開始"
            if recordingAt != nil {
                line += "（錄音中）"
            } else if let endedStamp {
                line += "，\(Self.readableEnd(endedStamp, after: start)) 結束"
            }
            if partCount > 1 {
                line += "（中間停過，共 \(partCount) 段）"
            }
            head.append(line)
        } else {
            head.append("日期：\(Self.readableDate(startedStamp))（轉成文字的時間，不是原檔錄的時間）")
        }
        if let recordingAt {
            head.append("時長：\(formatStamp(recordingAt))（複製當下）")
        } else if let audioSeconds {
            head.append("時長：\(formatStamp(audioSeconds))")
        }
        head.append("來源：\(origin ?? source)")
        if let parts, parts.count > 1 {
            head.append("錄音：共 \(parts.count) 段（\(parts.joined(separator: "、"))），字照順序接在一起，時間.json 的秒數從第一段開頭算")
        }
        if origin != nil {
            // v0.16：電腦傳來的稿，講者是電腦版的（分軌的我／對方、分好人後電腦上取的名字）
            if let speakers, !speakers.isEmpty {
                head.append("講者：\(speakers.joined(separator: "、"))（\(speakerInfo ?? "電腦版的講者")）")
            } else {
                head.append("講者：沒有分人")
            }
        } else if let speakers, !speakers.isEmpty {
            var line = "講者：\(speakers.joined(separator: "、"))（手機只看聲音自動分，可能分錯；A、B 是出現順序，不是人名）"
            if partCount > 1 {
                line += "；續錄的每一段各自分人，不同段的 A、B 不一定是同一人"
            }
            head.append(line)
        } else {
            head.append("講者：沒有分人")
        }
        if origin != nil {
            head.append("說明：文字是\(engine)轉的、傳到手機存下來，可能有同音錯字，人名與專有名詞尤其要核對。")
        } else {
            head.append("說明：文字由手機語音辨識（\(engine)，\(language)）產生，可能有同音錯字，人名與專有名詞尤其要核對。")
        }
        if let appVersion {
            head.append("App：轉文字 \(appVersion)，iOS \(systemVersion)")
        }
        if let recordingAt {
            head.append(LiveCopy.statusLine(at: recordingAt))
        } else if !finished {
            head.append("注意：這份沒有轉完，只有已出來的字。")
        }
        head.append("---")
        var tail = ""
        if let edits, !edits.isEmpty {
            tail = "\n\n---\n校正紀錄（手機蘋果 AI 改的，可能改錯；原文另存）\n" + edits.map { "\($0.wrong) → \($0.right)" }.joined(separator: "\n") + "\n"
        }
        if let hints, !hints.isEmpty {
            tail += "\n\n---\n離線校正提示（手機蘋果 AI 覺得可能是同音錯字，字沒有改，〔…？〕裡是它猜的，可能猜錯）\n" + hints.map { "\($0.wrong) → \($0.right)" }.joined(separator: "\n") + "\n"
        }
        if let notes, !notes.isEmpty {
            let label = ["found": "維基有", "judge": "維基有提到", "none": "未確認", "held": "沒送查（像人名，程式擋下）"]
            tail += "\n\n---\n智慧校正（手機蘋果 AI 挑詞、查維基百科；維基有這個詞不代表稿裡講的就是它，字沒有改）\n"
                + notes.map { note in
                    let target = note.right.isEmpty ? "" : " → \(note.right)"
                    let link = note.url.map { "（\($0)）" } ?? ""
                    return "\(label[note.status] ?? note.status)：\(note.written.joined(separator: "、"))\(target)\(link)"
                }.joined(separator: "\n") + "\n"
        }
        return head.joined(separator: "\n") + "\n" + text + tail
    }

    /// 20261107-174500 → 2026-11-07 17:45
    private static func readableDate(_ stamp: String) -> String {
        let c = Array(stamp)
        guard c.count == 15 else { return stamp }
        return "\(String(c[0..<4]))-\(String(c[4..<6]))-\(String(c[6..<8])) \(String(c[9..<11])):\(String(c[11..<13]))"
    }

    /// 同一天只寫時:分，跨天寫全部。
    private static func readableEnd(_ stamp: String, after start: String) -> String {
        let full = readableDate(stamp)
        guard stamp.count == 15, start.count == 15, stamp.prefix(8) == start.prefix(8) else { return full }
        return String(full.suffix(5))
    }
}

/// 版本與裝置：畫面、稿頭、錯誤資料都用這裡。
enum AppInfo {
    /// 例：0.14.15（build 15）。版本號由雲端編譯時寫進去。
    /// 例：0.21.24（原始轉錄的引擎欄用）
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// v0.23 起小版用數字：0.23.1（build 27）。版本號在 build.yml 寫死，build 是雲端編譯的序號。
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short)（build \(build)）"
    }

    /// 型號代碼，例如 iPhone17,3（對照表查得到是哪一款）。
    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static var memoryGB: String {
        String(format: "%.1f GB", Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)
    }
}
