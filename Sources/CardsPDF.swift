import UIKit

// v0.27.1 卡片 PDF（A4 直式，裝置上產生）：每張卡依時間——時間＋頁碼、重點（大）、整理版、改好的全文（小）、
// 重查（結論／為什麼／來源）、那一頁投影片的圖（有投影片才放；和上一張卡同一頁就不重放，PDF 才不會太大）。
// 分頁、縮放的算法在 SessionFiles.swift（CardsPDFLayout，shape_check 測）；這個檔只量字和畫。可以在背景跑。

enum CardsPDF {
    private enum Item {
        case text(NSAttributedString, link: URL?)
        case image(UIImage, CGSize)
    }

    private static func attributed(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = .black,
                                   spacing: CGFloat = 2) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = spacing
        style.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
    }

    private static func height(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let rect = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return ceil(rect.height)
    }

    /// 投影片那一頁：最大邊 1600 像素、JPEG 0.6 再讀回來（PDF 才不會太大）
    private static func slideImage(course: String, source: String?, page: Int) -> UIImage? {
        guard let data = SlideImport.pageImage(course: course, source: source, page: page),
              let image = UIImage(data: data) else { return nil }
        let pixels = CardsPDFLayout.pixelSize(width: Double(image.size.width * image.scale), height: Double(image.size.height * image.scale))
        let size = CGSize(width: pixels.width.rounded(), height: pixels.height.rounded())
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: CGFloat(CardsPDFLayout.jpegQuality)) else { return nil }
        return UIImage(data: jpeg)
    }

    /// 寫 PDF 到 url。title：第一頁最上面那行；course：正式課名（找投影片）；slides：投影片原檔名（nil＝這門課最新那份）
    static func write(cards: [LiveCard], title: String, course: String, slides: String?, to url: URL) throws {
        let width = CGFloat(CardsPDFLayout.contentWidth)
        var items: [Item] = []
        var blocks: [CardsPDFLayout.Block] = []
        func addText(_ text: NSAttributedString, gap: Double, keep: Bool = false, link: URL? = nil) {
            items.append(.text(text, link: link))
            blocks.append(CardsPDFLayout.Block(height: Double(height(text, width: width)), gap: gap, keepWithNext: keep))
        }
        addText(attributed(title, size: 20, weight: .bold), gap: 18)
        var lastPage: Int?
        for card in cards.sorted(by: { $0.start < $1.start }) {
            let head = CardText.range(card) + (card.page.map { "　p.\($0)" } ?? "")
            addText(attributed(head, size: 10, color: .darkGray), gap: 4, keep: true)
            switch card.state {
            case .done:
                if !card.key.isEmpty { addText(attributed(card.key, size: 17, weight: .bold, spacing: 3), gap: 6, keep: true) }
                if !card.tidy.isEmpty { addText(attributed(card.tidy, size: 12, spacing: 3), gap: 6) }
                if !card.unsure.isEmpty {
                    addText(attributed("不確定：" + card.unsure.joined(separator: "、"), size: 10, color: .systemOrange), gap: 6)
                }
            case .failed, .waiting:
                addText(attributed(card.note ?? "沒整理到", size: 10, color: .gray), gap: 6)
            }
            for item in card.rechecks ?? [] where item.state == .done {
                addText(attributed("重查", size: 9, weight: .semibold, color: .gray), gap: 2, keep: true)
                if let conclusion = item.conclusion, !conclusion.isEmpty { addText(attributed(conclusion, size: 11, weight: .semibold), gap: 2) }
                if let why = item.why, !why.isEmpty { addText(attributed(why, size: 10), gap: 2) }
                for source in item.sources ?? [] {
                    addText(attributed("來源：" + source.title, size: 9, color: .systemBlue), gap: 2, link: URL(string: source.url))
                }
                for fix in item.applied ?? [] {
                    addText(attributed("逐字稿已改：\(fix.old) → \(fix.new)", size: 9, color: UIColor(red: 0.06, green: 0.46, blue: 0.43, alpha: 1)), gap: 2)
                }
                if let unsure = item.unsure, !unsure.isEmpty { addText(attributed("沒把握：" + unsure, size: 9, color: .systemOrange), gap: 2) }
            }
            let body = card.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = CardDiff.lines(body).components(separatedBy: "\n").filter { !$0.isEmpty }
            for (i, line) in lines.enumerated() {
                addText(attributed(line, size: 9.5, color: UIColor(white: 0.2, alpha: 1)), gap: i == lines.count - 1 ? 8 : 1)
            }
            if let page = card.page, page != lastPage, !course.isEmpty,
               let image = slideImage(course: course, source: slides, page: page) {
                let fit = CardsPDFLayout.fit(width: Double(image.size.width), height: Double(image.size.height),
                                             maxWidth: CardsPDFLayout.contentWidth, maxHeight: CardsPDFLayout.contentHeight * 0.6)
                let size = CGSize(width: fit.width, height: fit.height)
                items.append(.image(image, size))
                blocks.append(CardsPDFLayout.Block(height: fit.height, gap: 8))
            }
            lastPage = card.page ?? lastPage
            // 卡和卡之間空一點
            if let last = blocks.indices.last {
                blocks[last].gap += 14
            }
        }
        let placed = CardsPDFLayout.paginate(blocks)
        let bounds = CGRect(x: 0, y: 0, width: CardsPDFLayout.pageWidth, height: CardsPDFLayout.pageHeight)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "轉文字"]
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        let margin = CGFloat(CardsPDFLayout.margin)
        try renderer.writePDF(to: url) { context in
            var current = -1
            for (index, item) in items.enumerated() {
                let spot = placed[index]
                while current < spot.page {
                    context.beginPage()
                    current += 1
                }
                let y = margin + CGFloat(spot.y)
                switch item {
                case .text(let text, let link):
                    let rect = CGRect(x: margin, y: y, width: width, height: CGFloat(blocks[index].height))
                    text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                    if let link {
                        context.setURL(link, for: rect)
                    }
                case .image(let image, let size):
                    image.draw(in: CGRect(x: margin, y: y, width: size.width, height: size.height))
                }
            }
            if items.isEmpty {
                context.beginPage()
            }
        }
    }
}
