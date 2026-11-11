import SwiftUI
import UniformTypeIdentifiers

// v0.23.4 實驗模式的畫面：星星選單「實驗：比較轉文字引擎…」打開。邏輯在 EngineLab.swift、LabPlan.swift。

struct LabSheet: View {
    @Bindable var lab: EngineLab
    @State private var picking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(lab.fileName.isEmpty ? "選錄音檔…" : lab.fileName) { picking = true }
                        .disabled(lab.running)
                    if let note = lab.note {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("錄音檔")
                } footer: {
                    Text("App 錄的在「轉文字 › 錄音」。錄音只在這台處理，不上傳。")
                }
                Section {
                    Picker("課", selection: $lab.course) {
                        ForEach(AppModel.scheduleCourses(includePrivate: false), id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(lab.running)
                    Text(lab.keywordNote).font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("關鍵字取自哪門課（投影片＋課程對照表）")
                }
                Section {
                    Label("Apple 現用（SpeechTranscriber，對照組）", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                    // v0.23.5：已知失靈，預設關
                    Toggle("Apple 聽寫＋關鍵字（已知失靈：實測只出 2 字）", isOn: $lab.useDictation)
                    Toggle("Whisper large-v3 turbo", isOn: $lab.useWhisper)
                    Toggle("Whisper 加關鍵字提示詞（鬼打牆可能變多）", isOn: $lab.whisperPrompt)
                        .disabled(!lab.useWhisper)
                } header: {
                    Text("要跑的引擎（一個跑完再跑下一個）")
                } footer: {
                    Text("Whisper 第一次要下載約 600 MB 模型（用 Wi-Fi），之後不用。iPad 實測：46 分鐘的錄音 Apple 約 1 分鐘、Whisper 約 4–5 分鐘。Whisper 的轉換時間從模型載入完才算，載入另列。字數不到 Apple 現用 10% 的寫「疑似失敗」。跑的時候螢幕不要關、不要切走。")
                }
                Section {
                    if lab.running {
                        Button("停止", role: .destructive) { lab.cancel() }
                    } else {
                        Button("開始比較") { lab.start() }
                            .disabled(lab.fileURL == nil)
                    }
                }
                if !lab.rows.isEmpty {
                    Section("進度") {
                        ForEach(lab.rows) { row in
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.id.name)
                                Spacer()
                                Text(row.text).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }
                if let report = lab.report {
                    Section {
                        if let url = lab.reportURL {
                            ShareLink("分享報告", item: url)
                        }
                        Text(report).font(.caption.monospaced()).textSelection(.enabled)
                    } header: {
                        Text("結果")
                    } footer: {
                        Text("全部檔案在「檔案」App › 我的 iPad › 轉文字 › 實驗 › \(lab.folderName ?? "")：報告、每分鐘對照（網頁）、各引擎的稿和時間。")
                    }
                }
            }
            .navigationTitle("實驗：比較轉文字引擎")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { lab.showSheet = false }
                        .disabled(lab.running)
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.audio, .movie]) { result in
                if case .success(let url) = result {
                    lab.picked(url)
                }
            }
        }
        .interactiveDismissDisabled(lab.running)
        .onAppear {
            // 課名從設定檔來：還沒選過、或選的課已經不在課表上，就換成第一門
            let courses = AppModel.scheduleCourses(includePrivate: false)
            if !courses.contains(lab.course) { lab.course = courses.first ?? "" }
        }
    }
}
