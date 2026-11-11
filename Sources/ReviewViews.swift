import SwiftUI

// v0.23.1 地基的畫面：開始畫面的 Haiku 圓鈕選單、第一次貼金鑰的說明、投影片選課、上方一行提示。
// 風格照 SpeakerMenu／FixMenu：圓框圖示、點開是系統選單，不做大型設定頁。
// 0.23.2 起錄音中的狀態列、橫幅、「N 題」也放這個檔。

/// 開始畫面的 Haiku 圓鈕。沒金鑰＝圖示加斜線；有金鑰＝原樣。
struct HaikuMenu: View {
    let model: AppModel
    let size: CGFloat

    var body: some View {
        Menu {
            Section(model.haikuKeyLabel.map { "Haiku 金鑰：\($0)" } ?? "Haiku 金鑰：未設定") {
                Button {
                    model.pasteKeyTapped()
                } label: {
                    Label(model.haikuKeyLabel == nil ? "貼上金鑰" : "換一把（貼上）", systemImage: "doc.on.clipboard")
                }
                if model.haikuKeyLabel != nil {
                    Button {
                        model.testHaiku()
                    } label: {
                        Label(model.haikuTesting ? "測試中…" : "測試連線", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(model.haikuTesting)
                    Button(role: .destructive) {
                        model.deleteKey()
                    } label: {
                        Label("刪除金鑰", systemImage: "trash")
                    }
                }
            }
            if let course = model.currentCourse,
               let setting = model.courseSettings.first(where: { $0.course == course }) {
                // 0.23.3：不在上課時段時這段是「最近匯入投影片的那門」，標題寫清楚，免得看成現在在上這門
                Section(CourseSchedule.course(at: Date()) == nil ? "最近匯入投影片：\(course)（現在不是上課時段）" : course) {
                    CourseSettingItems(model: model, setting: setting)
                }
            } else {
                Section("這門課") {
                    Text("現在不是上課時段，也還沒匯入投影片")
                }
            }
            Menu("其他課") {
                ForEach(model.courseSettings.filter { $0.course != model.currentCourse }) { setting in
                    Menu(setting.course) {
                        CourseSettingItems(model: model, setting: setting)
                    }
                }
            }
            // v0.23.2：不在課表時段也能送 Haiku——先指定下一場是哪門課（標題、資料夾、Haiku 都照它；錄一場就清掉）
            Menu {
                CoursePicker(model: model, includeSchedule: true)
            } label: {
                Label("下一場是哪門課：\(model.chosenCourse ?? "照課表")", systemImage: "book.closed")
            }
            // v0.23.2：自動上傳測試資料（Google 雲端硬碟「轉文字App測試資料」；錄音不傳、私人課程不傳）
            DriveItems(drive: model.drive)
            // v0.23.5：按停止後用 Whisper 在裝置上再轉一份（預設關）。小字寫說明；有待轉、轉換中、上次結果就多一行
            Section("裝置上跑、不上傳；約錄音長度的 1/10，轉換中螢幕不自動鎖；第一次下載約 600 MB（要 Wi-Fi）") {
                Toggle(isOn: Binding(get: { model.whisper.enabled }, set: { model.whisper.enabled = $0 })) {
                    Label("下課後用 Whisper 再轉一份", systemImage: "waveform")
                }
                if let line = model.whisper.statusLine {
                    Text(line)
                }
            }
            // v0.23.4：實驗模式（Apple 現用／Apple 聽寫＋關鍵字／Whisper 同一個錄音檔各轉一次）
            Section {
                Button {
                    model.lab.showSheet = true
                } label: {
                    Label("實驗：比較轉文字引擎…", systemImage: "flask")
                }
                .disabled(model.isBusy)
            }
        } label: {
            RoundGlyph(systemName: "sparkles", size: size, slashed: model.haikuKeyLabel == nil)
        }
        // 0.23.3：照程式的順序排（iPad 上圓鈕在下半部時，系統把整個選單倒過來，金鑰跑到最下面）
        .menuOrder(.fixed)
        .sheet(isPresented: Binding(get: { model.lab.showSheet }, set: { model.lab.showSheet = $0 })) {
            LabSheet(lab: model.lab)
        }
        .accessibilityLabel(model.haikuKeyLabel == nil ? "Haiku，還沒有金鑰" : "Haiku，金鑰已設定")
    }
}

/// v0.23.2 星星選單最後一段：小字（Section 標題）寫上次結果；沒設定＝灰字；沒登入＝點了登入；登入後＝開關＋登出。
private struct DriveItems: View {
    let drive: DriveUploader

    var body: some View {
        Section(drive.statusLine) {
            if !drive.configured {
                Label("自動上傳測試資料：還沒設定", systemImage: "icloud.slash")
            } else if !drive.signedIn || drive.state.problem?.kind == .needsLogin {
                Button {
                    drive.signInTapped()
                } label: {
                    Label(drive.signingIn ? "登入中…" : (drive.signedIn ? "重新登入 Google" : "自動上傳測試資料"), systemImage: "icloud.and.arrow.up")
                }
                .disabled(drive.signingIn)
                if drive.signedIn {
                    Button(role: .destructive) {
                        drive.signOut()
                    } label: {
                        Label("登出 Google", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            } else {
                Toggle(isOn: Binding(get: { drive.enabled }, set: { drive.enabled = $0 })) {
                    Label("自動上傳測試資料", systemImage: "icloud.and.arrow.up")
                }
                Button(role: .destructive) {
                    drive.signOut()
                } label: {
                    Label("登出 Google", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
    }
}

/// 一門課在選單裡的兩行：投影片、要不要送 Haiku（私人課程不能開）。
private struct CourseSettingItems: View {
    let model: AppModel
    let setting: AppModel.CourseSetting

    var body: some View {
        Label(setting.slides.map { "投影片：\($0)" } ?? "投影片：還沒有", systemImage: "doc.richtext")
        if setting.allowed {
            Toggle(isOn: Binding(get: { setting.haiku }, set: { model.setHaiku($0, course: setting.course) })) {
                Label("錄音中送 Haiku 改字", systemImage: "sparkles")
            }
        } else {
            Label("私人課程不送", systemImage: "lock")
        }
    }
}

/// 第一次貼金鑰前的說明、投影片選課、上方提示：掛在 ContentView 最外層。
struct HaikuSheets: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content
            .alert("貼上 Anthropic API 金鑰", isPresented: $model.showHaikuIntro) {
                Button("貼上") {
                    model.confirmHaikuIntro()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("開啟後，上課中稿的文字會送到 Anthropic 的 Claude Haiku 做改字；錄音不會送。設定檔標成私人的課永遠不送。金鑰只存在這台裝置的鑰匙圈，畫面只顯示最後 4 碼。")
            }
            // v0.23.2：第一次登入 Google 前講一次會傳什麼
            .alert("自動上傳測試資料", isPresented: Binding(get: { model.drive.showIntro }, set: { model.drive.showIntro = $0 })) {
                Button("登入 Google") {
                    model.drive.confirmIntro()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("登入後，每次按停止，這場的稿、即時稿、改字紀錄、版本與錯誤紀錄（就是「匯出（不含錄音）」那一包）會傳到你的 Google 雲端硬碟「\(DrivePlan.rootFolderName)」資料夾。錄音不傳，私人課程不傳，可以在這個選單關掉。App 只碰得到自己建的檔。")
            }
            .confirmationDialog(
                "這份投影片是哪門課？",
                isPresented: Binding(
                    get: { model.pendingSlides != nil },
                    set: { if !$0 { model.pendingSlides = nil } }
                ),
                titleVisibility: .visible,
                presenting: model.pendingSlides
            ) { pending in
                ForEach(AppModel.scheduleCourses(includePrivate: false), id: \.self) { course in
                    Button(course) {
                        model.saveSlides(pending, course: course)
                        // 0.23.3：不在上課時段匯入投影片、選了課，下一場就當這門課（先傳投影片再按錄音，課名、資料夾、Haiku 都對）
                        model.assignCourse(course)
                    }
                }
                Button("其他（不存）", role: .cancel) {
                    model.skipSlides(pending)
                }
            } message: { pending in
                Text("\(pending.source)，\(pending.pages.count) 頁。現在不是上課時段，選了才存")
            }
            .overlay(alignment: .top) {
                if let line = model.banner {
                    Button {
                        model.dismissBanner()
                    } label: {
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(.black)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(.white))
                            .overlay(Capsule().stroke(Color.black.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                    .padding(.horizontal, 20)
                    .transition(.opacity)
                    .accessibilityHint("點一下關掉")
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.banner)
    }
}

/// v0.23.2：課名清單（課表上的課，私人課程除外）。錄音前＝指定下一場；錄音中＝只給這場的 Haiku 用。
struct CoursePicker: View {
    let model: AppModel
    /// 錄音前多一個「照課表」
    let includeSchedule: Bool

    var body: some View {
        if includeSchedule {
            Button {
                model.assignCourse(nil)
            } label: {
                if model.chosenCourse == nil {
                    Label("照課表", systemImage: "checkmark")
                } else {
                    Text("照課表")
                }
            }
        }
        ForEach(AppModel.scheduleCourses(includePrivate: false), id: \.self) { course in
            Button {
                model.assignCourse(course)
            } label: {
                if model.chosenCourse == course {
                    Label(course, systemImage: "checkmark")
                } else {
                    Text(course)
                }
            }
        }
    }
}

/// v0.23.2 錄音畫面標題下：「投影片：lecture-17　Haiku：已送 N 批・改 M 處・擋 K 處・上一批 X 秒」；
/// 沒課名而沒送時，點這行選這場是哪門課。下面一條橫幅（不擋操作）：沒有網路、金鑰無效、花費到上限、Haiku 暫停；網路回來自動消失。
struct ReviewStatusBar: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.reviewer == nil && model.reviewNeedsCourse {
                Menu {
                    Section("這場是哪門課（只給 Haiku 用）") {
                        CoursePicker(model: model, includeSchedule: false)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.reviewStatusLine)
                        Image(systemName: "chevron.down")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text(model.reviewStatusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let banner = model.reviewer?.banner {
                Label(banner, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray6)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.2), lineWidth: 1))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: model.reviewer?.banner)
    }
}