import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// v0.26.1：iPad 視窗很矮（高 < 400 點）時用精簡排版（收起標題列、按鈕縮小）。iPhone 一律 false。
private struct ShortWindowKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var shortWindow: Bool {
        get { self[ShortWindowKey.self] }
        set { self[ShortWindowKey.self] = newValue }
    }
}

/// v0.26.1：iPad 視窗可以拉得更矮（寬度照系統原本的最小值；高度系統會再夾）
enum WindowSizing {
    static let minimumHeight: CGFloat = 220
    static let shortBelow: CGFloat = 400

    @MainActor
    static func allowShortWindows() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            guard let limits = scene.sizeRestrictions else { continue }
            limits.minimumSize = CGSize(width: limits.minimumSize.width, height: minimumHeight)
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    /// v0.15 連電腦：關掉畫面就停，跟原本的錄音、選檔分開（不共用麥克風）。
    @State private var link = PhoneLink()
    /// v0.26.1：視窗高度 < 400 點（只在 iPad 用）
    @State private var short = false

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 20)
        }
        .foregroundStyle(.black)
        // v0.26.1：iPad 視窗很矮時精簡排版；視窗可以拉得更矮
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.height < WindowSizing.shortBelow
        } action: { value in
            short = value
        }
        .environment(\.shortWindow, short && UIDevice.current.userInterfaceIdiom == .pad)
        .onAppear {
            WindowSizing.allowShortWindows()
        }
        // v0.23.1：第一次貼金鑰的說明、投影片選課、上方提示（ReviewViews.swift）
        .modifier(HaikuSheets(model: model))
        // 「選檔案」選到 PDF 也走 importFile，裡面依副檔名分到投影片匯入
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                model.importFile(url)
            case .failure(let error):
                model.importFailed(error)
            }
        }
        // 匯出、傳錯誤資料：iPhone 自己的分享畫面（存到檔案、AirDrop、郵件、雲端硬碟）
        .sheet(item: $model.share) { item in
            ShareSheet(url: item.url) {
                model.share = nil
            }
            .presentationDetents([.medium, .large])
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $model.showLink) {
            LinkView(link: link, close: {
                link.stop()
                model.showLink = false
            }, save: {
                // v0.16：電腦錄完傳來的稿存成手機上的一場（逐字稿資料夾）
                model.saveComputerRun(link.pc)
            })
            .onAppear {
                link.beginScan()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .recording:
            RecordingView(model: model)
        case .copying, .preparing:
            WorkingView(model: model, title: nil, fraction: nil)
        case .downloading(let fraction):
            WorkingView(model: model, title: "語言模型下載中，只有第一次要網路", fraction: fraction)
        case .transcribing(let fraction):
            WorkingView(model: model, title: "畫面請開著", fraction: fraction)
        case .correcting(let fraction):
            WorkingView(model: model, title: "校正中，只標註不改字。按停止會留下原稿和已標的部分", fraction: fraction)
        case .separating(let fraction):
            WorkingView(model: model, title: "分人中，請留在這個畫面，切到別的 App 會暫停。第一次要下載模型。按停止會留下沒分人的稿", fraction: fraction)
        case .idle, .failed:
            if let run = model.run, !run.text.isEmpty {
                ResultView(model: model, run: run)
            } else {
                StartView(model: model)
            }
        }
    }
}

// MARK: 開始

private struct StartView: View {
    let model: AppModel
    /// v0.27.0：討論會開始前的提醒（App 內的確認，不是系統警告框）
    @State private var confirmScene = false

    var body: some View {
        Spacer()
        HStack(spacing: 40) {
            RoundIcon(systemName: "mic.fill", label: "錄音", size: 96) {
                if model.needsSceneConfirm {
                    confirmScene = true
                } else {
                    model.recordButtonTapped()
                }
            }
            .confirmationDialog(RecordScene.confirmTitle, isPresented: $confirmScene, titleVisibility: .visible) {
                Button("開始錄音") {
                    model.recordButtonTapped()
                }
                Button("取消", role: .cancel) {}
            }
            RoundIcon(systemName: "folder", label: "選檔案", size: 96) {
                model.showImporter = true
            }
        }
        HStack(spacing: 20) {
            SceneMenu(model: model, size: 56)
            FixMenu(model: model, size: 56)
            // v0.15：掃電腦的 QR 碼，手機當電腦的麥克風（手機這邊不轉文字）
            RoundIcon(systemName: "laptopcomputer", label: "連電腦", size: 56) {
                model.openLink()
            }
            // v0.23.1：Haiku 金鑰、這門課的投影片、要不要送（ReviewViews.swift）
            HaikuMenu(model: model, size: 56)
        }
        .padding(.top, 28)
        if let note = model.crashNote {
            CrashLine(model: model, note: note).font(.footnote).padding(.top, 20)
        }
        VStack(spacing: 0) {
            Text(model.warmNote)
            // v0.27.0：下一場的場景
            Text("場景：\(model.scene.title)（\(model.scene.detail)）")
            Text(model.versionLine)
            // 收起之後要知道稿去哪了
            // v0.23.2：iPad 上是「我的 iPad」
            Text("稿和錄音都在「檔案」App › 我的 \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone") › 轉文字")
            // v0.23.2：在 Haiku 圓鈕指定了下一場是哪門課
            if let chosen = model.chosenCourse {
                Text("下一場指定為「\(chosen)」，錄音會叫「\(CourseSchedule.title(stamp: Store.timestamp(), course: CourseSchedule.shortName(chosen)))」")
            } else {
                // v0.14：上課時段按錄音會照課表命名，先讓他看到會叫什麼
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let course = CourseSchedule.course(at: context.date) {
                        Text("現在是「\(course)」的時段，錄音會叫「\(CourseSchedule.title(stamp: Store.timestamp(), course: course))」")
                    }
                }
            }
            if let note = model.exportNote {
                Text(note).textSelection(.enabled)
            }
            // v0.23.1：貼金鑰／測試連線、投影片匯入的結果
            if let note = model.haikuNote {
                Text(note).textSelection(.enabled)
            }
            if let note = model.slideNote {
                Text(note).textSelection(.enabled)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.top, 20)
        if case .failed(let message) = model.phase {
            FailureLine(message: message).padding(.top, 28)
        }
        Spacer()
    }
}

// MARK: 錄音中

private struct RecordingView: View {
    let model: AppModel
    /// v0.26.1：iPad 視窗很矮
    @Environment(\.shortWindow) private var short

    var body: some View {
        // v0.14：錄音中也看得到這場叫什麼（照課表是「11/10 幾何」）；v0.26.1 視窗很矮時收起
        if !short {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.run?.displayTitle ?? "")
                    .font(.headline)
                    .lineLimit(1)
                Text("錄音中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
        }
        // v0.23.2：投影片＋Haiku 狀態一行、橫幅（沒網路、金鑰無效、花費上限、Haiku 暫停；不擋操作）
        ReviewStatusBar(model: model)
        if let review = model.reviewer, review.cardMode {
            // v0.26.0 即時模式 1：每 60 秒一張卡（重點、整理版、擴寫原稿），下面接還沒進卡的字（LiveCardViews.swift）
            LiveCardsView(model: model, review: review)
                .padding(.top, 4)
        } else {
            // v0.22：錄音中的字照課程對照表改（只改畫面），改過的字綠底，點了看原字
            LiveText(final: model.recordingTail, volatile: model.volatileText,
                     rules: model.liveFixRules, turnOff: { model.turnOffLiveFix($0) })
                .padding(.top, 4)
        }
        if let part = model.continuing?.part, !short {
            Text("續錄第 \(part) 段，接在原稿後面；時間從整場開頭算")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let error = model.liveError {
            FailureLine(message: "錄音還在繼續，但字出不來：\(error)")
        }
        // v0.20：超過 10 秒沒有聲音進來（被打斷、麥克風被佔走）
        if let note = model.stallNote {
            FailureLine(message: note)
        }
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(formatClock(model.recordingSeconds))
                        .font(.system(size: short ? 18 : 28, weight: .light, design: .rounded))
                        .monospacedDigit()
                }
                // v0.21：按了複製之後 2 秒「已複製到 mm:ss」
                if let note = model.liveCopyNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            Spacer()
            // v0.21：錄音當下就能複製：到目前為止的全文進剪貼簿，錄音不停
            RoundIcon(
                systemName: (model.liveCopyNote ?? "").hasPrefix("已複製") ? "checkmark" : "doc.on.doc",
                label: "複製到目前為止的全文",
                size: short ? 34 : 56
            ) {
                model.copyWhileRecording()
            }
            .accessibilityHint("錄音不會停")
            .padding(.trailing, 8)
            Button {
                model.recordButtonTapped()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: short ? 36 : 64))
                    .foregroundStyle(.red)
            }
            .accessibilityLabel("停止錄音")
        }
        .padding(.vertical, short ? 2 : 8)
    }
}

/// 黑字是定稿，灰字引擎還可能改。畫面一直停在最新一行。v0.16 起連電腦畫面也用這個顯示電腦傳來的稿（樣式一樣）。
/// v0.22：有 rules 時，黑字照對照表換掉，換過的字綠底；點了下面出一張小卡看原字（灰字還會變，不換）。
struct LiveText: View {
    let final: String
    let volatile: String
    var rules: [LiveFixRule] = []
    var turnOff: ((String) -> Void)? = nil
    @State private var picked: LiveFixPiece?
    /// v0.23.2 效能：黑字和規則沒變就不重算（灰字每變一次 body 都會重跑；以前每次整份 × 全部規則重算）
    @State private var cache = LiveStyleCache()

    /// v0.26.0 起卡片的改字也用這個綠（LiveCardViews.swift）
    static let fixGreen = Color(red: 0.06, green: 0.46, blue: 0.43)
    fileprivate static let fixBack = Color(red: 0.90, green: 0.96, blue: 0.95)

    private var styled: AttributedString {
        var out = cache.styled(final, rules: rules)
        var tail = AttributedString(volatile)
        tail.foregroundColor = .gray
        out += tail
        return out
    }

    var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                Text(styled)
                    .font(.title3)
                    .tint(Self.fixGreen)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "livefix", let index = Int(url.lastPathComponent) else { return .systemAction }
                let all = cache.pieces(final, rules: rules)
                if all.indices.contains(index) { picked = all[index] }
                return .handled
            })
            if let piece = picked, let original = piece.original {
                let off: (() -> Void)? = turnOff == nil ? nil : {
                    turnOff?(original)
                    picked = nil
                }
                LiveFixCard(original: original, fixed: piece.text, rule: piece.rule, turnOff: off, close: { picked = nil })
                    .transition(.opacity)
            }
        }
    }
}

/// v0.23.2：黑字（定稿＋規則）算好的分段和上色字串，輸入一樣就直接拿舊的。
final class LiveStyleCache {
    private var key: (final: String, rules: [LiveFixRule])?
    private var cachedPieces: [LiveFixPiece] = []
    private var cachedStyled = AttributedString()

    private func update(_ final: String, _ rules: [LiveFixRule]) {
        if let key, key.final == final, key.rules == rules { return }
        key = (final, rules)
        cachedPieces = LiveFix.pieces(final, rules: rules)
        var out = AttributedString()
        for (index, piece) in cachedPieces.enumerated() {
            var part = AttributedString(piece.text)
            if piece.original != nil {
                part.foregroundColor = LiveText.fixGreen
                part.backgroundColor = LiveText.fixBack
                part.link = URL(string: "livefix://p/\(index)")
            }
            out += part
        }
        cachedStyled = out
    }

    func pieces(_ final: String, rules: [LiveFixRule]) -> [LiveFixPiece] {
        update(final, rules)
        return cachedPieces
    }

    func styled(_ final: String, rules: [LiveFixRule]) -> AttributedString {
        update(final, rules)
        return cachedStyled
    }
}

/// v0.22：點綠底字出來的小卡：原字 → 改成的字、誰改的；可以這場不再改這個詞。
/// v0.23.2：第二行依來源寫「課程對照表改的」或「Haiku 依 p.6／詞表／前後文 改的（程式驗過）」。
private struct LiveFixCard: View {
    let original: String
    let fixed: String
    let rule: LiveFixRule?
    let turnOff: (() -> Void)?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(original).strikethrough().foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                Text(fixed).fontWeight(.semibold)
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("關閉")
            }
            Text(ReviewText.cardSource(rule))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let turnOff {
                Button("這場不再改這個詞", action: turnOff)
                    .font(.callout)
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.systemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(.separator)))
    }
}

// MARK: 準備、下載、轉換中

private struct WorkingView: View {
    let model: AppModel
    let title: String?
    let fraction: Double?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            if let fraction {
                ProgressView(value: fraction.isFinite ? min(1, max(0, fraction)) : 0)
                    .tint(.black)
                Text("\(fraction.isFinite ? Int(min(1, max(0, fraction)) * 100) : 0)%")
                    .font(.system(size: 32, weight: .light, design: .rounded))
                    .monospacedDigit()
            } else {
                ProgressView()
            }
            if let title {
                Text(title).font(.footnote).foregroundStyle(.secondary)
            }
            if !model.liveTail.isEmpty {
                Text(model.liveTail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(8)
                    .padding(.top, 12)
            }
            Spacer()
            RoundIcon(systemName: "xmark", label: "停止", size: 56) {
                model.cancel()
            }
            .padding(.bottom, 8)
        }
    }
}

// MARK: 結果

/// v0.14：夠寬（iPad 橫放）時左邊稿、右邊資訊欄（可收起）；窄的時候（iPhone、iPad 分割畫面）照手機版面。
/// 寬窄看的是 App 實際拿到的寬度，不是裝置，所以分割畫面拉窄也不爆版。
private struct ResultView: View {
    let model: AppModel
    let run: SavedRun
    @AppStorage("sideColumnOpen") private var sideOpen = true
    @State private var renaming = false
    @State private var draftTitle = ""
    /// v0.26.1：模式 1 的場的卡片清單（可分享、拖到別的 App）
    @State private var showCards = false
    /// v0.27.0：討論會續錄前的提醒
    @State private var confirmContinue = false
    /// v0.26.1：iPad 視窗很矮
    @Environment(\.shortWindow) private var short

    /// 這場有卡片（即時模式 1 錄的）
    private var hasCards: Bool {
        FileManager.default.fileExists(atPath: Store.cardsFile(of: run).path)
    }

    /// 【我推論】右欄要稿至少留 520 點才放得下，所以 860 點以上才分兩欄（11 吋 iPad 橫放 1180、直放 820）
    static let wideWidth: CGFloat = 860

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= Self.wideWidth
            let side = min(380, max(280, geo.size.width * 0.32))
            HStack(alignment: .top, spacing: 0) {
                mainColumn(width: wide && sideOpen ? geo.size.width - side - 17 : geo.size.width, wide: wide)
                if wide && sideOpen {
                    Divider()
                        .padding(.horizontal, 8)
                    SideColumn(model: model, run: run)
                        .frame(width: side)
                        .padding(.top, 8)
                }
            }
        }
        .sheet(isPresented: $showCards) {
            ResultCardsSheet(run: run) {
                showCards = false
            }
        }
        .alert("改標題", isPresented: $renaming) {
            TextField("標題", text: $draftTitle)
            Button("好") {
                model.rename(draftTitle)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清空就回到自動的名字。檔名和資料夾不會變。")
        }
    }

    @ViewBuilder
    private func mainColumn(width: CGFloat, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: short ? 4 : 10) {
            // v0.26.1：視窗很矮時收起標題列、狀態字（收起這一場的 ✕ 搬到下面那排）
            if !short {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    // 未命名的錄音用時間當標題；照課表是「11/10 幾何」。點了可改
                    Button {
                        draftTitle = run.title ?? run.displayTitle
                        renaming = true
                    } label: {
                        Text(run.displayTitle)
                            .font(.headline)
                            .foregroundStyle(.black)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("點了可以改標題")
                    if run.course != nil, (run.title ?? "").isEmpty {
                        Text("照課表自動命名（點標題可改）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    MetricsView(run: run)
                }
                Spacer(minLength: 0)
                if wide {
                    SmallCircleButton(systemName: "sidebar.right", label: sideOpen ? "收起右欄" : "打開右欄") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            sideOpen.toggle()
                        }
                    }
                }
                // 收起這一場、回開始畫面。不刪檔
                SmallCircleButton(systemName: "xmark", label: "收起這一場", hint: "回開始畫面，檔案不刪") {
                    model.closeRun()
                }
            }
            .padding(.top, 8)
            Group {
                if let note = model.crashNote {
                    CrashLine(model: model, note: note)
                }
                Text(model.warmNote)
                Text(model.appleAIStatus)
                Text(model.versionLine)
                if let note = model.arrangeNote {
                    Text(note).textSelection(.enabled)
                }
                if let note = model.exportNote {
                    Text(note).textSelection(.enabled)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            }
            if case .failed(let message) = model.phase {
                FailureLine(message: message)
            }
            if !short {
                Divider()
            }
            // 點一下＝從那句播、點兩下＝標記、按住＝選字（可拖到別的 App）、Pencil 畫過＝標記
            TranscriptPane(model: model, text: run.text)
            if !(wide && sideOpen) {
                PlayerStrip(model: model)
            }
            bottomBar(width: width)
        }
        .frame(width: max(0, width), alignment: .leading)
    }

    /// 窄的時候圓鈕跟著縮（iPad 分割畫面最窄約 320 點），不擠出畫面。
    private func bottomBar(width: CGFloat) -> some View {
        let gap: CGFloat = width < 340 ? 4 : 8
        let count: CGFloat = 5 + (hasCards ? 1 : 0) + (short ? 1 : 0)
        let size = short ? 30 : max(32, min(46, (width - 64 - gap * count) / count))
        return HStack(spacing: gap) {
            if short {
                SmallCircleButton(systemName: "xmark", label: "收起這一場", hint: "回開始畫面，檔案不刪") {
                    model.closeRun()
                }
            }
            // 結果畫面左下角的麥克風＝接著這一場錄。錄新的一場要先按 ✕ 回開始畫面
            RoundIcon(systemName: "mic.fill", label: "繼續錄", size: size, badge: .symbol("plus")) {
                if model.needsSceneConfirm {
                    confirmContinue = true
                } else {
                    model.continueRecording()
                }
            }
            .confirmationDialog(RecordScene.confirmTitle, isPresented: $confirmContinue, titleVisibility: .visible) {
                Button("開始錄音") {
                    model.continueRecording()
                }
                Button("取消", role: .cancel) {}
            }
            // v0.16：電腦傳來的稿沒有手機的錄音，不能接著錄（按了也只會說明）
            .opacity(model.run?.origin == nil ? 1 : 0.3)
            RoundIcon(systemName: "folder", label: "選檔案", size: size) {
                model.showImporter = true
            }
            RoundIcon(systemName: "text.alignleft", label: "用蘋果 AI 分段", size: size) {
                model.arrangeWithAppleAI()
            }
            SceneMenu(model: model, size: size)
            FixMenu(model: model, size: size)
            // v0.26.1：模式 1 的場：看卡片、分享到別的 App
            if hasCards {
                RoundIcon(systemName: "rectangle.stack", label: "看卡片（可分享到別的 App）", size: size) {
                    showCards = true
                }
            }
            Spacer(minLength: 0)
            CopyButton(model: model)
        }
        .padding(.bottom, short ? 2 : 8)
    }
}

/// 只有這一塊讀播放位置，播放時每 0.25 秒更新不會帶著整個結果畫面重畫。
private struct TranscriptPane: View {
    let model: AppModel
    let text: String

    var body: some View {
        TranscriptView(
            text: text,
            map: model.map,
            marked: model.markedSentences,
            playing: model.playingSentence,
            jump: model.jump,
            onTap: { model.tapSentence($0) },
            onDoubleTap: { model.toggleMark($0) },
            onStroke: { model.markStroke($0) }
        )
    }
}

/// 小播放條：▶ 0:32 ———— 1:48:02。手機在稿的下面（點過一句才出現）；iPad 右欄打開時在右欄最上面（一直在）。
private struct PlayerStrip: View {
    let model: AppModel
    var alwaysShow = false

    var body: some View {
        let player = model.player
        VStack(alignment: .leading, spacing: 4) {
            if alwaysShow, !player.hasAudio {
                Text("這場的錄音不在 App 裡（選來的檔轉完就刪了），不能播")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if let note = model.playNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if player.isActive || alwaysShow {
                    controls(player)
                }
            }
        }
    }

    private func controls(_ player: Playback) -> some View {
        let total = max(player.total, 0.1)
        return HStack(spacing: 8) {
            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.black)
            .accessibilityLabel(player.isPlaying ? "暫停" : "播放")
            Text(formatClock(player.position))
                .monospacedDigit()
            Slider(
                value: Binding(get: { min(player.position, total) }, set: { model.seekPlayback(to: $0) }),
                in: 0...total
            )
            .tint(.black)
            .accessibilityLabel("播放位置")
            Text(formatClock(player.total))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if !alwaysShow {
                Button {
                    model.stopPlayback()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.secondary)
                .accessibilityLabel("收起播放條")
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.12), lineWidth: 1))
    }
}

/// iPad 右欄：播放條、可疑的字、標記的句子、講者。點一列，稿捲到那句。
private struct SideColumn: View {
    let model: AppModel
    let run: SavedRun

    var body: some View {
        let map = model.map
        let marks = model.marks
        VStack(alignment: .leading, spacing: 6) {
            PlayerStrip(model: model, alwaysShow: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    SideHeading(text: "可疑的字（點了跳過去）")
                    if map.suspects.isEmpty {
                        SideNote(text: run.fixInfo == nil ? "這場沒開校正" : "沒有標到可疑的字")
                    }
                    ForEach(Array(map.suspects.prefix(300).enumerated()), id: \.offset) { _, note in
                        SideRow(text: note.label, time: time(of: note.sentence, in: map)) {
                            model.jumpTo(sentence: note.sentence)
                        }
                    }
                    SideHeading(text: "標記的句子（點兩下或 Pencil 畫過）")
                    if marks.isEmpty {
                        SideNote(text: "還沒有。點兩下一句，或用 Pencil 在字上畫過去")
                    }
                    ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                        SideRow(text: "「\(String(mark.text.prefix(40)))」", time: mark.start.map(formatClock)) {
                            if let index = map.sentence(containingContent: mark.at) {
                                model.jumpTo(sentence: index)
                            }
                        }
                    }
                    SideHeading(text: "講者")
                    ForEach(speakerLines, id: \.self) { line in
                        SideNote(text: line)
                    }
                    if let info = run.speakerInfo {
                        Text(info)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                }
            }
        }
        .task(id: "\(run.startedStamp)|\(run.parts?.count ?? 1)") {
            await model.loadPlayback()
        }
    }

    private func time(of sentence: Int, in map: TranscriptMap) -> String? {
        guard sentence >= 0, sentence < map.sentences.count else { return nil }
        return map.sentences[sentence].start.map(formatClock)
    }

    private var speakerLines: [String] {
        guard let speakers = run.speakers, !speakers.isEmpty else { return ["沒有分人"] }
        let lines = run.text.components(separatedBy: "\n")
        return speakers.map { name in
            "\(name)：\(lines.filter { $0.hasPrefix(name + "：") }.count) 段"
        }
    }
}

private struct SideHeading: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}

private struct SideNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 3)
    }
}

private struct SideRow: View {
    let text: String
    let time: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.black)
                Spacer(minLength: 6)
                if let time {
                    Text(time)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// 右上角的小細框圓鈕（✕、收起右欄）。
private struct SmallCircleButton: View {
    let systemName: String
    let label: String
    var hint: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(.black)
                .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 1))
                .contentShape(Circle())
        }
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }
}

/// 黑色鈕：點一下複製全文；長按出匯出選單。
private struct CopyButton: View {
    let model: AppModel
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.title2)
                .frame(width: 64, height: 64)
                .foregroundStyle(.white)
                .background(Circle().fill(.black))
        }
        .accessibilityLabel("複製全文")
        .accessibilityHint("長按可以匯出")
        .contentShape(.contextMenuPreview, Circle())
        .contextMenu {
            Button(action: copy) {
                Label("複製全文", systemImage: "doc.on.doc")
            }
            // v0.21：檔名固定成原始轉錄的格式：<匯出資料夾>/<課名>/ 放得進去的 txt
            if let name = model.rawRecordName {
                Button {
                    model.export(.classRecord)
                } label: {
                    Label {
                        Text("存成原始轉錄")
                        Text(name)
                    } icon: {
                        Image(systemName: "doc.text")
                    }
                }
            }
            Button {
                model.export(.session)
            } label: {
                Label {
                    Text("匯出這一場")
                    Text("稿、時間檔、分人、校正紀錄、版本")
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            if let size = model.audioSizeMB {
                Button {
                    model.export(.withAudio)
                } label: {
                    Label {
                        Text("匯出（含錄音）")
                        Text("多約 \(max(size, 1)) MB，有錄到的每個人的聲音")
                    } icon: {
                        Image(systemName: "waveform")
                    }
                }
            } else {
                Button {} label: {
                    Label {
                        Text("匯出（含錄音）")
                        Text("這場的錄音不在 App 裡（選來的檔轉完就刪了）")
                    } icon: {
                        Image(systemName: "waveform")
                    }
                }
                .disabled(true)
            }
            Button {
                model.export(.errorsOnly)
            } label: {
                Label {
                    Text("只傳錯誤資料")
                    Text("不含稿和錄音")
                } icon: {
                    Image(systemName: "ladybug")
                }
            }
        }
    }

    private func copy() {
        model.copyText()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// 閃退那行：不用截圖，直接傳錯誤資料（不含稿和聲音）。
private struct CrashLine: View {
    let model: AppModel
    let note: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(note).foregroundStyle(.red).textSelection(.enabled)
            Button {
                model.export(.errorsOnly)
            } label: {
                Text("傳錯誤資料").underline()
            }
            .foregroundStyle(.blue)
            .accessibilityHint("不含稿和錄音")
        }
    }
}

/// 系統分享畫面。
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onDone()
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// 要看得到引擎、實際語言、音檔長度、轉換秒數、倍速。
private struct MetricsView: View {
    let run: SavedRun

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(run.engine) · \(run.language) · iOS \(run.systemVersion)")
            Text(numbers)
            Text(run.origin == nil ? run.source : "電腦傳來的稿（聲音在電腦，手機沒有錄音）").lineLimit(1)
            if let info = run.liveInfo {
                Text(info).textSelection(.enabled)
            }
            if let info = run.speakerInfo {
                Text(info).textSelection(.enabled)
            }
            if let info = run.fixInfo {
                Text(info).textSelection(.enabled)
            }
            if !run.finished {
                Text("沒有轉完，這裡只有已出來的字").foregroundStyle(.red)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private var numbers: String {
        var parts: [String] = []
        if let audio = run.audioSeconds {
            parts.append("音檔 \(formatClock(audio))")
        }
        if let convert = run.convertSeconds {
            parts.append(String(format: "轉換 %.1f 秒", convert))
            if let audio = run.audioSeconds, convert > 0 {
                parts.append(String(format: "%.1f 倍速", audio / convert))
            }
        }
        return parts.joined(separator: " · ")
    }
}

struct FailureLine: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(message).textSelection(.enabled)
        }
        .font(.footnote)
        .foregroundStyle(.red)
    }
}

/// v0.27.0 場景：上課／討論會／聊天（取代原本的「情境（人數）」和「即時模式」）。討論會、聊天可以再選人數。
/// 下一次錄音或選檔才生效（選檔的分人人數也照這個）。
private struct SceneMenu: View {
    let model: AppModel
    let size: CGFloat

    var body: some View {
        Menu {
            Picker("場景", selection: Binding(get: { model.scene }, set: { model.scene = $0 })) {
                ForEach(RecordScene.allCases, id: \.self) { scene in
                    Label("\(scene.title)：\(scene.detail)", systemImage: scene.symbol).tag(scene)
                }
            }
            if model.scene != .lecture {
                Picker("人數", selection: Binding(get: { model.speakerMode }, set: { model.setSceneSpeakers($0) })) {
                    Text("自動（人數可能少算）").tag(-1)
                    Text("2 人").tag(2)
                    Text("3 人").tag(3)
                    Text("4 人").tag(4)
                    Text("5 人").tag(5)
                    Text("6 人").tag(6)
                    Text("8 人").tag(8)
                    Text("10 人").tag(10)
                }
                .pickerStyle(.menu)
            }
        } label: {
            // 場景用圖示表示；討論會、聊天的人數放角落（自動＝問號）
            switch model.scene {
            case .lecture:
                RoundGlyph(systemName: model.scene.symbol, size: size)
            case .discussion, .chat:
                RoundGlyph(systemName: model.scene.symbol, size: size,
                           badge: .text(model.speakerMode < 0 ? "?" : "\(model.speakerMode)"))
            }
        }
        .menuOrder(.fixed)
        .accessibilityLabel("場景，現在是\(model.scene.title)、\(model.speakerModeLabel)")
    }
}

/// 校正開關。下一次錄音或選檔才生效。
private struct FixMenu: View {
    let model: AppModel
    let size: CGFloat

    var body: some View {
        Menu {
            Picker("校正", selection: Binding(get: { model.fixMode }, set: { model.fixMode = $0 })) {
                Text("校正：關閉").tag(0)
                Text("離線校正（蘋果 AI 標可能的同音字，不改字）").tag(1)
                Text("智慧校正（蘋果 AI 挑詞、查維基，不改字）").tag(2)
            }
        } label: {
            // 關＝加一條斜線、離線＝原樣、智慧＝角落小地球（會查維基）
            switch min(max(model.fixMode, 0), 2) {
            case 0: RoundGlyph(systemName: "textformat.abc.dottedunderline", size: size, slashed: true)
            case 1: RoundGlyph(systemName: "textformat.abc.dottedunderline", size: size)
            default: RoundGlyph(systemName: "textformat.abc.dottedunderline", size: size, badge: .symbol("globe"))
            }
        }
        .accessibilityLabel(["校正關閉", "離線校正打開", "智慧校正打開"][min(max(model.fixMode, 0), 2)])
    }
}

struct RoundIcon: View {
    let systemName: String
    let label: String
    let size: CGFloat
    var badge: CornerBadge.Kind? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundGlyph(systemName: systemName, size: size, badge: badge)
        }
        .accessibilityLabel(label)
    }
}

/// 細框圓裡一個 SF Symbol，可加右下角小標或一條斜線。（v0.15 連電腦畫面也用，所以不是 private）
struct RoundGlyph: View {
    let systemName: String
    let size: CGFloat
    var badge: CornerBadge.Kind? = nil
    var slashed = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.38))
            .overlay {
                if slashed {
                    // 不靠 .slash 變體（這個圖示有沒有不確定），自己疊一條線；白邊讓線和字分得開
                    ZStack {
                        Capsule().fill(.white).frame(width: 4, height: size * 0.62)
                        Capsule().fill(.black).frame(width: 1.6, height: size * 0.62)
                    }
                    .rotationEffect(.degrees(45))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    CornerBadge(kind: badge, size: size)
                        .offset(x: size * 0.13, y: size * 0.1)
                }
            }
            .frame(width: size, height: size)
            .foregroundStyle(.black)
            .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 1))
            .contentShape(Circle())
    }
}

/// 圖示右下角的小標：數字、問號（黑底白字），或加號、地球（白底黑框）。
struct CornerBadge: View {
    enum Kind {
        case text(String)
        case symbol(String)
    }

    let kind: Kind
    let size: CGFloat

    var body: some View {
        let side = max(12, size * 0.28)
        switch kind {
        case .text(let text):
            Text(text)
                .font(.system(size: side * 0.68, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, side * 0.18)
                .frame(minWidth: side, minHeight: side)
                .background(Capsule().fill(.black))
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: side * 0.58, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: side, height: side)
                .background(Circle().fill(.white))
                .overlay(Circle().stroke(Color.black, lineWidth: 1))
        }
    }
}

/// 幾小時的課字很多，用 UITextView（SwiftUI 的 Text 字太多會卡）。可選取、不可編輯。
/// v0.14：
/// - 點一下＝從那句播放（要等系統確定不是點兩下，約 0.3 秒；用「單擊要等雙擊失敗」做，不是自己計時）
/// - 點兩下＝標記／取消標記（底色）；系統自己的「點兩下選一個詞」讓給這個
/// - 按住＝系統選字，選好可以拖到別的 App（textDragInteraction，iPhone 預設關，這裡打開）
/// - Apple Pencil：看 UITouch 的種類分開。捲動只認手指、滑鼠、觸控板；Pencil 的筆觸不捲動，畫完不留筆跡，
///   算出筆跡蓋到哪幾句就標記哪幾句（和點兩下一樣）。iPhone 沒有 Pencil，這個手勢永遠不會開始。
private struct TranscriptView: UIViewRepresentable {
    let text: String
    let map: TranscriptMap
    let marked: Set<Int>
    let playing: Int?
    let jump: JumpRequest?
    let onTap: (Int) -> Void
    let onDoubleTap: (Int) -> Void
    let onStroke: ([Int]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .white
        view.textColor = .black
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        // 按住選好的字可以拖到別的 App（iPhone 預設關）
        view.textDragInteraction?.isEnabled = true
        // 捲動只認手指和滑鼠、觸控板；Pencil 留給標記
        view.panGestureRecognizer.allowedTouchTypes = [
            UITouch.TouchType.direct, UITouch.TouchType.indirect, UITouch.TouchType.indirectPointer,
        ].map { NSNumber(value: $0.rawValue) }
        context.coordinator.attach(to: view)
        // 重新建畫面時，上一次的「跳到那句」不要再跳一次
        context.coordinator.lastJump = jump?.id
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(view)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TranscriptView?
        var lastJump: UUID?
        private weak var view: UITextView?
        private var shownText: String?
        private var applied: [Int: UIColor] = [:]
        private var single: UITapGestureRecognizer?
        private var double: UITapGestureRecognizer?
        private var pencil: UIPanGestureRecognizer?
        private var tuned = Set<ObjectIdentifier>()
        private var hadSelection = false
        private var strokePoints: [CGPoint] = []
        private var strokeLayer: CAShapeLayer?

        private static let markColor = UIColor(red: 1.0, green: 0.88, blue: 0.40, alpha: 0.55)
        private static let playColor = UIColor(white: 0, alpha: 0.08)
        private static let bothColor = UIColor(red: 1.0, green: 0.78, blue: 0.28, alpha: 0.75)

        func attach(to view: UITextView) {
            self.view = view
            let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
            double.numberOfTapsRequired = 2
            double.delegate = self
            let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped(_:)))
            single.require(toFail: double)
            single.delegate = self
            let pencil = UIPanGestureRecognizer(target: self, action: #selector(stroked(_:)))
            pencil.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            pencil.maximumNumberOfTouches = 1
            pencil.delegate = self
            view.addGestureRecognizer(double)
            view.addGestureRecognizer(single)
            view.addGestureRecognizer(pencil)
            self.double = double
            self.single = single
            self.pencil = pencil
        }

        func update(_ view: UITextView) {
            guard let parent else { return }
            tuneSystemDoubleTap(view)
            if shownText != parent.text {
                shownText = parent.text
                // 間距太小不好讀
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 7
                style.paragraphSpacing = 6
                view.attributedText = NSAttributedString(string: parent.text, attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: UIColor.black,
                    .paragraphStyle: style,
                ])
                applied = [:]
            }
            applyHighlights(view)
            if let jump = parent.jump, jump.id != lastJump {
                lastJump = jump.id
                scroll(to: jump.range, in: view)
            }
        }

        /// 系統的「點兩下選一個詞」要等我們的點兩下失敗才算，點兩下就只會標記。找不到也不會壞，只是會多選一個詞（下面會清掉）。
        private func tuneSystemDoubleTap(_ view: UITextView) {
            guard let double else { return }
            for recognizer in view.gestureRecognizers ?? [] {
                guard recognizer !== double, recognizer !== single, recognizer !== pencil,
                      let tap = recognizer as? UITapGestureRecognizer, tap.numberOfTapsRequired == 2,
                      !tuned.contains(ObjectIdentifier(tap)) else { continue }
                tuned.insert(ObjectIdentifier(tap))
                tap.require(toFail: double)
            }
        }

        // MARK: 底色：標記（黃）、正在播（淡灰）

        private func applyHighlights(_ view: UITextView) {
            guard let parent else { return }
            let storage = view.textStorage
            var want: [Int: UIColor] = [:]
            // 表和畫面上的字長度不同（還沒重算）就先不畫，免得畫錯位置
            if parent.map.utf16Count == storage.length {
                let count = parent.map.sentences.count
                for index in parent.marked where index < count {
                    want[index] = Self.markColor
                }
                if let playing = parent.playing, playing < count {
                    want[playing] = want[playing] == nil ? Self.playColor : Self.bothColor
                }
            }
            guard want != applied else { return }
            storage.beginEditing()
            for index in applied.keys where want[index] == nil {
                if let range = nsRange(of: index, length: storage.length) {
                    storage.removeAttribute(.backgroundColor, range: range)
                }
            }
            for (index, color) in want where applied[index] != color {
                if let range = nsRange(of: index, length: storage.length) {
                    storage.addAttribute(.backgroundColor, value: color, range: range)
                }
            }
            storage.endEditing()
            applied = want
        }

        private func nsRange(of index: Int, length: Int) -> NSRange? {
            guard let parent, index >= 0, index < parent.map.sentences.count else { return nil }
            let sentence = parent.map.sentences[index]
            guard sentence.end <= length else { return nil }
            return NSRange(location: sentence.location, length: sentence.length)
        }

        // MARK: 手勢

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Pencil 的筆觸不和其他手勢一起（不選字、不捲動）；點一下、點兩下和系統手勢一起認，系統的選字照常
            if gestureRecognizer === pencil || other === pencil { return false }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer === single {
                // 有選字時點一下是在取消選字，不播放
                hadSelection = (view?.selectedRange.length ?? 0) > 0
            }
            return true
        }

        @objc private func singleTapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view, !hadSelection else { return }
            guard let index = sentence(at: recognizer.location(in: view), in: view) else { return }
            parent?.onTap(index)
        }

        @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view else { return }
            guard let index = sentence(at: recognizer.location(in: view), in: view) else { return }
            parent?.onDoubleTap(index)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            clearSelection(view)
        }

        /// 系統如果還是選了一個詞，拿掉，免得下一次點一下被當成「取消選字」。
        private func clearSelection(_ view: UITextView) {
            Task { @MainActor [weak view] in
                guard let view, view.selectedRange.length > 0 else { return }
                view.selectedRange = NSRange(location: view.selectedRange.location, length: 0)
            }
        }

        /// 點的地方是哪一句；點在稿的空白處（最後一行下面）是 nil。
        private func sentence(at point: CGPoint, in view: UITextView) -> Int? {
            guard let parent, parent.map.utf16Count == view.textStorage.length else { return nil }
            let begin = view.beginningOfDocument
            if let character = view.characterRange(at: point) {
                return parent.map.sentence(atUTF16: view.offset(from: begin, to: character.start))
            }
            guard let position = view.closestPosition(to: point) else { return nil }
            let caret = view.caretRect(for: position)
            if !caret.isNull, point.y < caret.minY - 16 || point.y > caret.maxY + 16 {
                return nil
            }
            return parent.map.sentence(atUTF16: view.offset(from: begin, to: position))
        }

        // MARK: Apple Pencil

        @objc private func stroked(_ recognizer: UIPanGestureRecognizer) {
            guard let view else { return }
            let point = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                strokePoints = [point]
                // 畫的時候有一條淡橘線看得到畫到哪，放開就消失（不留筆跡）
                let layer = CAShapeLayer()
                layer.strokeColor = UIColor.systemOrange.withAlphaComponent(0.7).cgColor
                layer.fillColor = nil
                layer.lineWidth = 3
                layer.lineCap = .round
                layer.lineJoin = .round
                view.layer.addSublayer(layer)
                strokeLayer = layer
                drawStroke()
            case .changed:
                strokePoints.append(point)
                drawStroke()
            case .ended:
                strokePoints.append(point)
                finishStroke(in: view)
                clearStroke()
            default:
                clearStroke()
            }
        }

        private func drawStroke() {
            guard let first = strokePoints.first, let strokeLayer else { return }
            let path = UIBezierPath()
            path.move(to: first)
            for point in strokePoints.dropFirst() {
                path.addLine(to: point)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            strokeLayer.path = path.cgPath
            CATransaction.commit()
        }

        private func clearStroke() {
            strokeLayer?.removeFromSuperlayer()
            strokeLayer = nil
            strokePoints = []
        }

        /// 筆跡的外框蓋到哪幾句：每一句的每一行，和外框重疊超過半行高就算。畫底線（扁的）往上算一行。都沒有就算外框中間那句。
        private func finishStroke(in view: UITextView) {
            guard let parent, parent.map.utf16Count == view.textStorage.length, !strokePoints.isEmpty else { return }
            let xs = strokePoints.map(\.x)
            let ys = strokePoints.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
            var rect = CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
            let lineHeight = view.font?.lineHeight ?? 22
            if rect.height < lineHeight * 0.6 {
                rect = CGRect(x: rect.minX, y: rect.minY - lineHeight * 0.8, width: rect.width, height: rect.height + lineHeight * 0.8)
            }
            let begin = view.beginningOfDocument
            let step = max(1, strokePoints.count / 40)
            var samples = stride(from: 0, to: strokePoints.count, by: step).map { strokePoints[$0] }
            samples += [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.midY)]
            var low = Int.max
            var high = Int.min
            for sample in samples {
                guard let position = view.closestPosition(to: sample) else { continue }
                let offset = view.offset(from: begin, to: position)
                low = min(low, offset)
                high = max(high, offset)
            }
            guard low <= high else { return }
            var hit: [Int] = []
            for index in parent.map.sentences(from: low, to: high).prefix(300) {
                let sentence = parent.map.sentences[index]
                guard let start = view.position(from: begin, offset: sentence.location),
                      let end = view.position(from: start, offset: sentence.length),
                      let range = view.textRange(from: start, to: end) else { continue }
                let covered = view.selectionRects(for: range).contains { item in
                    let line = item.rect
                    let overlap = line.intersection(rect)
                    return !overlap.isNull && overlap.width >= 6 && overlap.height >= line.height * 0.5
                }
                if covered {
                    hit.append(index)
                }
            }
            if hit.isEmpty, let center = sentence(at: CGPoint(x: rect.midX, y: rect.midY), in: view) {
                hit = [center]
            }
            guard !hit.isEmpty else { return }
            parent.onStroke(hit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        // MARK: 右欄點了跳過去

        private func scroll(to range: NSRange, in view: UITextView) {
            guard range.location + range.length <= view.textStorage.length,
                  let start = view.position(from: view.beginningOfDocument, offset: range.location),
                  let end = view.position(from: start, offset: range.length),
                  let textRange = view.textRange(from: start, to: end) else { return }
            view.scrollRangeToVisible(range)   // 先讓那一段排好版，下面的位置才準
            view.layoutIfNeeded()
            let rect = view.firstRect(for: textRange)
            guard !rect.isNull, !rect.isInfinite else { return }
            let top = -view.adjustedContentInset.top
            let bottom = max(top, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
            let y = min(max(top, rect.minY - view.bounds.height * 0.3), bottom)
            view.setContentOffset(CGPoint(x: view.contentOffset.x, y: y), animated: false)
            flash(textRange, in: view)
        }

        /// 跳過去的那句閃一下淡橘色。
        private func flash(_ range: UITextRange, in view: UITextView) {
            let rects = view.selectionRects(for: range).map(\.rect).filter { !$0.isNull && $0.width > 0 }
            guard !rects.isEmpty else { return }
            let path = UIBezierPath()
            for rect in rects {
                path.append(UIBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -1), cornerRadius: 4))
            }
            let layer = CAShapeLayer()
            layer.path = path.cgPath
            layer.fillColor = UIColor.systemOrange.withAlphaComponent(0.3).cgColor
            view.layer.addSublayer(layer)
            Task { @MainActor [weak layer] in
                try? await Task.sleep(for: .seconds(1.4))
                layer?.removeFromSuperlayer()
            }
        }
    }
}

func formatClock(_ seconds: Double) -> String {
    // 不是數字或太大（壞掉的檔）時 Int(...) 會讓 App 直接閃退，先擋
    guard seconds.isFinite, abs(seconds) < 1e9 else { return "?" }
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let rest = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, rest)
    }
    return String(format: "%d:%02d", minutes, rest)
}
