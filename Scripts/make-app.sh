#!/bin/zsh
# 組出 build/Saymend.app：SwiftPM 產物 + Info.plist + 資源 bundle + 簽章。
# 簽章優先用穩定的 Apple Development 憑證（TCC 授權可跨重建保留）；
# 找不到憑證才退回 ad-hoc（每次重簽，輔助使用授權會失效需重勾）。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Saymend.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/SaymendApp "$APP/Contents/MacOS/Saymend"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# SwiftyOpenCC 等資源 bundle（Bundle.module 會在 Contents/Resources 找）
cp -R .build/release/*.bundle "$APP/Contents/Resources/" 2>/dev/null || true

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "簽章身分：${IDENTITY:-ad-hoc}"
echo "完成 → $APP"
