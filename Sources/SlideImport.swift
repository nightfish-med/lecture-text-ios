import Foundation
import PDFKit

/// v0.23.1 投影片 PDF 匯入：抽每頁的字，存成 SlideDeck（Documents/投影片/<正式課名>/<檔名>.json），
/// 這門課的課程設定指到這份。PDF 本身不留（選來的檔複製到暫存、抽完就刪），也不上傳。
/// 不要放 MainActor 跑（幾十頁的 PDF 抽字要幾百毫秒）。
enum SlideImport {
    enum Problem: LocalizedError {
        case unreadable
        case locked
        case noPages

        var errorDescription: String? {
            switch self {
            case .unreadable: return "打不開這個 PDF"
            case .locked: return "這個 PDF 有密碼，抽不到字"
            case .noPages: return "這個 PDF 沒有頁"
            }
        }
    }

    /// 每頁的字（pages[0]＝p.1）；掃描檔、純圖片的頁是空字串。
    static func extractPages(_ url: URL) throws -> [String] {
        guard let document = PDFDocument(url: url) else { throw Problem.unreadable }
        if document.isLocked, !document.unlock(withPassword: "") { throw Problem.locked }
        guard document.pageCount > 0 else { throw Problem.noPages }
        return (0..<document.pageCount).map { index in
            document.page(at: index)?.string ?? ""
        }
    }

    /// 抽好的字存成這門課的投影片。course 給正式課名或簡稱都可以（存檔一律用正式課名）。
    static func save(pages: [String], source: String, course: String) throws -> SlideDeck {
        let deck = SlideDeck.make(
            course: CourseSchedule.formalName(course),
            source: source,
            importedAt: Store.timestamp(),
            pages: pages
        )
        try SlideStore.save(deck, root: Store.documents)
        return deck
    }

    /// 這門課目前的投影片（設定指的那份，沒有就最新匯入的）。
    static func latest(course: String) -> SlideDeck? {
        SlideStore.latest(course: course, root: Store.documents)
    }
}
