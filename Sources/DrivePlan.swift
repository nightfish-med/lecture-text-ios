import Foundation
import CryptoKit

// v0.23.2 自動上傳測試資料（純邏輯，不碰畫面、不連網；shape_check 用 tools/shape_check/drive_tests.swift 測）。
// 上傳到 Google 雲端硬碟一個獨立的新資料夾；做成可關的開關；錄音永遠不傳；私人課程（設定檔標 private）和不在設定檔裡的課永遠不傳。
// 上傳的就是「匯出（不含錄音）」那一包 zip，檔名照舊 YYYYMMDD_課名_App匯出_HHMM.zip。
// 端點、參數照 Google 官方文件（出處寫在各段註解；查證日 2026-11-11）。

// MARK: - 要不要傳、傳到哪、叫什麼

enum DrivePlan {
    /// 雲端硬碟根目錄下的資料夾名（App 自己建；之後用 id 找，使用者改名或搬走都還傳得到）
    static let rootFolderName = "轉文字App測試資料"
    /// 資料夾的 MIME 類型（developers.google.com/workspace/drive/api/guides/folder）
    static let folderMime = "application/vnd.google-apps.folder"
    static let zipMime = "application/zip"
    /// 5 MB 以下用 multipart 一次傳完，以上用 resumable（developers.google.com/workspace/drive/api/guides/manage-uploads）
    static let multipartLimit = 5 * 1024 * 1024
    /// 待傳清單最多留幾份（超過丟最舊的，紀錄寫一行）
    static let queueLimit = 30
    /// 同一份失敗幾次（不是沒網路、不是要重新登入）就放棄
    static let maxAttempts = 5

    /// 不傳的原因；nil＝要傳。
    enum Skip: String, Equatable {
        case notConfigured = "還沒設定 Google 用戶端編號"
        case privateCourse = "私人課程不傳"
        case unknownCourse = "不在設定檔的課不傳"
        case noCourse = "沒有課名不傳"
        case signedOut = "沒登入 Google"
        case off = "自動上傳關著"
    }

    /// 停止錄音後要不要把這場傳上去。私人課程、沒課名用的是和 Haiku 同一個判斷（CourseProfile.allowsUpload）。
    /// 順序：沒設定 → 沒課名／私人課程／不在設定檔的課 → 沒登入 → 關著。
    static func decide(configured: Bool, signedIn: Bool, enabled: Bool, course: String?) -> Skip? {
        guard configured else { return .notConfigured }
        if !CourseProfile.allowsUpload(course: course) {
            let name = (course ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { return .noCourse }
            return CourseSchedule.isPrivate(name) ? .privateCourse : .unknownCourse
        }
        guard signedIn else { return .signedOut }
        guard enabled else { return .off }
        return nil
    }

    /// 每台裝置一個子資料夾，只用 iPhone／iPad 這種不含個資的字（不用裝置名稱，裝置名稱常有人名）。
    static func deviceFolderName(isPad: Bool) -> String {
        isPad ? "iPad" : "iPhone"
    }

    /// 雲端上的檔名＝現有匯出 zip 的檔名（ClassRecord），不另外發明。
    static func fileName(stamp: String, course: String?) -> String {
        ClassRecord.exportFileName(.session, stamp: stamp, course: course)
    }

    /// 20261111-091200 → 11/11 09:12（狀態那行用）
    static func readable(_ stamp: String) -> String {
        let c = Array(stamp)
        guard c.count == 15 else { return stamp }
        return "\(String(c[4..<6]))/\(String(c[6..<8])) \(String(c[9..<11])):\(String(c[11..<13]))"
    }
}

// MARK: - 待傳清單與狀態（存在 App 的 Application Support，檔案 App 看不到）

struct DriveQueueItem: Codable, Equatable {
    /// 雲端檔名＝本機待傳資料夾裡的檔名
    var name: String
    /// 加進清單的時間 yyyyMMdd-HHmmss
    var addedAt: String
    var attempts = 0
}

/// 上一次失敗的種類。沒有網路和要重新登入分開記、分開顯示。
enum DriveProblemKind: String, Codable, Equatable {
    case offline
    case needsLogin
    case other
}

struct DriveProblem: Codable, Equatable {
    var kind: DriveProblemKind
    /// 給人看的一句（不含權杖、不含稿的字）
    var detail: String
}

struct DriveState: Codable, Equatable {
    /// 預設開：登入就是要傳；關掉後新的場不排進清單，已排的留著等打開
    var enabled = true
    var rootID: String? = nil
    var deviceID: String? = nil
    /// 檔名 → 雲端檔案 id：續錄同一場（檔名一樣）就覆蓋雲端那份，不多一份同名檔
    var uploaded: [String: String] = [:]
    var pending: [DriveQueueItem] = []
    var lastSuccess: String? = nil
    var problem: DriveProblem? = nil

    init() {}

    /// 少欄位也讀得開（之後加欄位，舊檔照讀）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        rootID = try c.decodeIfPresent(String.self, forKey: .rootID)
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        uploaded = try c.decodeIfPresent([String: String].self, forKey: .uploaded) ?? [:]
        pending = try c.decodeIfPresent([DriveQueueItem].self, forKey: .pending) ?? []
        lastSuccess = try c.decodeIfPresent(String.self, forKey: .lastSuccess)
        problem = try c.decodeIfPresent(DriveProblem.self, forKey: .problem)
    }
}

enum DriveQueue {
    /// 加一份：同名的先拿掉（續錄後的新版取代舊的），放最後；超過上限丟最舊的。回傳丟掉的檔名（要刪本機檔）。
    static func add(_ items: [DriveQueueItem], name: String, at stamp: String, limit: Int = DrivePlan.queueLimit) -> (items: [DriveQueueItem], dropped: [String]) {
        var list = items.filter { $0.name != name }
        list.append(DriveQueueItem(name: name, addedAt: stamp))
        var dropped: [String] = []
        while list.count > max(limit, 1) {
            dropped.append(list.removeFirst().name)
        }
        return (list, dropped)
    }

    static func remove(_ items: [DriveQueueItem], name: String) -> [DriveQueueItem] {
        items.filter { $0.name != name }
    }

    /// 失敗一次：次數加一；到上限回傳 true（要放棄這份）
    static func fail(_ items: [DriveQueueItem], name: String, limit: Int = DrivePlan.maxAttempts) -> (items: [DriveQueueItem], giveUp: Bool) {
        var list = items
        guard let index = list.firstIndex(where: { $0.name == name }) else { return (list, false) }
        list[index].attempts += 1
        if list[index].attempts >= limit {
            list.remove(at: index)
            return (list, true)
        }
        return (list, false)
    }
}

enum DriveText {
    /// 星星選單「自動上傳測試資料」下面那行小字。
    static func status(configured: Bool, signedIn: Bool, state: DriveState) -> String {
        guard configured else { return "還沒設定" }
        guard signedIn else { return "沒登入：不上傳" }
        if state.problem?.kind == .needsLogin { return "要重新登入 Google" }
        let count = state.pending.count
        if count > 0 {
            var line = "待傳 \(count) 份"
            if let problem = state.problem {
                line += "：" + (problem.kind == .offline ? "沒有網路" : problem.detail)
            }
            if !state.enabled { line += "（已關閉）" }
            return line
        }
        if !state.enabled {
            return "已關閉" + (state.lastSuccess.map { "（上次上傳 \(DrivePlan.readable($0))）" } ?? "")
        }
        if let last = state.lastSuccess { return "上次上傳 \(DrivePlan.readable(last))" }
        return "還沒上傳過"
    }
}

// MARK: - PKCE（RFC 7636；Google 文件建議 S256）

enum PKCE {
    /// base64url、不補 =（RFC 7636 附錄 A）
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 32 個隨機位元組 → 43 字的 code_verifier（隨機數由呼叫的人用 SecRandomCopyBytes 產生）
    static func verifier(bytes: [UInt8]) -> String {
        base64url(Data(bytes))
    }

    /// code_challenge = BASE64URL(SHA256(ASCII(code_verifier)))
    static func challenge(verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

// MARK: - Google 登入（給已安裝 App 的 OAuth 2.0＋PKCE；不用 client secret、不用 Google SDK）
// 出處：developers.google.com/identity/protocols/oauth2/native-app（端點、參數、iOS 不適用 client_secret、revoke）
//      developers.google.com/identity/sign-in/ios/start-integrating（reversed client ID＝iOS URL scheme）

enum GoogleOAuth {
    static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    static let revokeEndpoint = "https://oauth2.googleapis.com/revoke"
    /// 只看得到 App 自己建的檔和資料夾（非敏感權限）
    static let scope = "https://www.googleapis.com/auth/drive.file"

    /// client id 反過來＝iOS URL scheme：123-abc.apps.googleusercontent.com → com.googleusercontent.apps.123-abc。
    /// 不是 Google 的 iOS 用戶端編號格式就回 nil（當成還沒設定）。
    static func redirectScheme(clientID: String) -> String? {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = ".apps.googleusercontent.com"
        guard id.hasSuffix(suffix), id.count > suffix.count,
              !id.contains(where: { $0.isWhitespace || $0 == "/" || $0 == ":" }) else { return nil }
        return id.split(separator: ".").reversed().joined(separator: ".")
    }

    /// 文件寫法：com.googleusercontent.apps.123:redirect_uri_path，路徑例 /oauth2redirect
    static func redirectURI(clientID: String) -> String? {
        redirectScheme(clientID: clientID).map { $0 + ":/oauth2redirect" }
    }

    static func authURL(clientID: String, challenge: String, state: String) -> URL? {
        guard let redirect = redirectURI(clientID: clientID), var parts = URLComponents(string: authEndpoint) else { return nil }
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return parts.url
    }

    /// application/x-www-form-urlencoded；只留 RFC 3986 的不保留字元，其他都編碼（照輸入順序，測得出來）
    static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        let text = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    /// 登入碼換權杖（iOS 用戶端沒有 client_secret）
    static func codeExchangeFields(clientID: String, code: String, verifier: String) -> [(String, String)] {
        [
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", verifier),
            ("grant_type", "authorization_code"),
            ("redirect_uri", redirectURI(clientID: clientID) ?? ""),
        ]
    }

    static func refreshFields(clientID: String, refreshToken: String) -> [(String, String)] {
        [
            ("client_id", clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ]
    }

    enum CallbackResult: Equatable {
        case code(String)
        case cancelled
        case failed(String)
    }

    /// 登入頁跳回 App 的網址：state 要對得上（防 CSRF），有 code 才算成功；error=access_denied 是使用者按了取消。
    static func parseCallback(_ url: URL?, expectedState: String) -> CallbackResult {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return .failed("沒有收到登入結果")
        }
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        if let error = value("error") {
            return error == "access_denied" ? .cancelled : .failed("Google 回 \(error)")
        }
        guard value("state") == expectedState else { return .failed("登入結果對不上（state 不同），沒有採用") }
        guard let code = value("code"), !code.isEmpty else { return .failed("沒有收到登入碼") }
        return .code(code)
    }

    enum TokenResult: Equatable {
        case ok(access: String, expiresIn: Double, refresh: String?)
        /// 更新權杖失效（被撤銷、過期、測試模式 7 天到期）：要重新登入
        case needsLogin(String)
        case failed(String)
    }

    /// 權杖端點的回應。400／401 且 error 是 invalid_grant 或 unauthorized_client ＝ 要重新登入。
    /// 回給人看的字不含權杖本身。
    static func parseToken(_ data: Data, status: Int) -> TokenResult {
        struct Reply: Decodable {
            let access_token: String?
            let expires_in: Double?
            let refresh_token: String?
            let error: String?
            let error_description: String?
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        if status == 200, let access = reply?.access_token, !access.isEmpty {
            return .ok(access: access, expiresIn: reply?.expires_in ?? 3600, refresh: reply?.refresh_token)
        }
        let error = reply?.error ?? ""
        let why = String((reply?.error_description ?? error).prefix(120))
        if ["invalid_grant", "unauthorized_client", "invalid_client"].contains(error) || status == 401 {
            return .needsLogin(why.isEmpty ? "HTTP \(status)" : why)
        }
        if status >= 500 || status == 429 {
            return .failed("Google 登入服務忙（\(status)）")
        }
        return .failed("拿權杖失敗（\(status)）" + (why.isEmpty ? "" : "：" + why))
    }
}

// MARK: - Drive API 請求內容
// 出處：developers.google.com/workspace/drive/api/guides/manage-uploads（multipart、resumable）
//      developers.google.com/workspace/drive/api/guides/folder（資料夾、parents、root 別名）
//      developers.google.com/workspace/drive/api/guides/search-files（q 語法、跳脫）
//      developers.google.com/workspace/drive/api/reference/rest/v3/files（trashed 欄位）、files/update（PATCH 上傳）

enum DriveRequest {
    static let api = "https://www.googleapis.com/drive/v3/files"
    static let upload = "https://www.googleapis.com/upload/drive/v3/files"

    /// 建檔或建資料夾的中繼資料（sortedKeys：每次一樣，測得出來）
    struct Metadata: Encodable {
        let name: String
        let mimeType: String?
        let parents: [String]?
    }

    static func metadata(name: String, mimeType: String?, parents: [String]?) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(Metadata(name: name, mimeType: mimeType, parents: parents))) ?? Data("{}".utf8)
    }

    /// multipart/related（RFC 2387）：第一段中繼資料 application/json; charset=UTF-8，第二段檔案本身。
    static func multipart(metadata: Data, media: Data, mediaType: String, boundary: String) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(mediaType)\r\n\r\n".utf8))
        body.append(media)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    static func contentType(boundary: String) -> String {
        "multipart/related; boundary=\(boundary)"
    }

    /// q 裡的字串：反斜線變兩個、單引號前加反斜線
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// 找某個資料夾下同名、沒在垃圾桶的資料夾（drive.file 只看得到這個 App 建的，另一台裝置建的也算）
    static func folderQuery(name: String, parent: String) -> String {
        "name = \(quoted(name)) and mimeType = '\(DrivePlan.folderMime)' and \(quoted(parent)) in parents and trashed = false"
    }

    static func listURL(query: String) -> URL? {
        var parts = URLComponents(string: api)
        parts?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "pageSize", value: "10"),
        ]
        // URLComponents 不編碼 +，Google 會把 + 當空白；q 裡沒有 +（名字固定），保險起見還是換掉
        if let encoded = parts?.percentEncodedQuery {
            parts?.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
        }
        return parts?.url
    }

    /// 用 id 找資料夾：只要 id 和 trashed
    static func getURL(id: String) -> URL? {
        guard let safe = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) else { return nil }
        return URL(string: "\(api)/\(safe)?fields=id,trashed")
    }

    static func createFolderURL() -> URL? {
        URL(string: "\(api)?fields=id")
    }

    /// 新檔：multipart 或 resumable
    static func createUploadURL(resumable: Bool) -> URL? {
        URL(string: "\(upload)?uploadType=\(resumable ? "resumable" : "multipart")&fields=id")
    }

    /// 覆蓋既有檔（PATCH）：multipart 或 resumable
    static func updateUploadURL(id: String, resumable: Bool) -> URL? {
        guard let safe = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) else { return nil }
        return URL(string: "\(upload)/\(safe)?uploadType=\(resumable ? "resumable" : "multipart")&fields=id")
    }

    static func useResumable(size: Int) -> Bool {
        size > DrivePlan.multipartLimit
    }
}

/// 一次請求失敗的種類（決定要不要再試、狀態那行怎麼寫）
enum DriveFailure: Error, Equatable {
    case offline
    case needsLogin
    /// 401：權杖過期，先換新權杖再試一次
    case unauthorized
    /// 404：檔案或資料夾不見了（被永久刪除）
    case notFound
    /// 429、5xx、403 rateLimitExceeded：下次再試
    case retryLater(String)
    case other(String)

    /// Drive API 的 HTTP 狀態 → 種類。body 是 Google 的錯誤 JSON（error.errors[].reason）。
    static func classify(status: Int, body: Data) -> DriveFailure {
        struct Reply: Decodable {
            struct Detail: Decodable {
                struct Item: Decodable { let reason: String? }
                let message: String?
                let errors: [Item]?
            }
            let error: Detail?
        }
        let detail = (try? JSONDecoder().decode(Reply.self, from: body))?.error
        let reasons = detail?.errors?.compactMap(\.reason) ?? []
        switch status {
        case 401:
            return .unauthorized
        case 403:
            if reasons.contains(where: { $0 == "rateLimitExceeded" || $0 == "userRateLimitExceeded" }) {
                return .retryLater("Google 限流（403）")
            }
            if reasons.contains("storageQuotaExceeded") {
                return .other("雲端硬碟空間滿了")
            }
            return .other("沒有權限（403）" + (reasons.first.map { "：\($0)" } ?? ""))
        case 404:
            return .notFound
        case 429, 500...599:
            return .retryLater("Google 忙（\(status)）")
        default:
            return .other("Google 回 \(status)" + (reasons.first.map { "：\($0)" } ?? ""))
        }
    }

    /// 連不上的錯誤碼 → 沒有網路（不算失敗次數）
    static func isOffline(_ code: URLError.Code) -> Bool {
        let codes: [URLError.Code] = [.notConnectedToInternet, .dataNotAllowed, .networkConnectionLost, .internationalRoamingOff,
                                      .callIsActive, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed]
        return codes.contains(code)
    }

    /// 存進狀態的那一筆（offline／needsLogin 分開）
    var problem: DriveProblem {
        switch self {
        case .offline: return DriveProblem(kind: .offline, detail: "沒有網路")
        case .needsLogin, .unauthorized: return DriveProblem(kind: .needsLogin, detail: "要重新登入 Google")
        case .notFound: return DriveProblem(kind: .other, detail: "雲端找不到（404）")
        case .retryLater(let why), .other(let why): return DriveProblem(kind: .other, detail: why)
        }
    }

    /// 這份要不要算失敗次數（沒網路、要重新登入、等一下再試都不算，下一份也先別傳）
    var stopsQueue: Bool {
        switch self {
        case .offline, .needsLogin, .unauthorized, .retryLater: return true
        case .notFound, .other: return false
        }
    }
}
