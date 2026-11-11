// v0.23.2 自動上傳測試資料：Google 登入用的「iOS 類型 OAuth 用戶端編號」。
// 在 Google Cloud Console 建好 iOS 用戶端後，只改下面這一行（步驟見 README「Google 雲端硬碟自動上傳」）。
// 格式像「123456789012-abcdefg.apps.googleusercontent.com」。這不是密碼（iOS 用戶端沒有 client secret），放在程式裡沒關係。
// 空字串＝還沒設定：星星選單那項顯示「還沒設定」，整個自動上傳不動作，其他功能照舊。

enum GoogleDriveConfig {
    static let clientID = ""
}
