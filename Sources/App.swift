import SwiftUI

@main
struct LectureTextApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.light)
                // 從「檔案」或其他 App 用「打開方式」丟進來的檔。
                .onOpenURL { url in
                    model.importFile(url)
                }
        }
    }
}
