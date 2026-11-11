import AuthenticationServices
import Foundation
import Observation
import Security
import UIKit

// v0.23.2 自動上傳測試資料：Google 登入（ASWebAuthenticationSession＋PKCE）、待傳清單、上傳到雲端硬碟「轉文字App測試資料／iPhone（或 iPad）」。
// 純邏輯（要不要傳、檔名、清單、PKCE、請求內容、錯誤分類）在 DrivePlan.swift，shape_check 測得到。
// 不擋人：全部在背景做，失敗不跳警告、不影響錄音與畫面；失敗的留在待傳清單，下次停止、下次開 App（或回到前景超過 10 分鐘）再試。
// 權杖：更新權杖放鑰匙圈（AfterFirstUnlockThisDeviceOnly），存取權杖只在記憶體；畫面、紀錄、錯誤資料都不印權杖。

/// 更新權杖（refresh token）只放這台裝置的鑰匙圈
enum GoogleTokenStore {
    private static let service = "com.lecturetext.google"
    private static let account = "drive-refresh-token"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ token: String) -> OSStatus {
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// 登入網頁要掛在哪個視窗上
private final class AuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first { $0.isKeyWindow } ?? windows.first ?? ASPresentationAnchor()
    }
}

@MainActor
@Observable
final class DriveUploader {
    private(set) var state = DriveState()
    private(set) var signedIn = GoogleTokenStore.read() != nil
    private(set) var busy = false
    /// 登入中（選單那項寫「登入中…」）
    private(set) var signingIn = false
    /// 第一次登入前先講一次會傳什麼
    var showIntro = false

    /// 寫進錯誤紀錄（AppModel.log，不含權杖、不含稿的字）
    @ObservationIgnored var onEvent: (String) -> Void = { _ in }
    /// 畫面上方幾秒的一行（登入結果）
    @ObservationIgnored var onBanner: (String) -> Void = { _ in }

    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var accessExpiry = Date.distantPast
    @ObservationIgnored private var authSession: ASWebAuthenticationSession?
    private let anchor = AuthAnchor()
    @ObservationIgnored private var background: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var lastTry = Date.distantPast

    static var clientID: String { GoogleDriveConfig.clientID.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// client id 填了、格式也對才算設定好
    var configured: Bool { GoogleOAuth.redirectScheme(clientID: Self.clientID) != nil }
    var enabled: Bool {
        get { state.enabled }
        set {
            state.enabled = newValue
            save()
            onEvent("自動上傳：\(newValue ? "打開" : "關掉")")
            if newValue { retryPending() }
        }
    }
    var statusLine: String { DriveText.status(configured: configured, signedIn: signedIn, state: state) }
    /// 錯誤資料那一行
    var reportLine: String {
        guard configured else { return "自動上傳：還沒設定 Google 用戶端編號" }
        var line = "自動上傳：\(signedIn ? "已登入" : "沒登入")、\(state.enabled ? "開" : "關")；\(statusLine)"
        if let problem = state.problem { line += "；上次問題：\(problem.detail)" }
        return line
    }

    // MARK: 存檔位置（Application Support：檔案 App 看不到，不進備份）

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var url = base.appendingPathComponent("自動上傳", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    private static var stateFile: URL { folder.appendingPathComponent("狀態.json") }
    private static var queueFolder: URL {
        let url = folder.appendingPathComponent("待傳", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init() {
        if let data = try? Data(contentsOf: Self.stateFile),
           let saved = try? JSONDecoder().decode(DriveState.self, from: data) {
            state = saved
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(state) {
            try? data.write(to: Self.stateFile, options: .atomic)
        }
    }

    // MARK: 登入／登出

    /// 選單「自動上傳測試資料」（沒登入時）：第一次先跳說明，之後直接開登入頁。
    func signInTapped() {
        guard configured, !signingIn else { return }
        if UserDefaults.standard.bool(forKey: "driveIntroShown") {
            signIn()
        } else {
            showIntro = true
        }
    }

    func confirmIntro() {
        UserDefaults.standard.set(true, forKey: "driveIntroShown")
        signIn()
    }

    private func signIn() {
        let clientID = Self.clientID
        guard let scheme = GoogleOAuth.redirectScheme(clientID: clientID) else { return }
        var random = [UInt8](repeating: 0, count: 32)
        var nonce = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess,
              SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce) == errSecSuccess else {
            onBanner("Google 登入沒有開始：產生登入碼失敗")
            return
        }
        let verifier = PKCE.verifier(bytes: random)
        let expected = PKCE.base64url(Data(nonce))
        guard let url = GoogleOAuth.authURL(clientID: clientID, challenge: PKCE.challenge(verifier: verifier), state: expected) else { return }
        signingIn = true
        // callbackURLScheme＝client id 反過來：ASWebAuthenticationSession 自己接這個網址，不用在 Info.plist 註冊網址協定
        let web = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { [weak self] callback, error in
            Task { @MainActor in
                guard let self else { return }
                self.authSession = nil
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    self.signingIn = false
                    return
                }
                if let error {
                    self.finishSignIn(failure: "登入沒有完成：\(error.localizedDescription)")
                    return
                }
                switch GoogleOAuth.parseCallback(callback, expectedState: expected) {
                case .cancelled:
                    self.signingIn = false
                case .failed(let why):
                    self.finishSignIn(failure: why)
                case .code(let code):
                    await self.exchange(code: code, verifier: verifier)
                }
            }
        }
        web.presentationContextProvider = anchor
        // 不沿用 Safari 裡已登入的帳號，每次自己選；也不會先跳「想要使用 google.com 登入」
        web.prefersEphemeralWebBrowserSession = true
        authSession = web
        if !web.start() {
            authSession = nil
            finishSignIn(failure: "登入頁開不起來")
        }
    }

    private func finishSignIn(failure: String) {
        signingIn = false
        onEvent("自動上傳：Google \(failure)")
        onBanner("Google \(failure)")
    }

    private func exchange(code: String, verifier: String) async {
        let fields = GoogleOAuth.codeExchangeFields(clientID: Self.clientID, code: code, verifier: verifier)
        switch await tokenRequest(fields) {
        case .ok(let access, let expiresIn, let refresh):
            guard let refresh, !refresh.isEmpty else {
                finishSignIn(failure: "登入了但沒有拿到更新權杖，請登出再登入一次")
                return
            }
            let status = GoogleTokenStore.save(refresh)
            guard status == errSecSuccess else {
                finishSignIn(failure: "存進鑰匙圈失敗（\(status)）")
                return
            }
            accessToken = access
            accessExpiry = Date().addingTimeInterval(expiresIn)
            signedIn = true
            signingIn = false
            state.enabled = true
            state.problem = nil
            save()
            onEvent("自動上傳：Google 登入成功")
            onBanner("已登入 Google：之後每次按停止，這場的稿（不含錄音）會傳到雲端硬碟「\(DrivePlan.rootFolderName)」")
            retryPending()
        case .needsLogin(let why), .failed(let why):
            finishSignIn(failure: "登入失敗：\(why)")
        }
    }

    /// 登出：撤銷權杖（盡力，沒網路就算了）、刪鑰匙圈、清掉資料夾 id 和待傳清單（待傳的 zip 一起刪，手機上不多留一份稿）。
    func signOut() {
        let refresh = GoogleTokenStore.read()
        GoogleTokenStore.delete()
        accessToken = nil
        accessExpiry = .distantPast
        signedIn = false
        let dropped = state.pending.count
        for item in state.pending {
            try? FileManager.default.removeItem(at: Self.queueFolder.appendingPathComponent(item.name))
        }
        let keepEnabled = state.enabled
        state = DriveState()
        state.enabled = keepEnabled
        save()
        onEvent("自動上傳：登出 Google" + (dropped > 0 ? "（待傳 \(dropped) 份已刪）" : ""))
        if let refresh {
            Task.detached {
                var request = URLRequest(url: URL(string: GoogleOAuth.revokeEndpoint)!, timeoutInterval: 15)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = GoogleOAuth.formBody([("token", refresh)])
                _ = try? await URLSession.shared.data(for: request)
            }
        }
    }

    // MARK: 排進清單、上傳

    /// 停止後打包好的 zip 搬進待傳資料夾、排進清單，然後試著傳。
    func enqueue(zip: URL) {
        let name = zip.lastPathComponent
        let target = Self.queueFolder.appendingPathComponent(name)
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: zip, to: target)
        } catch {
            onEvent("自動上傳：放進待傳清單失敗：\(error.localizedDescription)")
            return
        }
        let result = DriveQueue.add(state.pending, name: name, at: Store.timestamp())
        state.pending = result.items
        for gone in result.dropped {
            try? FileManager.default.removeItem(at: Self.queueFolder.appendingPathComponent(gone))
            onEvent("自動上傳：待傳超過 \(DrivePlan.queueLimit) 份，丟掉最舊的 \(gone)")
        }
        save()
        onEvent("自動上傳：排進待傳（\(name)，\(state.pending.count) 份待傳）")
        retryPending()
    }

    /// 回到前景時：有待傳、而且上次試已經超過 10 分鐘才再試（不一直打 Google）
    func retryIfDue() {
        guard !state.pending.isEmpty, Date().timeIntervalSince(lastTry) > 600 else { return }
        retryPending()
    }

    /// 依序傳待傳清單。沒設定、沒登入、關著、正在傳、要重新登入時不動。
    func retryPending() {
        guard configured, signedIn, state.enabled, !busy, !state.pending.isEmpty else { return }
        guard state.problem?.kind != .needsLogin else { return }
        busy = true
        lastTry = Date()
        beginBackground()
        Task {
            await drain()
            busy = false
            endBackground()
        }
    }

    private func drain() async {
        while let item = state.pending.first {
            let file = Self.queueFolder.appendingPathComponent(item.name)
            guard let data = try? Data(contentsOf: file) else {
                state.pending = DriveQueue.remove(state.pending, name: item.name)
                save()
                onEvent("自動上傳：本機找不到 \(item.name)，從清單拿掉")
                continue
            }
            do {
                let id = try await uploadFile(name: item.name, data: data)
                state.uploaded[item.name] = id
                state.pending = DriveQueue.remove(state.pending, name: item.name)
                state.lastSuccess = Store.timestamp()
                state.problem = nil
                save()
                try? FileManager.default.removeItem(at: file)
                onEvent("自動上傳：已傳 \(item.name)（\(data.count / 1024) KB）")
            } catch {
                let failure = (error as? DriveFailure) ?? .other("上傳失敗")
                state.problem = failure.problem
                if failure.stopsQueue {
                    save()
                    onEvent("自動上傳：沒傳成（\(failure.problem.detail)），\(state.pending.count) 份留著下次再試")
                    return
                }
                let result = DriveQueue.fail(state.pending, name: item.name)
                state.pending = result.items
                if result.giveUp {
                    try? FileManager.default.removeItem(at: file)
                    onEvent("自動上傳：\(item.name) 失敗 \(DrivePlan.maxAttempts) 次，放棄（\(failure.problem.detail)）")
                } else {
                    onEvent("自動上傳：\(item.name) 沒傳成（\(failure.problem.detail)），下次再試")
                }
                save()
                // 同一份失敗沒到上限：先停，下次再從它開始（不連打）
                if !result.giveUp { return }
            }
        }
    }

    /// 傳一份：確定資料夾在 → 傳過同名的就覆蓋，沒有就新建；資料夾被永久刪了就重建一次。回傳雲端檔案 id。
    private func uploadFile(name: String, data: Data) async throws -> String {
        var folder = try await ensureFolders()
        if let existing = state.uploaded[name] {
            do {
                return try await sendUpload(name: name, data: data, parent: nil, updating: existing)
            } catch DriveFailure.notFound {
                state.uploaded[name] = nil
            }
        }
        do {
            return try await sendUpload(name: name, data: data, parent: folder, updating: nil)
        } catch DriveFailure.notFound {
            // 剛確認過還在、上傳時才不見：重找一次資料夾再傳
            state.deviceID = nil
            folder = try await ensureFolders()
            return try await sendUpload(name: name, data: data, parent: folder, updating: nil)
        }
    }

    /// 根目錄「轉文字App測試資料」→ 裝置子資料夾。存的 id 還在（沒在垃圾桶）就用；不在就先找同名（另一台裝置建的），找不到才建。
    private func ensureFolders() async throws -> String {
        let root = try await ensureFolder(name: DrivePlan.rootFolderName, parent: "root", stored: state.rootID)
        if root != state.rootID {
            state.rootID = root
            save()
        }
        let deviceName = DrivePlan.deviceFolderName(isPad: UIDevice.current.userInterfaceIdiom == .pad)
        let device = try await ensureFolder(name: deviceName, parent: root, stored: state.deviceID)
        if device != state.deviceID {
            state.deviceID = device
            save()
            onEvent("自動上傳：雲端資料夾 \(DrivePlan.rootFolderName)/\(deviceName) 就緒")
        }
        return device
    }

    private struct FileRef: Decodable {
        let id: String
        let trashed: Bool?
    }

    private struct FileList: Decodable {
        let files: [FileRef]?
    }

    private func ensureFolder(name: String, parent: String, stored: String?) async throws -> String {
        if let stored, let url = DriveRequest.getURL(id: stored) {
            do {
                let data = try await apiCall { token in
                    var request = URLRequest(url: url, timeoutInterval: 30)
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    return request
                }
                if let ref = try? JSONDecoder().decode(FileRef.self, from: data), ref.trashed != true {
                    return stored
                }
                onEvent("自動上傳：雲端資料夾在垃圾桶，重建")
            } catch DriveFailure.notFound {
                onEvent("自動上傳：雲端資料夾找不到，重建")
            }
        }
        if let url = DriveRequest.listURL(query: DriveRequest.folderQuery(name: name, parent: parent)) {
            let data = try await apiCall { token in
                var request = URLRequest(url: url, timeoutInterval: 30)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return request
            }
            if let found = (try? JSONDecoder().decode(FileList.self, from: data))?.files?.first {
                return found.id
            }
        }
        guard let url = DriveRequest.createFolderURL() else { throw DriveFailure.other("網址組不出來") }
        let body = DriveRequest.metadata(name: name, mimeType: DrivePlan.folderMime, parents: [parent])
        let data = try await apiCall { token in
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }
        guard let ref = try? JSONDecoder().decode(FileRef.self, from: data) else { throw DriveFailure.other("建資料夾的回應讀不懂") }
        return ref.id
    }

    /// 5 MB 以下 multipart 一次傳完；以上 resumable（先要一個上傳網址，再整份 PUT）。updating 有值＝PATCH 覆蓋那份。
    private func sendUpload(name: String, data: Data, parent: String?, updating: String?) async throws -> String {
        let resumable = DriveRequest.useResumable(size: data.count)
        let url = updating.map { DriveRequest.updateUploadURL(id: $0, resumable: resumable) } ?? DriveRequest.createUploadURL(resumable: resumable)
        guard let url else { throw DriveFailure.other("網址組不出來") }
        // 覆蓋時不帶 parents（files.update 不收 parents 欄位，搬家要用 addParents）
        let metadata = DriveRequest.metadata(name: name, mimeType: updating == nil ? DrivePlan.zipMime : nil, parents: parent.map { [$0] })
        let method = updating == nil ? "POST" : "PATCH"
        let reply: Data
        if resumable {
            let session = try await startResumable(url: url, method: method, metadata: metadata, size: data.count)
            reply = try await apiCall { token in
                var request = URLRequest(url: session, timeoutInterval: 300)
                request.httpMethod = "PUT"
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(DrivePlan.zipMime, forHTTPHeaderField: "Content-Type")
                request.httpBody = data
                return request
            }
        } else {
            let boundary = "lecturetext-" + UUID().uuidString
            let body = DriveRequest.multipart(metadata: metadata, media: data, mediaType: DrivePlan.zipMime, boundary: boundary)
            reply = try await apiCall { token in
                var request = URLRequest(url: url, timeoutInterval: 120)
                request.httpMethod = method
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(DriveRequest.contentType(boundary: boundary), forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                return request
            }
        }
        guard let ref = try? JSONDecoder().decode(FileRef.self, from: reply) else { throw DriveFailure.other("上傳的回應讀不懂") }
        return ref.id
    }

    /// resumable 第一步：送中繼資料，回應標頭 Location 是這次的上傳網址
    private func startResumable(url: URL, method: String, metadata: Data, size: Int) async throws -> URL {
        var location: URL?
        _ = try await apiCall(onResponse: { response in
            location = (response.value(forHTTPHeaderField: "Location")).flatMap(URL.init(string:))
        }) { token in
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue(DrivePlan.zipMime, forHTTPHeaderField: "X-Upload-Content-Type")
            request.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
            request.httpBody = metadata
            return request
        }
        guard let location else { throw DriveFailure.other("沒有拿到上傳網址") }
        return location
    }

    // MARK: 送請求（401 先換權杖再試一次）

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private func apiCall(onResponse: ((HTTPURLResponse) -> Void)? = nil, _ make: (String) -> URLRequest) async throws -> Data {
        var refreshed = false
        while true {
            let token = try await validToken(force: refreshed)
            let request = make(token)
            let result: (Data, URLResponse)
            do {
                result = try await Self.session.data(for: request)
            } catch let error as URLError {
                throw DriveFailure.isOffline(error.code) ? DriveFailure.offline : DriveFailure.other("連線失敗（\(error.code.rawValue)）")
            } catch {
                throw DriveFailure.other("連線失敗")
            }
            let data = result.0
            let http = result.1 as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (200...299).contains(status) {
                if let http { onResponse?(http) }
                return data
            }
            let failure = DriveFailure.classify(status: status, body: data)
            if failure == .unauthorized {
                if refreshed { throw DriveFailure.needsLogin }
                refreshed = true
                accessToken = nil
                continue
            }
            throw failure
        }
    }

    /// 記憶體裡的存取權杖還有 1 分鐘以上就用；不然拿鑰匙圈的更新權杖去換。
    private func validToken(force: Bool) async throws -> String {
        if !force, let accessToken, accessExpiry > Date().addingTimeInterval(60) {
            return accessToken
        }
        guard let refresh = GoogleTokenStore.read() else {
            signedIn = false
            throw DriveFailure.needsLogin
        }
        switch await tokenRequest(GoogleOAuth.refreshFields(clientID: Self.clientID, refreshToken: refresh)) {
        case .ok(let access, let expiresIn, let newRefresh):
            accessToken = access
            accessExpiry = Date().addingTimeInterval(expiresIn)
            if let newRefresh, !newRefresh.isEmpty, newRefresh != refresh {
                GoogleTokenStore.save(newRefresh)
            }
            return access
        case .needsLogin(let why):
            onEvent("自動上傳：更新權杖失效（\(why)），要重新登入")
            throw DriveFailure.needsLogin
        case .failed(let why):
            if why == Self.offlineMarker { throw DriveFailure.offline }
            throw why.contains("忙") ? DriveFailure.retryLater(why) : DriveFailure.other(why)
        }
    }

    /// 權杖端點。沒網路回 .failed(offlineMarker)，validToken 再換成 DriveFailure.offline（和要重新登入分開）。
    private func tokenRequest(_ fields: [(String, String)]) async -> GoogleOAuth.TokenResult {
        guard let url = URL(string: GoogleOAuth.tokenEndpoint) else { return .failed("網址組不出來") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleOAuth.formBody(fields)
        do {
            let (data, response) = try await Self.session.data(for: request)
            return GoogleOAuth.parseToken(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where DriveFailure.isOffline(error.code) {
            return .failed(Self.offlineMarker)
        } catch {
            return .failed("連不上 Google 登入服務")
        }
    }

    private static let offlineMarker = "沒有網路"

    // MARK: 背景時間（按停止後常馬上鎖螢幕）

    private func beginBackground() {
        endBackground()
        background = UIApplication.shared.beginBackgroundTask(withName: "自動上傳測試資料") { [weak self] in
            MainActor.assumeIsolated {
                self?.endBackground()
            }
        }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }
}
