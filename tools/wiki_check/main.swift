import Foundation

// 雲端跑一次：真的查維基百科，驗回應解得開、判定合理。詞都是公開的歷史名詞，不含稿。
let picks = [
    TermPick(written: ["夏木漱石"], guess: "夏目漱石"),
    TermPick(written: ["東經大學"], guess: "東京大學"),
    TermPick(written: ["分子生學"], guess: "分子生物學"),
    TermPick(written: ["明治圍新"], guess: "明治維新"),
    TermPick(written: ["福利龍之介"], guess: "芥川龍之介"),
    TermPick(written: ["禮公"], guess: "理工學部"),
    TermPick(written: ["亂打的字"], guess: "嗯嗯這不是詞"),
]
let result = await Wiki.check(picks, transcript: "")
for note in result.notes {
    print(note.status, note.written, "→", note.right, note.url ?? "")
}
print("錯誤：", result.error ?? "沒有")
let text = "夏木漱石去東經大學。亂打的字留著。"
print(TermCheck.annotate(result.notes, in: text))
let found = result.notes.filter { $0.status == "found" }.count
print("查到 \(found) 組")

// 關卡：攔下所有往外送的請求，看編的姓名有沒有出現在網址裡。這段不連網。
final class WireTap: URLProtocol {
    static var urls: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        WireTap.urls.append(request.url?.absoluteString.removingPercentEncoding ?? "")
        let reply = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"query\":{}}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
URLProtocol.registerClass(WireTap.self)
let guarded = await Wiki.check([
    TermPick(written: ["陳曉明"], guess: "陳小明"),
    TermPick(written: ["阿花"], guess: "阿華"),
    TermPick(written: ["東經大學"], guess: "東京大學"),
], transcript: "")
URLProtocol.unregisterClass(WireTap.self)
let sent = WireTap.urls.joined(separator: " ")
let leaked = ["陳小明", "陳曉明", "阿華", "阿花"].filter { sent.contains($0) }
let heldCount = guarded.notes.filter { $0.status == "held" }.count
print("關卡：送出 \(WireTap.urls.count) 次請求，擋下 \(heldCount) 組，漏出去的編造姓名 \(leaked.count) 個，公開詞有送出：\(sent.contains("東京大學"))")

exit(found >= 3 && result.notes.last?.status == "none" && leaked.isEmpty && heldCount == 2 && sent.contains("東京大學") ? 0 : 1)
