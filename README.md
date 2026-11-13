# 轉文字（iOS / iPadOS）

上課、對談錄音即時轉成繁體中文字稿的 App。錄音和轉文字都在裝置上做（Apple SpeechTranscriber；可選 WhisperKit 在下課後再轉一份），另有：

- 照課表自動命名錄音（課表放在裝置上的設定檔，見下面）
- 錄音中照課程對照表即時改字（只改畫面，存檔的稿是原字）
- 可選：錄音中把稿的字送 Claude Haiku 改字（要自己的 Anthropic API 金鑰，存在裝置鑰匙圈；錄音本身不送）
- 可選：停止後把「匯出（不含錄音）」那包傳到自己的 Google 雲端硬碟
- 離線分人（FluidAudio）、連電腦版當麥克風、引擎比較的實驗模式

## 目前狀態（v0.26.4）

- 即時模式 1（Whisper 主稿）改成每 60 秒一張卡：Haiku 一次回一句重點、2–4 句整理版、投影片頁碼，和「擴寫式校正」全文（每句保留、不摘要，只改聽錯的字、補標點）。錄音畫面由上而下一張張卡；原稿區一句一行，改過的字綠色，點了才看原字。
- 停止後逐字稿＝各卡的擴寫接起來；raw.txt 照舊是 Whisper 原字。匯出多 `cards.json`（每卡）和 `tidy.txt`（整理版）。「用錄好的檔模擬上課」走同一條路。
- 模式 0、2 照舊（挑字改字＋程式驗證）。
- v0.26.1：卡片右上分享鈕（文字＋那一頁投影片的圖，投影片要 v0.26.1 起匯入才有 PDF）、長按拖到旁邊的 App；結果畫面多「看卡片」；iPad 視窗可拉得更矮（高 < 400 點精簡排版）；被打斷後 0.5／1／2／4 秒快速重接麥克風；星星選單「麥克風和別的 App 共用」（下次錄音生效）。
- v0.26.2：卡片一律顯示完整文字（整理到＝改好的全文、綠字點了看原字；還在整理或沒整理到＝Whisper 原字），「原稿」改成預設收起來；送 Haiku 網路錯（含 -1200）錄音中不再放棄，前 3 次 5／15／45 秒、之後每 30 秒再送，卡上寫「網路不通，等一下再送」；往上捲時不會一直被拉回底部；內容少時從上面排。
- v0.26.3：修錄音中畫面整片空白一下又出現（卡片清單改一般 VStack、內容比畫面短時不捲）；字分大小（重點最大、整理版、完整文字小一號；下方即時字和完整文字同大小）；還沒有任何字時顯示「聽著…第一句通常 10–15 秒後出現」。
- v0.26.4：錄音畫面改版——iPad 寬（≥ 700 點）左邊逐字稿一路往下、右邊重點卡；分割畫面或手機變一欄，重點在段落上方。字級：重點 22 粗、整理版 15、逐字稿 13、時間 11；下方即時字和逐字稿同大小。「原稿」改名「原始轉錄」，預設收起來。結果畫面「看卡片」同一套排法。

## 怎麼編

需要 macOS、Xcode 26（iOS 26 SDK）、[XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
xcodegen generate
xcodebuild -project LectureText.xcodeproj -scheme LectureText -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
```

套件：FluidAudio 0.18.2、argmax-oss-swift（WhisperKit）1.1.1，版本寫死在 `project.yml`。
不簽名編出來的 .app 要自己簽再裝（例如 Sideloadly）。`.github/workflows/build.yml` 是同一套流程的 GitHub Actions 版，結果推到 `build-out` 分支；**公開倉庫的 build-out 誰都下載得到**。

不用 Xcode 也能先跑純邏輯的測試（只用 Foundation）：在倉庫根目錄照 `.github/workflows/build.yml` 第一步那行 `swiftc … -o shape_check` 編，再跑 `./shape_check`（要編哪些檔只寫在那一行）。

Haiku 的提示詞正本在 `tools/haiku_prompt/`，改了要跑 `python tools/haiku_prompt/同步提示詞.py` 產生 `Sources/HaikuPromptText.swift`。

## 設定檔：課表與課程對照表

程式裡不寫任何課名。App 啟動、回到前景時讀 `轉文字/設定/轉文字設定.json`（「檔案」App › 我的 iPhone／iPad › 轉文字 › 設定）。
**沒有這個檔＝沒有課表**：錄音用時間命名、沒有課程對照表、沒有課可以送 Haiku 或自動上傳；其他功能照常。

例子（課名都是編的）：

```json
{
  "firstDay": "2026-02-23",
  "lastDay": "2026-06-21",
  "toleranceMinutes": 10,
  "courses": [
    {"name": "幾何", "formal": "解析幾何", "weekday": 3, "from": "08:00", "to": "09:50"},
    {"name": "幾何", "formal": "解析幾何", "weekday": 6, "from": "14:00", "to": "15:30"},
    {"name": "讀書會", "weekday": 5, "from": "18:00", "to": "19:30", "weeks": [1, 3, 5, 7]},
    {"name": "私人課", "weekday": 1, "from": "20:00", "to": "21:00", "private": true}
  ],
  "offDays": {"2026-03-18": [], "2026-03-14": ["幾何"]},
  "privateKeywords": ["私人"],
  "liveFix": {"解析幾何": [["像量", "向量"], ["飛靈", "非零"]]}
}
```

| 欄位 | 意思 |
| --- | --- |
| `firstDay` | 第 1 週的週一（yyyy-MM-dd）；`weeks` 從這天算。沒寫就不限開始日，`weeks` 的課不排 |
| `lastDay` | 課表最後一天，之後一律用時間命名；沒寫就不過期 |
| `toleranceMinutes` | 上課前後幾分鐘內按錄音都算這堂（預設 10） |
| `courses[].name` | 標題和資料夾用的簡稱。**改了就和舊錄音的資料夾對不上** |
| `courses[].formal` | 正式課名，用在匯出檔名、課程設定檔名、課程對照表的 key；沒寫＝和 `name` 一樣 |
| `courses[].weekday` | 1＝週一 … 7＝週日 |
| `courses[].from` / `to` | HH:mm |
| `courses[].weeks` | 只有這幾週上；沒寫是每週 |
| `courses[].private` | 私人課程：永遠不送 Haiku、不自動上傳、不出現在投影片選課 |
| `offDays` | 停課日：空陣列＝整天沒課，否則只有列出的簡稱停 |
| `privateKeywords` | 課名（簡稱或正式名）含這些字就當私人課程 |
| `liveFix` | 課程對照表：key 是正式課名，每條是 `[稿裡常見的錯, 正確]`，錄音中只改畫面 |

格式錯（星期不是 1–7、時間不是 HH:mm、日期不是 yyyy-MM-dd、對照表一條不是兩個字串）整份不套用，橫幅會講是哪裡錯。

**匯入方式**（擇一）：

1. 用「檔案」App 把 `轉文字設定.json` 放進 我的 iPhone／iPad › 轉文字 › 設定（沒有就新建「設定」資料夾），再回到 App。
2. 在「檔案」App 長按 `轉文字設定.json` › 分享 › 選「轉文字」（或在 App 裡按「選檔案」選它）。App 檢查過才存進上面那個位置並套用；檔名要是「轉文字設定」開頭的 .json。

## Google 雲端硬碟自動上傳（可選）

在 Google Cloud Console 建一個「iOS」類型的 OAuth 用戶端（Bundle ID 用 `com.lecturetext.LectureText`），把用戶端編號填進 `Sources/GoogleDriveConfig.swift`。iOS 用戶端沒有 client secret，編號本身不是密碼。只要求 `drive.file` 權限（只看得到 App 自己建的檔）。沒填就整個功能不動作。

## 資料去向

- 錄音、逐字稿、聲紋都在裝置的 App 文件夾，標成不進 iCloud 備份。
- 送 Haiku 的只有稿的文字（使用者打開、有金鑰、不是私人課程時）；錄音不送。
- 智慧校正查維基百科只送挑出來的詞，像私人姓名的詞程式會先擋下。
