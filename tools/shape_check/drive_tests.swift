import Foundation

// v0.23.2 Sources/DrivePlan.swift：自動上傳測試資料的純邏輯——要不要傳（私人課程、不在設定檔的課、沒課名、沒登入、關著、沒設定）、
// 資料夾與檔名、待傳清單、狀態那行的字、PKCE、Google 登入與 Drive API 請求內容、錯誤分類。main.swift 只呼叫 driveTests(check)。

func driveTests(_ check: @escaping (String, String, String) -> Void) {
    func skip(_ s: DrivePlan.Skip?) -> String { s.map { "\($0)" } ?? "傳" }

    // ---- 要不要傳
    check(skip(DrivePlan.decide(configured: false, signedIn: true, enabled: true, course: "幾何")), "notConfigured", "上傳：client id 沒填 → 不傳")
    check(skip(DrivePlan.decide(configured: true, signedIn: true, enabled: true, course: "私人課")), "privateCourse", "上傳：私人課程永遠不傳（登入、開著也不傳）")
    check(skip(DrivePlan.decide(configured: true, signedIn: true, enabled: true, course: " 私人課 ")), "privateCourse", "上傳：私人課程前後有空白也不傳")
    check(skip(DrivePlan.decide(configured: true, signedIn: true, enabled: true, course: "私人補課")), "privateCourse", "上傳：課名含 privateKeywords 的字也不傳")
    check(skip(DrivePlan.decide(configured: true, signedIn: true, enabled: true, course: "沒在課表的課")), "unknownCourse", "上傳：不在設定檔課表上的課不傳")
    check(skip(DrivePlan.decide(configured: true, signedIn: true, enabled: true, course: nil)), "noCourse", "上傳：沒課名不傳（和 Haiku 同一個判斷）")
    check(skip(DrivePlan.decide(configured: true, signedIn: true, enabled: true, course: "")), "noCourse", "上傳：課名空字串不傳")
    check(skip(DrivePlan.decide(configured: true, signedIn: false, enabled: true, course: "幾何")), "signedOut", "上傳：沒登入不傳")
    check(skip(DrivePlan.decide(configured: true, signedIn: true, enabled: false, course: "幾何")), "off", "上傳：開關關著不傳")
    check(skip(DrivePlan.decide(configured: true, signedIn: true, enabled: true, course: "幾何")), "傳", "上傳：幾何、登入、開著 → 傳")
    check(skip(DrivePlan.decide(configured: true, signedIn: true, enabled: true, course: "解析幾何")), "傳", "上傳：正式課名也認得")
    check(DrivePlan.Skip.privateCourse.rawValue, "私人課程不傳", "上傳：私人課程的紀錄字")
    check(DrivePlan.Skip.unknownCourse.rawValue, "不在設定檔的課不傳", "上傳：不在設定檔的課的紀錄字")

    // ---- 資料夾與檔名
    check(DrivePlan.rootFolderName, "轉文字App測試資料", "上傳：根資料夾名")
    check(DrivePlan.deviceFolderName(isPad: true), "iPad", "上傳：iPad 子資料夾")
    check(DrivePlan.deviceFolderName(isPad: false), "iPhone", "上傳：iPhone 子資料夾")
    check(DrivePlan.fileName(stamp: "20261111-091230", course: "幾何"), "20261111_解析幾何_App匯出_0912.zip", "上傳：檔名＝現有匯出 zip 名")
    check(DrivePlan.fileName(stamp: "20261111-091230", course: "幾何"),
          ClassRecord.exportFileName(.session, stamp: "20261111-091230", course: "幾何"), "上傳：檔名和手動匯出同一個函式")
    check(DrivePlan.readable("20261111-091230"), "11/11 09:12", "上傳：時間給人看")
    check(DrivePlan.readable("壞的"), "壞的", "上傳：時間格式不對原樣回")

    // ---- 待傳清單
    var queue = DriveQueue.add([], name: "a.zip", at: "20261111-090000").items
    queue = DriveQueue.add(queue, name: "b.zip", at: "20261111-100000").items
    check(queue.map(\.name).joined(separator: ","), "a.zip,b.zip", "待傳：照順序排")
    let again = DriveQueue.add(queue, name: "a.zip", at: "20261111-110000")
    check(again.items.map(\.name).joined(separator: ","), "b.zip,a.zip", "待傳：同名（續錄）取代舊的、放最後")
    check(again.items.last?.addedAt ?? "", "20261111-110000", "待傳：同名換成新的時間")
    check("\(again.dropped.count)", "0", "待傳：同名取代不算丟掉")
    let full = DriveQueue.add(queue, name: "c.zip", at: "20261111-120000", limit: 2)
    check(full.items.map(\.name).joined(separator: ","), "b.zip,c.zip", "待傳：超過上限丟最舊的")
    check(full.dropped.joined(separator: ","), "a.zip", "待傳：回傳丟掉的檔名（要刪本機檔）")
    check(DriveQueue.remove(queue, name: "a.zip").map(\.name).joined(separator: ","), "b.zip", "待傳：傳好拿掉")
    var failing = DriveQueue.fail(queue, name: "a.zip", limit: 2)
    check("\(failing.items.first?.attempts ?? -1) \(failing.giveUp)", "1 false", "待傳：失敗一次記次數")
    failing = DriveQueue.fail(failing.items, name: "a.zip", limit: 2)
    check("\(failing.items.map(\.name).joined(separator: ",")) \(failing.giveUp)", "b.zip true", "待傳：失敗到上限放棄")
    check("\(DriveQueue.fail(queue, name: "沒有.zip").giveUp)", "false", "待傳：不在清單的檔不動")

    // ---- 狀態那行
    var st = DriveState()
    check(DriveText.status(configured: false, signedIn: false, state: st), "還沒設定", "狀態：沒設定")
    check(DriveText.status(configured: true, signedIn: false, state: st), "沒登入：不上傳", "狀態：沒登入")
    check(DriveText.status(configured: true, signedIn: true, state: st), "還沒上傳過", "狀態：登入了還沒傳")
    st.lastSuccess = "20261111-091230"
    check(DriveText.status(configured: true, signedIn: true, state: st), "上次上傳 11/11 09:12", "狀態：上次上傳時間")
    st.pending = [DriveQueueItem(name: "a.zip", addedAt: "x"), DriveQueueItem(name: "b.zip", addedAt: "y")]
    st.problem = DriveFailure.offline.problem
    check(DriveText.status(configured: true, signedIn: true, state: st), "待傳 2 份：沒有網路", "狀態：沒網路")
    st.problem = DriveFailure.retryLater("Google 忙（503）").problem
    check(DriveText.status(configured: true, signedIn: true, state: st), "待傳 2 份：Google 忙（503）", "狀態：其他錯誤寫原因")
    st.problem = DriveFailure.needsLogin.problem
    check(DriveText.status(configured: true, signedIn: true, state: st), "要重新登入 Google", "狀態：要重新登入和沒網路分開")
    check(DriveFailure.unauthorized.problem.kind.rawValue, "needsLogin", "狀態：401 也算要重新登入")
    st.problem = nil
    st.enabled = false
    check(DriveText.status(configured: true, signedIn: true, state: st), "待傳 2 份（已關閉）", "狀態：關著還有待傳")
    st.pending = []
    check(DriveText.status(configured: true, signedIn: true, state: st), "已關閉（上次上傳 11/11 09:12）", "狀態：關著")

    // 狀態存檔讀得回、少欄位用預設
    let empty = try? JSONDecoder().decode(DriveState.self, from: Data("{}".utf8))
    check(empty.map { "\($0.enabled) \($0.pending.count) \($0.rootID ?? "nil")" } ?? "讀不開", "true 0 nil", "狀態檔：空的用預設（開、沒有待傳）")
    st.rootID = "root1"
    st.uploaded = ["a.zip": "file1"]
    st.problem = DriveProblem(kind: .offline, detail: "沒有網路")
    let back = (try? JSONEncoder().encode(st)).flatMap { try? JSONDecoder().decode(DriveState.self, from: $0) }
    check(back == st ? "一樣" : "不一樣", "一樣", "狀態檔：存了讀回來一樣")

    // ---- PKCE（RFC 7636 附錄 B 的例子）
    let rfcBytes: [UInt8] = [116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186,
                             22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121]
    let verifier = PKCE.verifier(bytes: rfcBytes)
    check(verifier, "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", "PKCE：verifier（RFC 7636 附錄 B）")
    check(PKCE.challenge(verifier: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "PKCE：S256 challenge（RFC 7636 附錄 B）")
    check("\(verifier.count)", "43", "PKCE：32 位元組 → 43 字")
    check(PKCE.base64url(Data([251, 255])), "-_8", "PKCE：base64url 換 +/ 去 =")

    // ---- Google 登入請求
    let cid = "123456789012-abc123def.apps.googleusercontent.com"
    check(GoogleOAuth.redirectScheme(clientID: cid) ?? "nil", "com.googleusercontent.apps.123456789012-abc123def", "登入：client id 反過來＝URL scheme")
    check(GoogleOAuth.redirectURI(clientID: cid) ?? "nil", "com.googleusercontent.apps.123456789012-abc123def:/oauth2redirect", "登入：redirect_uri")
    check(GoogleOAuth.redirectScheme(clientID: "") ?? "nil", "nil", "登入：空字串＝還沒設定")
    check(GoogleOAuth.redirectScheme(clientID: "隨便打的") ?? "nil", "nil", "登入：不是 Google 用戶端編號＝還沒設定")
    check(GoogleOAuth.redirectScheme(clientID: "  \(cid) \n") ?? "nil", "com.googleusercontent.apps.123456789012-abc123def", "登入：前後空白不影響")
    check(GoogleOAuth.scope, "https://www.googleapis.com/auth/drive.file", "登入：權限只要 drive.file")
    let auth = GoogleOAuth.authURL(clientID: cid, challenge: "CH", state: "ST")
    let items = auth.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    let itemText = items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
    check(itemText, "client_id=\(cid)&redirect_uri=com.googleusercontent.apps.123456789012-abc123def:/oauth2redirect&response_type=code&scope=https://www.googleapis.com/auth/drive.file&code_challenge=CH&code_challenge_method=S256&state=ST", "登入：授權網址的參數")
    check(auth.map { $0.absoluteString.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth?") ? "對" : $0.absoluteString } ?? "nil", "對", "登入：授權端點")
    check(String(decoding: GoogleOAuth.formBody([("a", "b c"), ("u", "https://x/y?z=1&w")]), as: UTF8.self),
          "a=b%20c&u=https%3A%2F%2Fx%2Fy%3Fz%3D1%26w", "登入：表單編碼")
    let exchange = GoogleOAuth.codeExchangeFields(clientID: cid, code: "4/abc", verifier: "VER")
    check(exchange.map(\.0).joined(separator: ","), "client_id,code,code_verifier,grant_type,redirect_uri", "登入：換權杖的欄位（沒有 client_secret）")
    check(String(decoding: GoogleOAuth.formBody(exchange), as: UTF8.self),
          "client_id=\(cid)&code=4%2Fabc&code_verifier=VER&grant_type=authorization_code&redirect_uri=com.googleusercontent.apps.123456789012-abc123def%3A%2Foauth2redirect", "登入：換權杖的表單")
    check(GoogleOAuth.refreshFields(clientID: cid, refreshToken: "R").map { "\($0.0)=\($0.1)" }.joined(separator: "&"),
          "client_id=\(cid)&grant_type=refresh_token&refresh_token=R", "登入：更新權杖的欄位")

    func callback(_ text: String) -> String {
        switch GoogleOAuth.parseCallback(URL(string: text), expectedState: "ST") {
        case .code(let code): return "code \(code)"
        case .cancelled: return "cancelled"
        case .failed(let why): return "failed \(why)"
        }
    }
    check(callback("com.googleusercontent.apps.1:/oauth2redirect?state=ST&code=4/xyz&scope=s"), "code 4/xyz", "登入：跳回 App 拿到登入碼")
    check(callback("com.googleusercontent.apps.1:/oauth2redirect?state=XX&code=4/xyz"), "failed 登入結果對不上（state 不同），沒有採用", "登入：state 不同不採用")
    check(callback("com.googleusercontent.apps.1:/oauth2redirect?error=access_denied&state=ST"), "cancelled", "登入：使用者按取消")
    check(callback("com.googleusercontent.apps.1:/oauth2redirect?state=ST"), "failed 沒有收到登入碼", "登入：沒有 code")

    func token(_ json: String, _ status: Int) -> String {
        switch GoogleOAuth.parseToken(Data(json.utf8), status: status) {
        case .ok(let access, let expires, let refresh): return "ok \(access) \(Int(expires)) \(refresh ?? "nil")"
        case .needsLogin(let why): return "needsLogin \(why)"
        case .failed(let why): return "failed \(why)"
        }
    }
    check(token(#"{"access_token":"A","expires_in":3599,"refresh_token":"R","token_type":"Bearer"}"#, 200), "ok A 3599 R", "權杖：第一次登入有更新權杖")
    check(token(#"{"access_token":"A2","expires_in":3599}"#, 200), "ok A2 3599 nil", "權杖：更新時沒有新的更新權杖")
    check(token(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#, 400), "needsLogin Token has been expired or revoked.", "權杖：更新權杖失效＝要重新登入")
    check(token(#"{"error":"internal_failure"}"#, 503), "failed Google 登入服務忙（503）", "權杖：5xx 是忙，不是要重新登入")

    // ---- Drive API 請求內容
    check(String(decoding: DriveRequest.metadata(name: "轉文字App測試資料", mimeType: DrivePlan.folderMime, parents: ["root"]), as: UTF8.self),
          #"{"mimeType":"application/vnd.google-apps.folder","name":"轉文字App測試資料","parents":["root"]}"#, "雲端：建資料夾的中繼資料")
    check(String(decoding: DriveRequest.metadata(name: "a.zip", mimeType: nil, parents: nil), as: UTF8.self),
          #"{"name":"a.zip"}"#, "雲端：覆蓋時只帶檔名（不帶 parents）")
    let body = DriveRequest.multipart(metadata: Data(#"{"name":"a.zip"}"#.utf8), media: Data("ZIP".utf8), mediaType: "application/zip", boundary: "BB")
    check(String(decoding: body, as: UTF8.self),
          "--BB\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{\"name\":\"a.zip\"}\r\n--BB\r\nContent-Type: application/zip\r\n\r\nZIP\r\n--BB--\r\n", "雲端：multipart 本文")
    check(DriveRequest.contentType(boundary: "BB"), "multipart/related; boundary=BB", "雲端：multipart 標頭")
    check(DriveRequest.quoted("a'b\\c"), "'a\\'b\\\\c'", "雲端：q 字串跳脫單引號與反斜線")
    check(DriveRequest.folderQuery(name: "iPad", parent: "P1"),
          "name = 'iPad' and mimeType = 'application/vnd.google-apps.folder' and 'P1' in parents and trashed = false", "雲端：找同名資料夾的 q")
    let list = DriveRequest.listURL(query: "name = 'a+b'")
    let listItems = list.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    check(listItems.first(where: { $0.name == "q" })?.value ?? "nil", "name = 'a+b'", "雲端：list 的 q 解得回原字")
    check(list.map { $0.absoluteString.contains("a%2Bb") ? "對" : $0.absoluteString } ?? "nil", "對", "雲端：q 裡的 + 編成 %2B")
    check(listItems.first(where: { $0.name == "fields" })?.value ?? "nil", "files(id,name)", "雲端：list 只要 id、name")
    check(DriveRequest.getURL(id: "1AbC-_x")?.absoluteString ?? "nil", "https://www.googleapis.com/drive/v3/files/1AbC-_x?fields=id,trashed", "雲端：用 id 找資料夾")
    check(DriveRequest.createFolderURL()?.absoluteString ?? "nil", "https://www.googleapis.com/drive/v3/files?fields=id", "雲端：建資料夾網址")
    check(DriveRequest.createUploadURL(resumable: false)?.absoluteString ?? "nil", "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id", "雲端：新檔 multipart")
    check(DriveRequest.createUploadURL(resumable: true)?.absoluteString ?? "nil", "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id", "雲端：新檔 resumable")
    check(DriveRequest.updateUploadURL(id: "F1", resumable: false)?.absoluteString ?? "nil", "https://www.googleapis.com/upload/drive/v3/files/F1?uploadType=multipart&fields=id", "雲端：覆蓋舊檔")
    check("\(DriveRequest.useResumable(size: 5 * 1024 * 1024)) \(DriveRequest.useResumable(size: 5 * 1024 * 1024 + 1))", "false true", "雲端：5 MB 以下 multipart、以上 resumable")

    // ---- 錯誤分類
    func cls(_ status: Int, _ json: String = "") -> String {
        switch DriveFailure.classify(status: status, body: Data(json.utf8)) {
        case .offline: return "offline"
        case .needsLogin: return "needsLogin"
        case .unauthorized: return "unauthorized"
        case .notFound: return "notFound"
        case .retryLater(let why): return "retryLater \(why)"
        case .other(let why): return "other \(why)"
        }
    }
    check(cls(401), "unauthorized", "錯誤：401 先換權杖")
    check(cls(403, #"{"error":{"code":403,"errors":[{"reason":"userRateLimitExceeded"}]}}"#), "retryLater Google 限流（403）", "錯誤：403 限流下次再試")
    check(cls(403, #"{"error":{"code":403,"errors":[{"reason":"storageQuotaExceeded"}]}}"#), "other 雲端硬碟空間滿了", "錯誤：空間滿")
    check(cls(404), "notFound", "錯誤：404 找不到（重建資料夾）")
    check(cls(503), "retryLater Google 忙（503）", "錯誤：5xx 下次再試")
    check(cls(429), "retryLater Google 忙（429）", "錯誤：429 下次再試")
    check(cls(400, #"{"error":{"code":400,"errors":[{"reason":"badRequest"}]}}"#), "other Google 回 400：badRequest", "錯誤：400 寫原因")
    check("\(DriveFailure.isOffline(.notConnectedToInternet)) \(DriveFailure.isOffline(.networkConnectionLost)) \(DriveFailure.isOffline(.badURL))", "true true false", "錯誤：沒網路的錯誤碼")
    check("\(DriveFailure.offline.stopsQueue) \(DriveFailure.needsLogin.stopsQueue) \(DriveFailure.other("x").stopsQueue)", "true true false", "錯誤：沒網路／要登入整批停，其他只記這份")
}
