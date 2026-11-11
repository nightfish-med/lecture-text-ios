#!/bin/bash
# 模擬器：只截畫面。只在 commit 訊息含 [sim] 時跑（雲端 Mac 額度有限）。
# 模擬器上 SpeechTranscriber 據回報不可用，所以這裡驗不到轉文字，畫面靠 -demo-* 假資料（只有 Debug 有）。
set -x
xcodebuild -project LectureText.xcodeproj -scheme LectureText -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath simbuild \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build > out/sim-build.log 2>&1 || { tail -40 out/sim-build.log; exit 1; }
APP=simbuild/Build/Products/Debug-iphonesimulator/LectureText.app
BID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")
U=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
d=json.load(sys.stdin)['devices']
print([x['udid'] for k,v in sorted(d.items(),reverse=True) if 'iOS' in k for x in v if x['name'].startswith('iPhone 17')][0])")
mkdir -p out/shots
xcrun simctl boot "$U"; xcrun simctl bootstatus "$U" -b >/dev/null
xcrun simctl install "$U" "$APP"
for s in idle recording download transcribing done failed; do
  xcrun simctl terminate "$U" "$BID" 2>/dev/null
  xcrun simctl launch "$U" "$BID" "-demo-$s"
  sleep 4
  xcrun simctl io "$U" screenshot "out/shots/$s.png"
done
xcrun simctl shutdown "$U"
rm -f out/sim-build.log
