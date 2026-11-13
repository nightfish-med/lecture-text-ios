import SwiftUI
import UIKit
import UniformTypeIdentifiers

// v0.26.0 即時模式 1 錄音畫面：由上而下一張張卡（每 60 秒一張），下面接還沒進卡的字。
// 每張卡：時間＋頁碼、一句重點、整理版、不確定的詞、逐字稿（一律顯示，改過的字綠色）、「原始轉錄」（預設收起來）。
// v0.26.4：寬＝左逐字稿、右重點卡；窄＝一欄，重點在段落上方。字級 22／15／13／11。
// v0.27.0：寬的時候中間有把手可以左右拉（記住比例）；逐字稿一句一行，點一下那行＝改字（看得到原本聽到的）；
// Apple Pencil 圈起來＝那幾行送 Haiku 上網重查，結果放在右邊重點卡的「重查」。手指照常捲動。
// 卡片的資料、比對、行的切法在 LiveCards.swift、SceneCards.swift（純邏輯，shape_check 測）；這個檔只畫。

/// 點一行要改的那一行
struct LineEditRequest: Identifiable {
    let id = UUID()
    let cardID: Int
    let line: Int
    let current: String
    let original: String
}

/// 卡片清單＋下面的即時字。使用者原本在底部才自動捲到底（往上看舊卡時不跳）。
struct LiveCardsView: View {
    let model: AppModel
    let review: LiveReviewer
    @State private var atBottom = true
    /// v0.26.4：畫面大小（寬 ≥ 700 點＝左右兩欄）
    @State private var size: CGSize = .zero
    /// v0.27.0：右欄佔整寬的比例（0＝沒拉過，用 300 點）；所有卡片、下面的即時字都照這個
    @AppStorage("cardRightRatio") private var rightRatio: Double = 0
    @State private var dragStart: Double?
    /// v0.27.0：點一行要改的
    @State private var editing: LineEditRequest?

    /// 捲動位置（只比這三個數字）
    private struct Spot: Equatable {
        var offset: CGFloat
        var visible: CGFloat
        var content: CGFloat
    }

    private var wide: Bool { LiveCardView.isWide(size.width) }
    private var right: Double { CardSplit.right(total: Double(size.width), ratio: rightRatio) }

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
                                     wide: wide, rightWidth: CGFloat(right),
                                     onEdit: { index, line in
                                         editing = LineEditRequest(cardID: card.id, line: index, current: line.text, original: line.original)
                                     },
                                     onCircle: { rows in
                                         review.recheck(cardID: card.id, lines: rows)
                                     })
                    }
                    // 寬的時候即時字只佔左欄（和逐字稿對齊）
                    LiveCardsTail(model: model, review: review)
                        .padding(.trailing, wide ? CGFloat(right + CardSplit.gap) : 0)
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // v0.27.0：Pencil 不捲動（留給圈字），手指、觸控板照常捲
                .background(PencilScrollGuard())
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
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
            .overlay(alignment: .topLeading) {
                if wide {
                    splitHandle
                }
            }
        }
        .sheet(item: $editing) { request in
            LineEditSheet(request: request) { text in
                review.editLine(cardID: request.cardID, line: request.line, before: request.current, after: text)
            }
        }
    }

    /// v0.27.0 左右欄中間的把手：拉動改右欄寬度（兩邊都有最小寬度），放開記住比例
    private var splitHandle: some View {
        let center = Double(size.width) - right - CardSplit.gap / 2
        return ZStack {
            if dragStart != nil {
                Rectangle()
                    .fill(Color(.separator))
                    .frame(width: 1, height: max(0, size.height))
                    .allowsHitTesting(false)
            }
            Capsule()
                .fill(Color(.systemGray3))
                .frame(width: 6, height: 48)
                .frame(width: 28, height: 120)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStart ?? right
                            if dragStart == nil { dragStart = start }
                            rightRatio = CardSplit.ratio(right: start - Double(value.translation.width), total: Double(size.width))
                        }
                        .onEnded { _ in
                            dragStart = nil
                        }
                )
                .accessibilityLabel("左右欄的分隔，拉動調整寬度")
        }
        .frame(width: 28, height: max(120, size.height))
        .offset(x: CGFloat(center) - 14)
    }

    private static let bottomID = "cards-bottom"
}

/// v0.27.0 點一行的改字畫面：上面灰字是原本聽到的（Whisper），下面改；「改」才存
struct LineEditSheet: View {
    let request: LineEditRequest
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(request: LineEditRequest, save: @escaping (String) -> Void) {
        self.request = request
        self.save = save
        _text = State(initialValue: request.current)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("原本聽到的（Whisper）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(request.original.isEmpty ? "（沒有）" : request.original)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                TextField("這一行", text: $text, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 6)
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("改這一行")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("改") {
                        save(text)
                        dismiss()
                    }
                    .disabled(text == request.current)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// v0.27.0：所在的捲動區 Pencil 不捲動（只認手指、滑鼠、觸控板），Pencil 留給圈字。不擋任何點按。
private struct PencilScrollGuard: UIViewRepresentable {
    func makeUIView(context: Context) -> GuardView {
        let view = GuardView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: GuardView, context: Context) {
        view.apply()
    }

    final class GuardView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            var next = superview
            while let view = next {
                if let scroll = view as? UIScrollView {
                    scroll.panGestureRecognizer.allowedTouchTypes = [
                        UITouch.TouchType.direct, UITouch.TouchType.indirect, UITouch.TouchType.indirectPointer,
                    ].map { NSNumber(value: $0.rawValue) }
                    return
                }
                next = view.superview
            }
        }
    }
}

/// v0.27.0：Apple Pencil 的筆觸（只認 Pencil；手指照常點、捲）。座標是掛上去那個畫面自己的座標。
private struct PencilStrokeGesture: UIGestureRecognizerRepresentable {
    let onPoint: (CGPoint, Bool) -> Void
    let onEnd: (Bool) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pan.maximumNumberOfTouches = 1
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let point = context.converter.localLocation
        switch recognizer.state {
        case .began:
            onPoint(point, true)
        case .changed:
            onPoint(point, false)
        case .ended:
            onPoint(point, false)
            onEnd(true)
        default:
            onEnd(false)
        }
    }
}

/// 有給圈字的動作才掛 Pencil 手勢（結果畫面的卡片只看不改）
private struct PencilStrokeModifier: ViewModifier {
    let enabled: Bool
    let onPoint: (CGPoint, Bool) -> Void
    let onEnd: (Bool) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.gesture(PencilStrokeGesture(onPoint: onPoint, onEnd: onEnd))
        } else {
            content
        }
    }
}

/// v0.27.0 右邊重點卡的「重查」：結論 → 為什麼 → 來源（點了開 Safari）→ 逐字稿已改 → 沒把握（橘）。等的時候轉圈圈。
private struct RecheckView: View {
    let item: CardRecheck

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("重查")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            switch item.state {
            case .waiting:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(item.note ?? "上網查資料中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed:
                Text(item.note ?? "沒查到")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .done:
                if let conclusion = item.conclusion, !conclusion.isEmpty {
                    Text(conclusion)
                        .font(.system(size: LiveCardView.Size.tidy, weight: .semibold))
                }
                if let why = item.why, !why.isEmpty {
                    Text(why)
                        .font(.footnote)
                }
                if let sources = item.sources, !sources.isEmpty {
                    Text("來源")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                        if let url = URL(string: source.url) {
                            Link(destination: url) {
                                Text(source.title)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }
                }
                ForEach(Array((item.applied ?? []).enumerated()), id: \.offset) { _, fix in
                    Text("逐字稿已改：\(fix.old) → \(fix.new.isEmpty ? "（刪掉）" : fix.new)")
                        .font(.caption)
                        .foregroundStyle(LiveText.fixGreen)
                }
                if let unsure = item.unsure, !unsure.isEmpty {
                    Text("沒把握：\(unsure)")
                        .font(.caption)
                        .foregroundStyle(LiveCardView.unsureOrange)
                }
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
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
    /// v0.26.4：寬（iPad 全螢幕）＝左逐字稿、右重點卡；窄（分割畫面、手機）＝一欄，重點在段落上方
    var wide = false
    /// v0.27.0：右欄寬度（中間把手拉的）
    var rightWidth: CGFloat = 300
    /// v0.27.0：點一行＝改字（nil＝只看，例如結果畫面）
    var onEdit: ((Int, CardLine) -> Void)? = nil
    /// v0.27.0：Pencil 圈起來的行＝重查（nil＝不能圈）
    var onCircle: (([Int]) -> Void)? = nil
    @State private var anchor = ShareAnchorBox()
    /// v0.26.2：原稿預設收起來（完整文字另外一律顯示）；點「原始轉錄」展開
    @State private var rawOpen = false
    /// v0.27.0：每行的位置（這張卡逐字稿欄的座標）、Pencil 正在畫的點、畫到的行
    @State private var boxes: [Int: CGRect] = [:]
    @State private var stroke: [CGPoint] = []
    @State private var circled: Set<Int> = []

    static let unsureOrange = Color(red: 0.78, green: 0.40, blue: 0.0)
    /// 圈到的行、重查中的行的淡底色
    static let circleBack = Color(red: 1.0, green: 0.62, blue: 0.2).opacity(0.16)

    var body: some View {
        Group {
            if wide {
                HStack(alignment: .top, spacing: CGFloat(CardSplit.gap)) {
                    VStack(alignment: .leading, spacing: 4) {
                        header
                        transcript
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        keyBlock
                        rechecks
                    }
                    .padding(14)
                    .frame(width: rightWidth, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray6)))
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    keyBlock
                    rechecks
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
    /// 寬度夠放左右兩欄嗎（右欄最少 220 點＋間距，左欄至少約 300 點）
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

    /// v0.27.0 重查結果（一次一段，依先後）
    @ViewBuilder
    private var rechecks: some View {
        if let list = card.rechecks, !list.isEmpty {
            ForEach(list) { item in
                RecheckView(item: item)
            }
        }
    }

    /// 這張卡逐字稿欄的座標名字
    private var space: String { "card-text-\(card.id)" }

    /// 淡底色的行：Pencil 正在圈的、送出去還在查的
    private var highlighted: Set<Int> {
        var rows = circled
        for item in card.rechecks ?? [] where item.state == .waiting {
            rows.formUnion(item.lines)
        }
        return rows
    }

    /// 逐字稿一律顯示，一句一行（整理到＝改好的全文、綠字是改過的；否則 Whisper 原字）；原稿預設收起來
    @ViewBuilder
    private var transcript: some View {
        let lines = CardLines.build(card, diff: diff)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    lineView(index, line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .coordinateSpace(.named(space))
            .overlay(alignment: .topLeading) {
                strokePath
            }
            .modifier(PencilStrokeModifier(enabled: onCircle != nil, onPoint: { point, begin in
                if begin {
                    stroke = [point]
                } else {
                    stroke.append(point)
                }
                circled = Set(hitRows())
            }, onEnd: { committed in
                let rows = committed ? hitRows() : []
                stroke = []
                circled = []
                if !rows.isEmpty {
                    onCircle?(rows)
                }
            }))
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

    private func lineView(_ index: Int, _ line: CardLine) -> some View {
        Text(Self.styled(line))
            .font(.system(size: Size.text))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
            .background(highlighted.contains(index) ? Self.circleBack : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                onEdit?(index, line)
            }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(space))
            } action: { rect in
                boxes[index] = rect
            }
            .accessibilityHint(onEdit == nil ? "" : "點一下改這一行")
    }

    /// Pencil 畫的時候一條淡橘線，放開就消失（不留筆跡）
    private var strokePath: some View {
        Path { path in
            guard let first = stroke.first else { return }
            path.move(to: first)
            for point in stroke.dropFirst() {
                path.addLine(to: point)
            }
        }
        .stroke(Color.orange.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        .allowsHitTesting(false)
    }

    /// 筆跡的上下範圍蓋到哪幾行
    private func hitRows() -> [Int] {
        guard let first = stroke.first else { return [] }
        var top = first.y, bottom = first.y
        for point in stroke {
            top = min(top, point.y)
            bottom = max(bottom, point.y)
        }
        let list = boxes.map { LineBox(index: $0.key, top: Double($0.value.minY), bottom: Double($0.value.maxY)) }
        return CardLines.hit(list, top: Double(top), bottom: Double(bottom))
    }

    /// 一行的字：改過的那段綠色（使用者改的、重查改的都是）；Haiku 擴寫改的字綠色；純刪除的地方一個小紅點
    static func styled(_ line: CardLine) -> AttributedString {
        if let from = line.editedFrom {
            let frag = CardEdits.fragment(from, line.text)
            var out = AttributedString(frag.prefix)
            if frag.new.isEmpty, !frag.old.isEmpty {
                var dot = AttributedString("•")
                dot.foregroundColor = Color.red
                out += dot
            } else {
                var middle = AttributedString(frag.new)
                middle.foregroundColor = LiveText.fixGreen
                out += middle
            }
            out += AttributedString(frag.suffix)
            return out
        }
        var out = AttributedString()
        for piece in line.pieces {
            switch piece.kind {
            case .same:
                out += AttributedString(piece.text)
            case .changed:
                var part = AttributedString(piece.text)
                part.foregroundColor = LiveText.fixGreen
                out += part
            case .deleted:
                var dot = AttributedString("•")
                dot.foregroundColor = Color.red
                out += dot
            }
        }
        return out
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
    /// v0.27.0：和錄音畫面同一個左右比例
    @AppStorage("cardRightRatio") private var rightRatio: Double = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(cards) { card in
                        LiveCardView(card: card, diff: diffs[card.id], slides: slides,
                                     wide: LiveCardView.isWide(width - 32),
                                     rightWidth: CGFloat(CardSplit.right(total: Double(width - 32), ratio: rightRatio)))
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
