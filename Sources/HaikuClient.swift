import Foundation
import Security

// v0.23.1 地基：API 金鑰（iOS 鑰匙圈）＋「測試連線」。錄音中送稿改字是 0.23.2，在這個檔接著加。
// 金鑰只放鑰匙圈；畫面、紀錄、錯誤資料、匯出檔只寫 sk-ant-…末4碼，不寫進 UserDefaults。

/// 鑰匙圈裡的 Anthropic API 金鑰。
/// 存取等級 AfterFirstUnlockThisDeviceOnly：開機解鎖過一次後，鎖螢幕中（錄音中）也讀得到；不進備份、不同步到別台（規格 A 表第 8 點）。
enum HaikuKey {
    private static let service = "com.lecturetext.anthropic"
    private static let account = "api-key"

    enum PasteProblem: Error {
        case empty
        case notKey
        case saveFailed(OSStatus)

        var message: String {
            switch self {
            case .empty: return "剪貼簿裡沒有字：先在 Anthropic Console 複製金鑰再按一次"
            case .notKey: return "剪貼簿裡的字不是 sk-ant- 開頭的金鑰，沒有存"
            case .saveFailed(let status): return "存進鑰匙圈失敗（\(status)）"
            }
        }
    }

    /// 給人看、寫紀錄用：sk-ant-…WXYZ（0.23.2 起寫在 HaikuFix.swift 的 APIKeyMask，shape_check 測得到；行為不變）
    static func masked(_ key: String) -> String {
        APIKeyMask.masked(key)
    }

    /// 剪貼簿的字去頭尾空白、檢查開頭；沒問題回傳金鑰本身。
    static func clean(_ raw: String?) -> Result<String, PasteProblem> {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        guard text.hasPrefix("sk-ant-"), text.count > 12, !text.contains(where: { $0.isWhitespace }) else { return .failure(.notKey) }
        return .success(text)
    }

    /// 「貼上金鑰」：剪貼簿的字檢查過就存進鑰匙圈。成功回傳遮過的 sk-ant-…末4碼（金鑰本身不往外傳）。
    static func paste(_ raw: String?) -> Result<String, PasteProblem> {
        switch clean(raw) {
        case .failure(let problem):
            return .failure(problem)
        case .success(let key):
            let status = save(key)
            guard status == errSecSuccess else { return .failure(.saveFailed(status)) }
            return .success(masked(key))
        }
    }

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

    /// 舊的先刪再存（存取等級才一定是新的那個）。
    @discardableResult
    static func save(_ key: String) -> OSStatus {
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// 送 Anthropic API。0.23.1 只有「測試連線」：送一句「回答：好」，看金鑰能不能用、要幾秒。
enum HaikuClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"
    static let model = "claude-haiku-5-5"

    /// 測試連線的請求內容。用 Codable＋sortedKeys 編，鍵的順序每次一樣（0.23.2 的快取靠這個，這裡先照同一套寫）。
    /// 不送 temperature（2026-10-21 版會 400）、不送 thinking（Haiku 5.5 預設 adaptive）。
    struct TestRequest: Encodable {
        struct OutputConfig: Encodable { let effort: String }
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let max_tokens: Int
        let output_config: OutputConfig
        let messages: [Message]
    }

    static func testBody() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(TestRequest(
            model: model,
            max_tokens: 64,
            output_config: .init(effort: "low"),
            messages: [.init(role: "user", content: "回答：好")]
        ))
    }

    /// 回傳給畫面看的一句話和要不要算成功。不含金鑰；API 的錯誤訊息最多帶 100 字。
    static func testConnection(key: String) async -> (ok: Bool, line: String) {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        do {
            request.httpBody = try testBody()
        } catch {
            return (false, "請求內容編不出來：\(error.localizedDescription)")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let seconds = Date().timeIntervalSince(started)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                return (true, String(format: "金鑰可用（%.1f 秒）", seconds))
            case 401, 403:
                return (false, "金鑰無效（\(code)）：到 Anthropic Console 重新複製一把再貼")
            case 429:
                return (false, "請求太多次（429），等一下再試")
            case 400:
                return (false, "Anthropic 不收這個請求（400）\(apiMessage(data))")
            case 402:
                return (false, "帳戶要付款或額度用完（402）\(apiMessage(data))")
            case 500...599:
                return (false, "Anthropic 那邊忙或故障（\(code)），等一下再試")
            default:
                return (false, "Anthropic 回 \(code)\(apiMessage(data))")
            }
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .dataNotAllowed:
                return (false, "沒有網路：連上 Wi-Fi 或行動網路再試")
            case .timedOut:
                return (false, "逾時：15 秒沒回應（網路太慢或 Anthropic 忙）")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost:
                return (false, "連不上 Anthropic（\(error.code.rawValue)），網路可能被擋")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                return (false, "加密連線失敗（\(error.code.rawValue)）：公共 Wi-Fi 可能要先登入")
            default:
                return (false, "連線失敗（\(error.code.rawValue)）")
            }
        } catch {
            return (false, "連線失敗：\(error.localizedDescription)")
        }
    }

    /// v0.23.2：400 這類不重送的回應，紀錄只留 API 的錯誤說明（error.type＋error.message）前 200 字（規格 B6）。不含稿的字、不含金鑰。
    static func errorText(_ data: Data, status: Int) -> String {
        struct Reply: Decodable {
            struct Detail: Decodable { let type: String?; let message: String? }
            let error: Detail?
        }
        let detail = (try? JSONDecoder().decode(Reply.self, from: data))?.error
        let text = [detail?.type, detail?.message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "：")
        return "HTTP \(status)" + (text.isEmpty ? "" : "：" + String(text.prefix(200)))
    }

    /// API 回的錯誤說明（error.message），最多 100 字；讀不到就空字串。
    private static func apiMessage(_ data: Data) -> String {
        struct Reply: Decodable {
            struct Detail: Decodable { let message: String? }
            let error: Detail?
        }
        guard let message = (try? JSONDecoder().decode(Reply.self, from: data))?.error?.message, !message.isEmpty else { return "" }
        return "：" + String(message.prefix(100))
    }
}

// MARK: - v0.23.2 錄音中送稿改字

/// 送一批的結果：有回應（任何 HTTP 狀態）或連不上。message 不含稿的字、不含金鑰。
enum HaikuOutcome {
    case response(data: Data, status: Int, latency: Double, retryAfter: String?)
    /// offline：沒網路、連線中斷（App 被暫停後回來常是 -1005）——不算重試次數，等網路回來
    case failure(message: String, offline: Bool)
}

extension HaikuClient {
    /// 錄音中送稿用的連線：請求逾時 30 秒、整體 45 秒、沒網路不等（規格 B6）。一般請求，不用背景專用的 URLSession。
    static let reviewSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// POST /v1/messages。body 由 HaikuPrompt.requestBody 產生（Codable＋sortedKeys，快取靠這個）。回傳資料、HTTP 狀態、延遲秒數。
    static func send(body: Data, key: String) async -> HaikuOutcome {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body
        let started = Date()
        do {
            let (data, response) = try await reviewSession.data(for: request)
            let http = response as? HTTPURLResponse
            return .response(
                data: data,
                status: http?.statusCode ?? 0,
                latency: Date().timeIntervalSince(started),
                retryAfter: http?.value(forHTTPHeaderField: "retry-after")
            )
        } catch let error as URLError {
            let offlineCodes: [URLError.Code] = [.notConnectedToInternet, .dataNotAllowed, .networkConnectionLost,
                                                 .internationalRoamingOff, .callIsActive]
            let message: String
            switch error.code {
            case .timedOut: message = "逾時：30 秒沒回應"
            case .notConnectedToInternet, .dataNotAllowed: message = "沒有網路"
            case .networkConnectionLost: message = "連線中斷（-1005）"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: message = "連不上 Anthropic（\(error.code.rawValue)）"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                message = "加密連線失敗（\(error.code.rawValue)）：公共 Wi-Fi 可能要先登入"
            default: message = "連線失敗（\(error.code.rawValue)）"
            }
            return .failure(message: message, offline: offlineCodes.contains(error.code))
        } catch {
            return .failure(message: "連線失敗", offline: false)
        }
    }
}
