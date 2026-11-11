import AVFoundation
import SwiftUI
import UIKit

// v0.15 連電腦畫面：掃 QR → 選用法 → 收音狀態（音量條、傳了多久、斷線與重連）。樣式照開始畫面：白底、細框圓鈕。
// v0.16：電腦（v5.27 起，協定 v3）傳來的即時稿放在畫面中間，樣式跟 App 自己錄音時的 LiveText 一樣（黑字定稿、灰字還可能改、
// 一直停在最新一行）；音量條和連線狀態縮成上方一行小字。電腦是舊版就照舊只有狀態和音量條，並寫「電腦版要更新才看得到字」。
// v0.17：電腦（v5.29 起，協定 v4）傳來的叫 Claude 對話放在稿下面一條（ClaudeStrip）：平常只寫最新一則兩行，新回覆來時亮起來、
// 多露幾行，點了從下面拉出整段對話（照電腦網頁的樣子：右側淡底泡泡＝他叫 Claude、左側「Claude」＋回覆），稿不會被擠掉。
// 連不上時手機在行動網路就直接寫「手機現在用 4G／行動網路」。

/// Claude 的字色（跟電腦網頁的 accent 一樣是偏橘的褐色）。
private let claudeAccent = Color(red: 0.76, green: 0.39, blue: 0.24)

struct LinkView: View {
    let link: PhoneLink
    let close: () -> Void
    /// v0.16：把電腦錄完的稿存成手機上的一場，回傳給他看的一句話。
    let save: () -> String

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("連電腦")
                        .font(.headline)
                    Spacer()
                    RoundIcon(systemName: "xmark", label: "關閉連電腦", size: 40) {
                        close()
                    }
                }
                .padding(.top, 8)
                content
                    .frame(maxWidth: 520)
            }
            .padding(.horizontal, 20)
        }
        .foregroundStyle(.black)
    }

    @ViewBuilder
    private var content: some View {
        switch link.stage {
        case .scanning:
            ScanStep(link: link)
        case .choosing:
            ChooseStep(link: link)
        case .connecting, .connected, .lost:
            LiveStep(link: link, save: save)
        case .ended:
            EndedStep(link: link, close: close, save: save)
        }
    }
}

// MARK: 掃 QR 碼

private struct ScanStep: View {
    let link: PhoneLink
    @State private var allowed: Bool?

    var body: some View {
        VStack(spacing: 16) {
            Text("在電腦的設定按「連手機」，把相機對準畫面上的 QR 碼")
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
            Group {
                if allowed == false {
                    VStack(spacing: 12) {
                        Image(systemName: "camera")
                            .font(.system(size: 32))
                        Text("沒有相機權限。到「設定 > 轉文字 > 相機」打開，或用下面的「貼上網址」。")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                        Button("打開設定") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                    .padding()
                } else if allowed == true {
                    QRScanner { code in
                        link.scanned(code)
                    } onError: { message in
                        link.scanFailed(message)
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background(Color.black.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.black.opacity(0.25), lineWidth: 1))
            if let error = link.scanError {
                FailureLine(message: error)
            }
            Button("沒辦法掃？貼上電腦給的網址") {
                if let text = UIPasteboard.general.string {
                    link.scanned(text)
                } else {
                    link.scanFailed("剪貼簿裡沒有網址")
                }
            }
            .font(.footnote)
            Text("連上之後聲音只傳到這台電腦（同一個 Wi-Fi），用 QR 碼裡的憑證指紋確認是它。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                allowed = true
            case .notDetermined:
                allowed = await AVCaptureDevice.requestAccess(for: .video)
            default:
                allowed = false
            }
        }
    }
}

// MARK: 選用法

private struct ChooseStep: View {
    let link: PhoneLink

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let target = link.target {
                Text("找到電腦 \(target.label)。這支手機要怎麼收？")
                    .font(.callout)
                    .padding(.top, 16)
            }
            ForEach(LinkUse.allCases, id: \.self) { use in
                Button {
                    link.connect(using: use)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: use == .split ? "person.2" : "iphone")
                            .font(.system(size: 22))
                            .frame(width: 44, height: 44)
                            .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 1))
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(use.title).font(.headline)
                                if use == link.use {
                                    Text("上次用的").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Text(use.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.25), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("手機這邊不轉文字，字在電腦上出來（電腦版 v5.27 起字會傳回手機顯示，v5.29 起 Claude 的回覆也會）。電腦按開始錄音後手機才傳聲音。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("重新掃描") {
                link.beginScan()
            }
            .font(.footnote)
            Spacer()
        }
    }
}

// MARK: 連著

private struct LiveStep: View {
    let link: PhoneLink
    let save: () -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if link.pc.supported == true {
                // v0.16：電腦會送稿——狀態縮成上方一行小字，中間放電腦的稿
                CompactStatus(link: link)
                    .padding(.top, 8)
                PCTextPane(pc: link.pc)
                ClaudeStrip(link: link)
                SaveRow(pc: link.pc, save: save)
            } else {
                status
                    .padding(.top, 20)
                LevelBar(level: link.level, dimmed: !(link.stage == .connected && link.pcRecording))
                details
                if link.pc.supported == false {
                    // 電腦是 v5.26 以前（協定 v1／v2），不會送稿
                    Label("電腦版要更新才看得到字和 Claude 回覆（電腦版 v5.27 起傳稿、v5.29 起傳 Claude 回覆）", systemImage: "arrow.up.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Picker("用法", selection: Binding(get: { link.use }, set: { link.change(to: $0) })) {
                ForEach(LinkUse.allCases, id: \.self) { use in
                    Text(use.title).tag(use)
                }
            }
            .pickerStyle(.segmented)
            .disabled(link.pcRecording)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                RoundIcon(systemName: "stop.fill", label: "停止收音", size: link.pc.supported == true ? 52 : 64) {
                    link.stop()
                }
                Spacer()
            }
            .padding(.bottom, 12)
        }
    }

    private var caption: String {
        if link.pcRecording {
            return "電腦錄音中不能換用法，按結束後再換。"
        }
        if link.pc.supported == true {
            return "字是電腦轉的，傳到手機只能看、不能改（改字、改人在電腦上）。可以鎖螢幕，鎖了也繼續收。"
        }
        return "手機這邊不轉文字，字在電腦上。可以鎖螢幕，鎖了也繼續收。"
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("用法：\(link.use.title)")
            Text("已傳到電腦 \(formatClock(link.sentSeconds))")
            if let rtt = link.rttMs {
                Text("網路來回 \(rtt) 毫秒")
            }
            LinkNotes(link: link)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    @ViewBuilder
    private var status: some View {
        switch link.stage {
        case .lost:
            VStack(alignment: .leading, spacing: 6) {
                Label("連線中斷", systemImage: "wifi.exclamationmark")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.red)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let since = link.lostSince {
                        Text("已斷 \(Int(context.date.timeIntervalSince(since))) 秒。手機先留最近 3 秒，接上會補送；更久的那段電腦會補靜音")
                    }
                }
                .font(.footnote)
                if let hint = link.networkHint {
                    NetworkHintLine(text: hint)
                }
                if let note = link.note {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            }
        case .connecting:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("連電腦中…").font(.title3)
                }
                if let hint = link.networkHint {
                    NetworkHintLine(text: hint)
                }
                if let note = link.note {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            }
        default:
            if link.pcRecording {
                Label("收音中，傳到電腦", systemImage: "dot.radiowaves.left.and.right")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("已連上電腦", systemImage: "checkmark.circle")
                        .font(.title2.weight(.semibold))
                    Text("麥克風開著，等電腦按開始錄音才傳聲音")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 斷過幾次、接上時少了幾秒、電腦的提醒。少幾秒以電腦算的為準（協定 v2 的 gap），舊電腦才用手機自己算的。
private struct LinkNotes: View {
    let link: PhoneLink

    var body: some View {
        if link.drops > 0 {
            if let total = link.pcLostTotal {
                Text(String(format: "斷過 %ld 次，這場共少約 %.0f 秒（電腦算的）", link.drops, total))
            } else {
                Text("斷過 \(link.drops) 次，共\(LinkText.lost(samples: link.lostTotalSamples))")
            }
        }
        if let resume = link.resumeNote {
            Text(resume)
        }
        if let warning = link.warning {
            Text("電腦提醒：\(warning)").foregroundStyle(.orange)
        }
    }
}

/// v0.16：連線狀態和音量條縮成上方一行小字（電腦會送稿時，中間要留給稿）。
private struct CompactStatus: View {
    let link: PhoneLink

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                headline
                LevelBar(level: link.level, dimmed: !(link.stage == .connected && link.pcRecording))
                    .frame(width: 64)
                Spacer(minLength: 0)
                Text(trailing)
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
            .lineLimit(1)
            LinkNotes(link: link)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let hint = link.networkHint {
                NetworkHintLine(text: hint)
            }
            if link.stage != .connected, let note = link.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
    }

    @ViewBuilder
    private var headline: some View {
        switch link.stage {
        case .lost:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label(lostText(at: context.date), systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.red)
            }
        case .connecting:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("連電腦中…")
            }
        default:
            if link.pcRecording {
                Label("收音中", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
            } else {
                Label("已連上", systemImage: "checkmark.circle")
            }
        }
    }

    private func lostText(at date: Date) -> String {
        guard let since = link.lostSince else { return "連線中斷" }
        return "連線中斷 \(Int(date.timeIntervalSince(since))) 秒"
    }

    /// 右邊：電腦在幹嘛、傳了多久、網路多快。
    private var trailing: String {
        var parts: [String] = []
        switch link.pc.rec {
        case .recording:
            parts.append("電腦錄音中")
        case .processing:
            if let eta = link.pc.eta, eta > 0 {
                parts.append("電腦整理中，約 \(Int(eta.rounded())) 秒")
            } else {
                parts.append("電腦整理中")
            }
        case .idle:
            break
        }
        if link.sentSeconds > 0 {
            parts.append("已傳 \(formatClock(link.sentSeconds))")
        }
        if let rtt = link.rttMs {
            parts.append("\(rtt) ms")
        }
        return parts.joined(separator: " · ")
    }
}

/// v0.16：電腦傳來的稿。樣式跟 App 自己錄音一樣（LiveText）：黑字定稿、灰字電腦還可能改，一直停在最新一行。
private struct PCTextPane: View {
    let pc: PCTranscript

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let note = stageNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !pc.received {
                placeholder("等電腦傳稿…")
            } else if pc.isEmpty {
                placeholder(pc.rec == .recording ? "電腦正在聽…" : "電腦還沒有稿。電腦按開始錄音後，字會出現在這裡")
            } else {
                // 跟錄音中一樣只放最後 3000 字（幾小時的課字很多）；整份存成一場後看
                LiveText(final: String(pc.finalText.suffix(PCTranscript.tailChars)), volatile: pc.volatileText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .foregroundStyle(.gray)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var stageNote: String? {
        var note: String?
        switch pc.stage {
        case "labelled":
            note = "電腦分好人了，講者寫在每段前面"
        case "final":
            note = "電腦定稿了（整句重聽過的字）"
        default:
            note = nil
        }
        if pc.omitted > 0 {
            let more = "最前面 \(pc.omitted) 句太長沒傳到手機（完整的在電腦）"
            note = note.map { "\($0)；\(more)" } ?? more
        }
        return note
    }
}

/// v0.16：電腦錄完（定稿或分好人）才出現：存成手機上的一場。
private struct SaveRow: View {
    let pc: PCTranscript
    let save: () -> String
    @State private var saved: String?

    var body: some View {
        if pc.canSave {
            HStack(spacing: 12) {
                RoundIcon(systemName: "square.and.arrow.down", label: "存成手機上的一場", size: 44) {
                    saved = save()
                }
                Text(saved ?? "存成手機上的一場（逐字稿資料夾），之後可以看全文、複製、長按匯出")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        } else if pc.rec == .processing {
            Text("電腦整理完（定稿或分好人）就能存到手機")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 音量條：擺位置時看收不收得到。沒在傳時淡一點。
private struct LevelBar: View {
    let level: Double
    let dimmed: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.08))
                Capsule()
                    .fill(Color.black.opacity(dimmed ? 0.35 : 0.85))
                    .frame(width: max(4, geo.size.width * CGFloat(level.isFinite ? min(1, max(0, level)) : 0)))
            }
        }
        .frame(height: 10)
        .animation(.linear(duration: 0.1), value: level)
        .accessibilityLabel("音量")
        .accessibilityValue("\(Int((level.isFinite ? level : 0) * 100))%")
    }
}

// MARK: 結束

private struct EndedStep: View {
    let link: PhoneLink
    let close: () -> Void
    let save: () -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(link.note ?? "已停止")
                .font(.title3)
                .padding(.top, 20)
            if link.sentSeconds > 0 || link.drops > 0 {
                Text("這次傳了 \(formatClock(link.sentSeconds))；斷過 \(link.drops) 次，共\(LinkText.lost(samples: link.lostTotalSamples))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 24) {
                if link.target != nil {
                    VStack(spacing: 6) {
                        RoundIcon(systemName: "arrow.clockwise", label: "再連一次", size: 56) {
                            link.reconnect()
                        }
                        Text("再連一次").font(.caption)
                    }
                }
                VStack(spacing: 6) {
                    RoundIcon(systemName: "qrcode.viewfinder", label: "重新掃描", size: 56) {
                        link.beginScan()
                    }
                    Text("重新掃描").font(.caption)
                }
                VStack(spacing: 6) {
                    RoundIcon(systemName: "xmark", label: "回開始畫面", size: 56) {
                        close()
                    }
                    Text("回開始畫面").font(.caption)
                }
            }
            .padding(.top, 8)
            // v0.16：停了之後，電腦錄完傳來的稿還留著，照樣能存
            SaveRow(pc: link.pc, save: save)
                .padding(.top, 8)
            // v0.17：停了之後，Claude 的對話也還看得到
            if !link.chat.items.isEmpty {
                ClaudeStrip(link: link)
            }
            Spacer()
        }
    }
}

// MARK: v0.17 連不上時的網路原因

/// 手機在 4G／行動網路、沒網路：紅字直接講（原本只寫「要在同一個 Wi-Fi」，沒說是在用 4G）。
private struct NetworkHintLine: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "antenna.radiowaves.left.and.right")
            .font(.footnote)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: v0.17 叫 Claude 的對話（協定 v4，電腦版 v5.29 起）

/// 稿下面一條：最新一則（兩行）、正在想、新回覆亮起來；點了拉出整段對話。電腦是 v5.28 以前就寫一行要更新。
private struct ClaudeStrip: View {
    let link: PhoneLink
    @State private var open = false
    @State private var flash = false

    var body: some View {
        if link.chat.supported == false && link.chat.items.isEmpty {
            Label("電腦版要更新才看得到 Claude 回覆（電腦版 v5.29 起）", systemImage: "arrow.up.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if link.chat.supported == true || !link.chat.items.isEmpty {
            Button {
                open = true
            } label: {
                strip
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Claude 的對話：\(link.chat.preview)。點開看全部")
            .sheet(isPresented: $open) {
                ClaudeChatSheet(link: link)
                    .presentationDetents([.medium, .large])
            }
            .task(id: link.chat.newReplies) {
                // 新回覆來了：亮 6 秒、多露幾行（就算在看稿也看得到）
                guard link.chat.newReplies > 0 else { return }
                flash = true
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                flash = false
            }
        }
    }

    private var strip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Claude")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(claudeAccent)
                if link.chat.thinking != nil {
                    ProgressView()
                        .controlSize(.mini)
                    ThinkingLabel(link: link)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if flash {
                    Text("新回覆")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(claudeAccent)
                }
                Spacer(minLength: 0)
                if link.speakReplies {
                    Image(systemName: link.speakingNow ? "speaker.wave.3" : "speaker.wave.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(link.chat.preview)
                .font(.footnote)
                .foregroundStyle(link.chat.latest == nil ? Color.gray : Color.black)
                .lineLimit(flash ? 5 : 2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(flash ? claudeAccent.opacity(0.12) : Color.black.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(flash ? claudeAccent.opacity(0.6) : Color.black.opacity(0.12), lineWidth: 1))
        .animation(.easeInOut(duration: 0.25), value: flash)
        .contentShape(Rectangle())
    }
}

/// 「Claude 正在想… 12 秒」：秒數一直走，卡住看得出來。
private struct ThinkingLabel: View {
    let link: PhoneLink

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let since = link.thinkingSince {
                Text("\(link.chat.thinkingText) \(max(0, Int(context.date.timeIntervalSince(since)))) 秒")
            } else {
                Text(link.chat.thinkingText)
            }
        }
        .monospacedDigit()
    }
}

/// 拉出來的整段對話：照電腦網頁的樣子，右側淡底泡泡＝他叫 Claude／打字，左側「Claude」＋回覆。
private struct ClaudeChatSheet: View {
    let link: PhoneLink
    @Environment(\.dismiss) private var dismiss
    /// v0.18：手機上的中文聲音（打開這頁時抓一次）。
    @State private var voices = LinkSpeaker.chineseVoices()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("叫 Claude 的對話")
                    .font(.headline)
                Spacer()
                RoundIcon(systemName: "xmark", label: "收起", size: 36) {
                    dismiss()
                }
            }
            Toggle(isOn: Binding(get: { link.speakReplies }, set: { link.speakReplies = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("念出新回覆（iPhone 的聲音）")
                        .font(.callout)
                    Text(speakCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(claudeAccent)
            // v0.19 開口就停（預設開）
            Toggle(isOn: Binding(get: { link.stopOnVoice }, set: { link.stopOnVoice = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("開口就停")
                        .font(.callout)
                    Text([link.bargeNote, LinkBargeRule.caption(pcVersion: link.pcVersion, enabled: link.stopOnVoice)].compactMap { $0 }.joined(separator: "。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(claudeAccent)
            HStack(spacing: 6) {
                Text("聲音")
                    .font(.callout)
                Picker("聲音", selection: Binding(get: { link.speakVoice }, set: { link.speakVoice = $0 })) {
                    Text(LinkVoiceChoice.systemLabel).tag("")
                    // 存的聲音被刪掉時，選單仍要有這個值，否則 Picker 會報錯；畫面那行會寫「不在這支手機上了」
                    if !link.speakVoice.isEmpty, LinkVoiceChoice.pick(saved: link.speakVoice, from: voices) == nil {
                        Text("（之前選的，已不在手機上）").tag(link.speakVoice)
                    }
                    ForEach(voices) { v in
                        Text(v.label).tag(v.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(claudeAccent)
                Spacer(minLength: 0)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if link.chat.omitted > 0 {
                            Text("更早的 \(link.chat.omitted) 則在電腦上")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if link.chat.items.isEmpty {
                            Text(link.chat.preview)
                                .font(.callout)
                                .foregroundStyle(.gray)
                        }
                        ForEach(link.chat.items) { item in
                            ChatBubble(item: item, fail: link.chat.fails[item.id]) {
                                link.say(item.text)
                            }
                        }
                        if link.chat.thinking != nil {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                ThinkingLabel(link: link)
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("end")
                    }
                    .padding(.vertical, 4)
                }
                .onAppear {
                    proxy.scrollTo("end", anchor: .bottom)
                }
                .onChange(of: link.chat.items.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                }
                .onChange(of: link.chat.thinking) { _, _ in
                    withAnimation {
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                }
            }
            Text("Claude 是電腦上答的（叫它時照情境帶稿上雲）。要問：錄音中喊「Hey Claude」，或在電腦打 @claude。手機這邊只能看。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .foregroundStyle(.black)
        .background(Color.white.ignoresSafeArea())
    }

    private var speakCaption: String {
        var parts = ["預設關", LinkVoiceChoice.note(saved: link.speakVoice, from: voices)]
        if link.pcTakesSpeech {
            parts.append("念的那段時間收到的聲音，電腦不寫進稿、不拿來叫 Claude；戴耳機最好")
        } else {
            parts.append("電腦版是舊的（v5.28 以前）：念的聲音可能被收進稿，請戴耳機")
        }
        return parts.joined(separator: "。")
    }
}

/// 一則對話。
private struct ChatBubble: View {
    let item: PCChatItem
    let fail: String?
    let speak: () -> Void

    var body: some View {
        if item.isClaude {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Claude")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(claudeAccent)
                    Text(item.caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(action: speak) {
                        Image(systemName: "speaker.wave.2")
                            .font(.caption)
                            .frame(width: 32, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("念這則")
                }
                Text(item.text)
                    .font(.system(.body, design: .serif))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .trailing, spacing: 3) {
                Text(item.caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(item.text)
                    .font(.callout)
                    .foregroundStyle(item.role == "heard" ? Color.black.opacity(0.7) : Color.black)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.06)))
                if let fail {
                    Text(fail)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
        }
    }
}

// MARK: 相機掃 QR 碼（AVCaptureMetadataOutput，iOS 內建，不用套件）

private struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onCode = onCode
        controller.onError = onError
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {
        controller.onCode = onCode
        controller.onError = onError
    }
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "lecturetext.scan")
    private var preview: AVCaptureVideoPreviewLayer?
    private var lastCode: String?
    private var lastAt = Date.distantPast

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            onError?("開不了相機。可以用「貼上網址」")
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onError?("相機不能掃 QR 碼。可以用「貼上網址」")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let running = session
        sessionQueue.async {
            if !running.isRunning {
                running.startRunning()     // 會卡一下，不放主執行緒
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let running = session
        sessionQueue.async {
            if running.isRunning {
                running.stopRunning()
            }
        }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let code = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }.first
        MainActor.assumeIsolated {
            self.found(code)
        }
    }

    private func found(_ code: String?) {
        guard let code else { return }
        // 同一個碼一直在畫面上會一直回報：同一個碼 2 秒內只算一次（掃錯的碼才看得到錯誤、不會一直閃）
        if code == lastCode, Date().timeIntervalSince(lastAt) < 2 { return }
        lastCode = code
        lastAt = Date()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onCode?(code)
    }
}
