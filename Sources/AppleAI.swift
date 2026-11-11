import Foundation
import FoundationModels

/// 手機排版可以用 Apple 的裝置上模型（Foundation Models）。官方文件沒查到明確支援繁中，所以先把這台裝置的實況顯示出來。
/// 只分段，不准改字：回來的字和原文不同就丟掉，保留原文。模型一次只吃約 4096 token（第三方資料），所以切小塊。
enum AppleAI {
    static let chunkCharacters = 900
    /// 11/07 真機：校正卡在 50% 很久，就是第二塊一直沒回。一塊 900 字正常約 5 秒，等這麼久就算這塊失敗，繼續下一塊。
    static let chunkLimitSeconds = 45.0

    enum AskError: LocalizedError {
        case timedOut

        var errorDescription: String? { "這一塊 45 秒沒回應" }
    }

    /// 模型卡住時可能連取消都不理，所以不等它結束，時間一到就往下走。
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var onCancel: (() -> Void)?

        func fire(_ block: () -> Void) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { block() }
        }

        func setCancel(_ block: @escaping () -> Void) {
            lock.lock()
            onCancel = block
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            let block = onCancel
            lock.unlock()
            block?()
        }
    }

    private static func ask(_ instructions: String, _ part: String) async throws -> String {
        let once = Once()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let worker = Task {
                    do {
                        let session = LanguageModelSession(instructions: instructions)
                        let answer = try await session.respond(to: part).content
                        once.fire { continuation.resume(returning: answer) }
                    } catch {
                        once.fire { continuation.resume(throwing: error) }
                    }
                }
                Task {
                    try? await Task.sleep(for: .seconds(chunkLimitSeconds))
                    once.fire {
                        worker.cancel()
                        continuation.resume(throwing: AskError.timedOut)
                    }
                }
                once.setCancel {
                    once.fire {
                        worker.cancel()
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
        } onCancel: {
            once.cancel()
        }
    }

    static var statusLine: String {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            let chinese = model.supportedLanguages
                .filter { $0.languageCode?.identifier == "zh" }
                .map(\.maximalIdentifier)
                .sorted()
            return "蘋果 AI：可用；中文：\(chinese.isEmpty ? "清單沒有" : chinese.joined(separator: "、"))"
        case .unavailable(let reason):
            return "蘋果 AI：不可用（\(String(describing: reason))）"
        }
    }

    struct Outcome {
        let text: String
        let succeeded: Int
        let changedWords: Int
        let failed: Int
        let firstError: String?
    }

    static func chunks(of text: String) -> [String] {
        TextBlocks.split(text, limit: chunkCharacters).map(\.text)
    }

    struct FixOutcome {
        /// 每塊自己的建議，只標在那一塊。
        let hints: [BlockHints]
        let succeeded: Int
        let failed: Int
        /// v0.15：他按 ✕ 或停止造成的取消，不算失敗、不記英文錯誤句（真機 0.14.17 記成「失敗 1 塊；Swift.CancellationError」）。
        var cancelled = false
        let firstError: String?
    }

    /// 取消（使用者按 ✕／停止）不是失敗。
    static func isCancel(_ error: Error) -> Bool {
        error is CancellationError || Task.isCancelled
    }

    /// 離線校正：全程在裝置上，不上網。
    /// 校正只標註：模型只回可能的錯字，程式在字後面加〔…？〕，稿不改。準不準要真機看；失敗就留原稿並講原因。
    static func corrections(
        of text: String,
        progress: @escaping @MainActor (Double) -> Void
    ) async -> FixOutcome {
        let parts = TextBlocks.split(text, limit: chunkCharacters)
        var hints: [BlockHints] = []
        var succeeded = 0, failed = 0
        var cancelled = false
        var firstError: String?
        for (index, part) in parts.enumerated() {
            if Task.isCancelled {
                cancelled = true
                break
            }
            await progress(Double(index) / Double(max(parts.count, 1)))
            do {
                let instructions = """
                    你只負責找出繁體中文語音辨識稿裡的同音錯字。不確定就不要列。
                    不准改寫句子、不准潤飾、不准補標點。私人姓名不要動。
                    只輸出 JSON：{"edits":[{"wrong":"稿裡一字不差的片段","right":"正確寫法"}]}
                    """
                let answer = try await ask(instructions, part.text)
                let edits = TextFixer.clean(TextFixer.parse(answer), in: part.text)
                if !edits.isEmpty {
                    hints.append(BlockHints(lines: part.lines, edits: edits))
                }
                succeeded += 1
            } catch {
                if isCancel(error) {
                    cancelled = true
                    break
                }
                failed += 1
                if firstError == nil {
                    firstError = error.localizedDescription
                }
            }
        }
        return FixOutcome(hints: hints, succeeded: succeeded, failed: failed, cancelled: cancelled, firstError: firstError)
    }

    /// 智慧校正第一步：手機上的模型挑可能聽錯的專有名詞。私人姓名叫它不要挑，因為這些詞等下要拿去查維基。
    static func pickTerms(
        of text: String,
        progress: @escaping @MainActor (Double) -> Void
    ) async -> (picks: [TermPick], failed: Int, cancelled: Bool, firstError: String?) {
        let parts = chunks(of: text)
        var raw: [TermPick] = []
        var failed = 0
        var cancelled = false
        var firstError: String?
        for (index, part) in parts.enumerated() {
            if Task.isCancelled {
                cancelled = true
                break
            }
            await progress(Double(index) / Double(max(parts.count, 1)))
            do {
                let instructions = """
                    你只負責從繁體中文語音辨識稿挑出可能被聽錯的專有名詞或學術用語（人名、機構、法令、書刊、學科、歷史事件）。
                    只挑歷史人物、已出版作者、機構、書刊這類公開對象。現任老師、同學、朋友、家人的姓名一律不挑。
                    一般口語錯字不要挑。guess 是你猜的正確寫法，沒把握就不要列。
                    只輸出 JSON：{"groups":[{"written":["稿裡一字不差的寫法"],"guess":"正確寫法"}]}
                    """
                raw += TermCheck.parse(try await ask(instructions, part))
            } catch {
                if isCancel(error) {
                    cancelled = true
                    break
                }
                failed += 1
                if firstError == nil {
                    firstError = error.localizedDescription
                }
            }
        }
        return (TermCheck.clean(raw, in: text), failed, cancelled, firstError)
    }

    private static func squeeze(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// 取消時保留已完成的部分。
    static func paragraphs(
        of text: String,
        progress: @escaping @MainActor (Double) -> Void
    ) async -> Outcome {
        let parts = chunks(of: text)
        var output: [String] = []
        var succeeded = 0, changedWords = 0, failed = 0
        var firstError: String?
        for (index, part) in parts.enumerated() {
            if Task.isCancelled {
                output.append(part)
                continue
            }
            await progress(Double(index) / Double(max(parts.count, 1)))
            do {
                let instructions = """
                    你只負責替語音辨識稿分段。在話題改變的地方空一行。
                    一個字都不准改、不准刪、不准補，連錯字和標點都照抄。只輸出稿子本身。
                    """
                let answer = try await ask(instructions, part)
                if squeeze(answer) == squeeze(part) {
                    output.append(answer.trimmingCharacters(in: .whitespacesAndNewlines))
                    succeeded += 1
                } else {
                    output.append(part.trimmingCharacters(in: .whitespacesAndNewlines))
                    changedWords += 1
                }
            } catch {
                output.append(part.trimmingCharacters(in: .whitespacesAndNewlines))
                if isCancel(error) {
                    continue      // 取消：這塊留原文，不算失敗
                }
                failed += 1
                if firstError == nil {
                    firstError = error.localizedDescription
                }
            }
        }
        return Outcome(
            text: output.joined(separator: "\n\n") + "\n",
            succeeded: succeeded,
            changedWords: changedWords,
            failed: failed,
            firstError: firstError
        )
    }
}
