import SwiftUI
import UIKit
import UniformTypeIdentifiers

// v0.26.0 即時模式 1 錄音畫面：由上而下一張張卡（每 60 秒一張），下面接還沒進卡的字。
// 每張卡：時間＋頁碼、一句重點、整理版、不確定的詞、逐字稿（一律顯示，改過的字綠色，點了才看原字）、「原始轉錄」（預設收起來）。
// v0.26.4：寬＝左逐字稿、右重點卡；窄＝一欄，重點在段落上方。字級 22／15／13／11。
// 卡片的資料、比對在 LiveCards.swift（純邏輯，shape_check 測）；這個檔只畫。

/// 卡片清單＋下面的即時字。使用者原本在底部才自動捲到底（往上看舊卡時不跳）。
struct LiveCardsView: View {
    let model: AppModel
    let review: LiveReviewer
    @State private var atBottom = true
    /// v0.26.4：畫面寬度（≥ 700 點＝左右兩欄）
    @State private var width: CGFloat = 0

    /// 捲動位置（只比這三個數字）
    private struct Spot: Equatable {
        var offset: CGFloat
        var visible: CGFloat
        var content: CGFloat
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // v0.26.3 修「閃」：LazyVStack 在內容一直變高、又捲到底時會先用估的高度，畫面整片空白一下再出現（11/13 真機 1:14 空白、1:19 有字）。
                // 一堂課最多約 100 張卡，用一般 VStack 全部排好，高度不再用估的。
                VStack(alignment: .leading, spacing: 22) {
                    if review.cards.isEmpty, model.cardTail.isEmpty, model.volatileText.isEmpty {
                        // v0.26.3：第一句出來前（Whisper 要先聽一段）畫面不是空的，免得以為壞掉
                        Text(CardText.listening)
                            .font(.system(size: LiveCardView.Size.text))
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(review.cards) { card in
                        LiveCardView(card: card, diff: review.diffs[card.id],
                                     slides: SlideRef(course: review.course, source: review.log.slides),
                                     wide: LiveCardView.isWide(width))
                    }
                    // 寬的時候即時字只佔左欄（和逐字稿對齊）
                    LiveCardsTail(model: model, review: review)
                        .padding(.trailing, LiveCardView.isWide(width) ? 320 : 0)
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // v0.26.2：一打開在底部；內容比畫面短時從上面排（不再上面留一大片白）
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            // v0.26.2 修「一直跳」：原本只在內容沒變時記「在不在底部」，Whisper 每幾秒加字，
            // 使用者往上捲的同時內容也在變，就一直被拉回底部。改成看手指：一碰就停止跟捲，放手停下來時在底部才恢復。
            .onScrollPhaseChange { _, phase, context in
                switch phase {
                case .interacting:
                    atBottom = false
                case .idle:
                    let geo = context.geometry
                    atBottom = geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
                default:
                    break
                }
            }
            .onScrollGeometryChange(for: Spot.self) { geo in
                Spot(offset: geo.contentOffset.y, visible: geo.containerSize.height, content: geo.contentSize.height)
            } action: { old, new in
                // 內容變長（新卡、新字）：原本在底部才跟著捲；內容比畫面短時不捲（捲了反而整片空白）
                if new.content != old.content, atBottom, new.content > new.visible {
                    Task { @MainActor in
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private static let bottomID = "cards-bottom"
}

/// 還沒進卡的 Whisper 字（深灰）＋ Apple 灰字（淺灰）
private struct LiveCardsTail: View {
    let model: AppModel
    let review: LiveReviewer

    var body: some View {
        // 新卡排出去時 run.text 不一定變，讀一下卡片數讓這裡跟著更新
        let _ = review.cards.count
        let whisper = model.cardTail
        let apple = model.volatileText
        if !whisper.isEmpty || !apple.isEmpty {
            // 和卡片裡的逐字稿同一個大小，字進卡片時不會突然變大變小
            Text(Self.styled(whisper: whisper, apple: apple))
                .font(.system(size: LiveCardView.Size.text))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func styled(whisper: String, apple: String) -> AttributedString {
        var first = AttributedString(whisper)
        first.foregroundColor = Color(.secondaryLabel)
        var second = AttributedString(apple)
        second.foregroundColor = Color(.tertiaryLabel)
        return first + second
    }
}

/// v0.26.1：卡片分享時要畫哪份投影片（正式課名＋原 PDF 檔名；檔名 nil＝這門課最新的那份）
struct SlideRef: Equatable {
    let course: String
    let source: String?
}

/// v0.26.1 卡片分享到別的 App（單向；例如 iPad 分割畫面旁邊的 Gemini）：文字＋那一頁投影片的圖。
enum CardShare {
    /// 投影片那一頁的圖（沒頁碼、沒投影片、沒有 PDF＝nil）。背景跑。
    static func image(_ card: LiveCard, slides: SlideRef?) async -> UIImage? {
        guard let page = card.page, let slides else { return nil }
        let data = await Task.detached {
            SlideImport.pageImage(course: slides.course, source: slides.source, page: page)
        }.value
        return data.flatMap { UIImage(data: $0) }
    }

    /// 開系統分享面板；iPad 用 anchor 當 popover 的錨點
    @MainActor
    static func present(_ card: LiveCard, slides: SlideRef?, anchor: UIView?) async {
        var items: [Any] = [CardText.share(card)]
        if let image = await image(card, slides: slides) {
            items.append(image)
        }
        guard let anchor, let window = anchor.window, var top = window.rootViewController else { return }
        while let next = top.presentedViewController {
            top = next
        }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
        }
        top.present(controller, animated: true)
    }

    /// 長按拖到旁邊的 App：文字和圖兩種都放（對方 App 挑它收得下的那種）
    static func provider(_ card: LiveCard, slides: SlideRef?) -> NSItemProvider {
        let provider = NSItemProvider(object: CardText.share(card) as NSString)
        if let page = card.page, let slides {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = SlideImport.pageImage(course: slides.course, source: slides.source, page: page)
                    completion(data, nil)
                }
                return nil
            }
        }
        return provider
    }
}

/// 抓到分享鈕底下的 UIView（iPad 分享面板要從這裡彈出來）
final class ShareAnchorBox {
    weak var view: UIView?
}

struct ShareAnchorView: UIViewRepresentable {
    let box: ShareAnchorBox

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        box.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        box.view = view
    }
}

/// 一張卡
struct LiveCardView: View {
    let card: LiveCard
    let diff: [CardDiff.Piece]?
    /// v0.26.1：分享時畫哪份投影片；nil＝只送文字
    var slides: SlideRef? = nil
    @State private var anchor = ShareAnchorBox()
    /// v0.26.2：原稿預設收起來（完整文字另外一律顯示）；點「原稿」展開
    @State private var rawOpen = false
    /// 點開看原字的那幾組
    @State private var shown: Set<Int> = []

    static let unsureOrange = Color(red: 0.78, green: 0.40, blue: 0.0)

    /// v0.26.4：寬（iPad 全螢幕）＝左逐字稿、右重點卡；窄（分割畫面、手機）＝一欄，重點在段落上方
    var wide = false

    var body: some View {
        Group {
            if wide {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        header
                        transcript
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        keyBlock
                    }
                    .padding(14)
                    .frame(width: 300, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray6)))
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    keyBlock
                    header
                    transcript
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 14))
        // v0.26.1：長按拖到旁邊的 App（文字＋圖）
        .onDrag {
            CardShare.provider(card, slides: slides)
        }
    }

    /// v0.26.4 字級（他 11/13 定：重點大、逐字稿小）：重點 22 粗 → 整理版 15 → 逐字稿 13 → 時間 11
    /// 寬度夠放左右兩欄嗎（右欄 300 點＋間距，左欄至少約 380 點）
    static func isWide(_ width: CGFloat) -> Bool { width >= 700 }

    enum Size {
        static let key: CGFloat = 22
        static let tidy: CGFloat = 15
        static let text: CGFloat = 13
        static let time: CGFloat = 11
    }

    /// 時間、頁碼、分享鈕一行
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(CardText.range(card))
                .font(.system(size: Size.time))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            if let page = card.page {
                Text("p.\(page)")
                    .font(.system(size: Size.time, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // v0.26.1：分享到別的 App（文字＋那一頁投影片的圖）
            Button {
                let target = anchor.view
                Task { await CardShare.present(card, slides: slides, anchor: target) }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(ShareAnchorView(box: anchor))
            .accessibilityLabel("分享這張卡")
        }
    }

    /// 重點、整理版、不確定的詞；還在整理、沒整理到時是一行小字
    @ViewBuilder
    private var keyBlock: some View {
        switch card.state {
        case .waiting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(card.note ?? "整理中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed:
            Text(card.note ?? "沒整理到")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .done:
            if !card.key.isEmpty {
                Text(card.key)
                    .font(.system(size: Size.key, weight: .bold))
            }
            if !card.tidy.isEmpty {
                Text(card.tidy)
                    .font(.system(size: Size.tidy))
            }
            if !card.unsure.isEmpty {
                Text(card.unsure.joined(separator: "　"))
                    .font(.caption)
                    .foregroundStyle(Self.unsureOrange)
            }
        }
    }

    /// 逐字稿一律顯示（整理到＝改好的全文，綠字點了看原字；否則 Whisper 原字），原稿預設收起來
    @ViewBuilder
    private var transcript: some View {
        if !card.transcriptText.isEmpty {
            Text(styled)
                .font(.system(size: Size.text))
                .lineSpacing(3)
                .tint(LiveText.fixGreen)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "cardfix", let group = Int(url.lastPathComponent) else { return .systemAction }
                    if shown.contains(group) {
                        shown.remove(group)
                    } else {
                        shown.insert(group)
                    }
                    return .handled
                })
        }
        if card.state == .done, !card.raw.isEmpty, card.raw != card.transcriptText {
            Button {
                rawOpen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: rawOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("原始轉錄")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(rawOpen ? "收合原始轉錄" : "展開原始轉錄")
            if rawOpen {
                Text(CardDiff.lines(card.raw))
                    .font(.system(size: Size.time))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 原稿區的字：整理到的卡＝擴寫全文（一句一行），改過的字綠色、純刪除的地方一個小紅點；點了在後面顯示原字（刪除線、小一號、灰）
    private var styled: AttributedString {
        guard card.state == .done, !card.expanded.isEmpty, let diff, !diff.isEmpty else {
            return AttributedString(CardDiff.lines(card.transcriptText))
        }
        var out = AttributedString()
        for piece in diff {
            switch piece.kind {
            case .same:
                out += AttributedString(piece.text)
            case .changed:
                var part = AttributedString(piece.text)
                part.foregroundColor = LiveText.fixGreen
                part.link = URL(string: "cardfix://g/\(piece.group)")
                out += part
                if shown.contains(piece.group), !piece.old.isEmpty {
                    out += Self.original(piece.old)
                }
            case .deleted:
                // 連結的字會被套成 tint 色，用表情符號的紅點才保證是紅的
                var dot = AttributedString("🔴")
                dot.font = Font.system(size: 7)
                dot.link = URL(string: "cardfix://g/\(piece.group)")
                out += dot
                if shown.contains(piece.group) {
                    out += Self.original(piece.old)
                }
            }
        }
        return out
    }

    /// 原字：刪除線、小一號、灰
    private static func original(_ text: String) -> AttributedString {
        var part = AttributedString(text)
        part.foregroundColor = Color.gray
        part.font = Font.footnote
        part.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Color.gray)
        return part
    }
}

/// v0.26.1 結果畫面的卡片清單（模式 1 的場；讀「… 卡片.json」，比對在背景算）
struct ResultCardsSheet: View {
    let run: SavedRun
    let close: () -> Void
    @State private var cards: [LiveCard] = []
    @State private var diffs: [Int: [CardDiff.Piece]] = [:]
    @State private var slides: SlideRef?
    @State private var width: CGFloat = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(cards) { card in
                        LiveCardView(card: card, diff: diffs[card.id], slides: slides,
                                     wide: LiveCardView.isWide(width - 32))
                    }
                }
                .padding(16)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .background(Color.white)
            .navigationTitle(run.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: close) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("關閉")
                }
            }
        }
        .task {
            let current = run
            let loaded = await Task.detached { () -> ([LiveCard], [Int: [CardDiff.Piece]], String?) in
                let cards = Store.loadCards(of: current)
                var diffs: [Int: [CardDiff.Piece]] = [:]
                for card in cards where card.state == .done {
                    diffs[card.id] = CardDiff.pieces(raw: card.raw, expanded: card.expanded)
                }
                return (cards, diffs, Store.loadReview(of: current)?.slides)
            }.value
            cards = loaded.0
            diffs = loaded.1
            if let course = run.course.map(CourseSchedule.formalName) {
                slides = SlideRef(course: course, source: loaded.2)
            }
        }
    }
}
