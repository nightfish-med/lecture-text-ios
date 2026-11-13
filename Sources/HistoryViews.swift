import SwiftUI

// v0.27.1「以前的課」：開始畫面的圓鈕打開，列出這台裝置存的每一場（依課分組、新的在前），點一下用結果畫面打開
// （有卡片就是左右兩欄的卡片，否則逐字稿；分享逐字稿和重點 PDF 也能用）。只看不刪（App 本來就不刪檔）。
// 讀稿、分組的算法在 SessionFiles.swift（RunCatalog，shape_check 測）。

extension Store {
    /// 逐字稿資料夾（含各課的子資料夾）裡每一場的主稿。背景跑。
    static func listRuns() -> [RunEntry] {
        let manager = FileManager.default
        let root = transcripts
        var out: [RunEntry] = []
        func scan(_ folder: URL, course: String?) {
            let names = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names {
                guard RunCatalog.mainName(name) != nil else { continue }
                let url = folder.appendingPathComponent(name)
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let entry = RunCatalog.parse(fileName: name, course: course, document: text) else { continue }
                out.append(entry)
            }
        }
        scan(root, course: nil)
        let folders = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for folder in folders {
            let isFolder = (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isFolder, !folder.lastPathComponent.hasPrefix(".") else { continue }
            scan(folder, course: folder.lastPathComponent)
        }
        return out
    }

    /// 一場完整的紀錄（v0.27.1 起每次存稿都另存；舊的場沒有）
    static func runJSON(stamp: String, stem: String, course: String?) -> URL {
        transcriptsFolder(course: course).appendingPathComponent("\(stamp) \(stem) 場.json")
    }

    /// 打開以前的一場：有「… 場.json」就用它（和存的時候一模一樣）；舊的場從稿頭讀回來（錄音檔名從錄音資料夾找）
    static func loadRun(_ entry: RunEntry) -> SavedRun {
        let json = runJSON(stamp: entry.startedStamp, stem: entry.sourceStem, course: entry.course)
        if let data = try? Data(contentsOf: json), let saved = try? JSONDecoder().decode(SavedRun.self, from: data) {
            return saved
        }
        let folder = recordingsFolder(course: entry.course)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let source = names.first { ($0 as NSString).deletingPathExtension == entry.sourceStem } ?? entry.sourceStem + ".caf"
        var run = SavedRun(source: source, startedStamp: entry.startedStamp, engine: "", language: "", systemVersion: "",
                           audioSeconds: entry.audioSeconds, convertSeconds: nil, finished: entry.finished, text: entry.text)
        run.speakers = entry.speakers.isEmpty ? nil : entry.speakers
        run.parts = entry.parts
        run.course = entry.course
        run.origin = entry.origin
        run.scene = entry.scene
        return run
    }
}

/// 以前的課的清單
struct HistorySheet: View {
    let model: AppModel
    let close: () -> Void
    @State private var groups: [(course: String, entries: [RunEntry])] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if !loaded {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("讀取中…")
                            .foregroundStyle(.secondary)
                    }
                } else if groups.isEmpty {
                    Text("這台裝置還沒有存下來的課")
                        .foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.course) { group in
                    Section(group.course) {
                        ForEach(group.entries, id: \.key) { entry in
                            Button {
                                model.openPastRun(entry)
                                close()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title.isEmpty ? entry.sourceStem : entry.title)
                                        .foregroundStyle(.black)
                                    Text(RunCatalog.rowText(entry))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("以前的課")
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
            let list = await Task.detached { Store.listRuns() }.value
            groups = RunCatalog.group(list)
            loaded = true
        }
    }
}
