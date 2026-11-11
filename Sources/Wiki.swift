import Foundation

/// 智慧校正：手機上沒有能上網的 Claude，所以查維基百科（免金鑰、免費）。只送詞，不送稿。
/// 11/07 實測：連發約 11 次就回 429（要等 17 秒）。所以先一次查完整批標題，查不到的才一個一個搜，中間隔開；被限流就等它說的秒數，再不行就停。
enum Wiki {
    enum WikiError: LocalizedError {
        case limited
        case bad(Int)

        var errorDescription: String? {
            switch self {
            case .limited: return "維基百科要求暫停（查太多次）"
            case .bad(let code): return "維基百科回 \(code)"
            }
        }
    }

    static let batchSize = 50
    static let searchGap: Duration = .milliseconds(1500)
    static let maxSearches = 15

    private static func get(_ items: [URLQueryItem]) async throws -> Data {
        var parts = URLComponents(string: "https://zh.wikipedia.org/w/api.php")!
        parts.queryItems = items + [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "variant", value: "zh-tw"),
        ]
        var request = URLRequest(url: parts.url!, timeoutInterval: 15)
        request.setValue("LectureText/0.13 (personal transcription app)", forHTTPHeaderField: "User-Agent")
        for attempt in 0..<2 {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return data }
            guard code == 429, attempt == 0 else {
                throw code == 429 ? WikiError.limited : WikiError.bad(code)
            }
            let wait = Int((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 20
            try await Task.sleep(for: .seconds(min(wait, 30)))
        }
        throw WikiError.limited
    }

    /// 一次查一批標題。回傳「這個詞 → 維基頁面標題」，只含真的有頁面的；繁簡和重新導向都算。
    static func exactTitles(_ words: [String]) async throws -> [String: String] {
        struct Pair: Decodable { let from: String; let to: String }
        struct Page: Decodable { let title: String; let missing: Bool? }
        struct Query: Decodable {
            let normalized: [Pair]?
            let converted: [Pair]?
            let redirects: [Pair]?
            let pages: [Page]?
        }
        struct Reply: Decodable { let query: Query? }

        var found: [String: String] = [:]
        var start = 0
        while start < words.count {
            let batch = Array(words[start..<min(start + batchSize, words.count)])
            start += batchSize
            let data = try await get([
                URLQueryItem(name: "action", value: "query"),
                URLQueryItem(name: "titles", value: batch.joined(separator: "|")),
                URLQueryItem(name: "redirects", value: "1"),
                URLQueryItem(name: "converttitles", value: "1"),
            ])
            guard let query = try JSONDecoder().decode(Reply.self, from: data).query else { continue }
            let existing = Set((query.pages ?? []).filter { $0.missing != true }.map(\.title))
            var next: [String: String] = [:]
            for pair in (query.normalized ?? []) + (query.converted ?? []) + (query.redirects ?? []) {
                next[pair.from] = pair.to
            }
            for word in batch {
                var title = word
                var steps = 0
                while let to = next[title], steps < 5 {
                    title = to
                    steps += 1
                }
                if existing.contains(title) {
                    found[word] = title
                }
            }
        }
        return found
    }

    static func search(_ word: String) async throws -> [WikiHit] {
        struct Item: Decodable { let title: String; let snippet: String }
        struct Query: Decodable { let search: [Item]? }
        struct Reply: Decodable { let query: Query? }
        let data = try await get([
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: word),
            URLQueryItem(name: "srlimit", value: "3"),
        ])
        let items = try JSONDecoder().decode(Reply.self, from: data).query?.search ?? []
        return items.map { WikiHit(title: $0.title, snippet: $0.snippet) }
    }

    /// 挑到的詞全部查完。查一半被限流也回傳已查到的，其餘當未確認，並把原因帶回去。
    /// 連網前一定先過 PrivacyGate：像私人姓名的詞不送，只記成 held。這是往維基送字的唯一入口。
    static func check(_ all: [TermPick], transcript: String) async -> (notes: [TermNote], error: String?) {
        let gate = PrivacyGate.split(all, transcript: transcript)
        let picks = gate.allowed
        var notes = gate.held.map { TermNote(written: $0.written, right: "", status: "held", url: nil) }
        var error: String?
        let guesses = picks.map(\.guess)
        var titles: [String: String] = [:]
        do {
            titles = try await exactTitles(guesses)
        } catch {
            return (notes + picks.map { TermNote(written: $0.written, right: "", status: "none", url: nil) }, error.localizedDescription)
        }
        var searches = 0
        var stopped = false
        for pick in picks {
            if let title = titles[pick.guess] {
                notes.append(TermNote(written: pick.written, right: pick.guess, status: "found", url: TermCheck.pageURL(title)))
                continue
            }
            if stopped || searches >= maxSearches || Task.isCancelled {
                notes.append(TermNote(written: pick.written, right: "", status: "none", url: nil))
                continue
            }
            do {
                if searches > 0 {
                    try await Task.sleep(for: searchGap)
                }
                searches += 1
                let verdict = TermCheck.judge(guess: pick.guess, hits: try await search(pick.guess))
                notes.append(TermNote(written: pick.written, right: verdict.status == "none" ? "" : pick.guess, status: verdict.status, url: verdict.url))
            } catch {
                stopped = true
                notes.append(TermNote(written: pick.written, right: "", status: "none", url: nil))
            }
        }
        if stopped {
            error = "維基百科查到一半停了，剩下的列未確認"
        }
        return (notes, error)
    }
}
