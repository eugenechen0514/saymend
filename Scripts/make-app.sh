#!/bin/zsh
# 組出 build/Speeckink.app：SwiftPM 產物 + Info.plist + 資源 bundle + ad-hoc 簽章。
# 注意：ad-hoc 簽章每次重簽，輔助功能授權可能需在系統設定重新勾選。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Speeckink.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/SpeeckinkApp "$APP/Contents/MacOS/Speeckink"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# SwiftyOpenCC 等資源 bundle（Bundle.module 會在 Contents/Resources 找）
cp -R .build/release/*.bundle "$APP/Contents/Resources/" 2>/dev/null || true

codesign --force --sign - "$APP"
echo "完成 → $APP"
