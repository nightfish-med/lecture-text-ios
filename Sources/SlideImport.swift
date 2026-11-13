import Foundation
import PDFKit
import UIKit

/// v0.23.1 投影片 PDF 匯入：抽每頁的字，存成 SlideDeck（Documents/投影片/<正式課名>/<檔名>.json），
/// 這門課的課程設定指到這份。v0.26.1 起 PDF 也留在同一個資料夾（<檔名>.pdf，卡片分享畫那一頁用），不上傳；之前匯入的沒有 PDF，要重匯一次。
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
    static func save(pages: [String], source: String, course: String, pdf: URL? = nil) throws -> SlideDeck {
        let deck = SlideDeck.make(
            course: CourseSchedule.formalName(course),
            source: source,
            importedAt: Store.timestamp(),
            pages: pages
        )
        try SlideStore.save(deck, root: Store.documents)
        if let pdf {
            let target = pdfURL(course: deck.course, source: source)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: pdf, to: target)
            try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent())
        }
        return deck
    }

    /// v0.26.1：這份投影片的 PDF 放哪（和 .json 同資料夾、同名）
    static func pdfURL(course: String, source: String) -> URL {
        let name = (SlideDeck.fileName(source: source) as NSString).deletingPathExtension + ".pdf"
        return SlideStore.folder(course: course, root: Store.documents).appendingPathComponent(name)
    }

    /// v0.26.1 卡片分享：投影片第 page 頁（1 起）畫成圖，寬約 width 像素，JPEG。沒有 PDF、頁碼超出就 nil。不要放 MainActor 跑。
    static func pageImage(course: String, source: String?, page: Int, width: CGFloat = 1600) -> Data? {
        let name = source ?? latest(course: course)?.source
        guard let name else { return nil }
        let url = pdfURL(course: course, source: name)
        guard let document = PDFDocument(url: url), page >= 1, page <= document.pageCount,
              let pdfPage = document.page(at: page - 1) else { return nil }
        let bounds = pdfPage.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let size = CGSize(width: width, height: (width * bounds.height / bounds.width).rounded())
        // thumbnail 的 size 是點；scale 1 的畫布才是這麼多像素
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            pdfPage.thumbnail(of: size, for: .mediaBox).draw(in: CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.85)
    }

    /// 這門課目前的投影片（設定指的那份，沒有就最新匯入的）。
    static func latest(course: String) -> SlideDeck? {
        SlideStore.latest(course: course, root: Store.documents)
    }
}
