#!/bin/zsh
# 組出 build/Saymend.app：SwiftPM 產物 + Info.plist + 資源 bundle + 簽章。
# 簽章優先用穩定的 Apple Development 憑證（TCC 授權可跨重建保留）；
# 找不到憑證才退回 ad-hoc（每次重簽，輔助使用授權會失效需重勾）。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Saymend.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

cp .build/release/SaymendApp "$APP/Contents/MacOS/Saymend"
# `saymend` CLI（本機控制介面的 client，docs/control-interface.md）放 Helpers 而非 MacOS：
# 檔案系統不分大小寫，Contents/MacOS/saymend 會跟主程式 Saymend 撞名。
cp .build/release/SaymendCLI "$APP/Contents/Helpers/saymend"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 遠端橋接的 client（docs/remote.md）：app 用 ssh 把它裝到遠端的 ~/.saymend-remote/
mkdir -p "$APP/Contents/Resources/remote"
cp Resources/remote/saymend_remote.py "$APP/Contents/Resources/remote/saymend_remote.py"
# SwiftyOpenCC 等資源 bundle（Bundle.module 會在 Contents/Resources 找）
cp -R .build/release/*.bundle "$APP/Contents/Resources/" 2>/dev/null || true

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')
# 巢狀的執行檔要先簽，外層 bundle 的簽章才涵蓋得到它（不用 --deep）
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/Helpers/saymend"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "簽章身分：${IDENTITY:-ad-hoc}"

# 在 ~/.local/bin 建 `saymend` symlink，指向這次打包的 bundle 裡的 CLI。
# 只取代既有的 symlink；同名的一般檔案不動（那不是我們放的）。SAYMEND_SKIP_CLI_LINK=1 可略過。
if [[ -z "${SAYMEND_SKIP_CLI_LINK:-}" ]]; then
  BIN_DIR="$HOME/.local/bin"
  LINK="$BIN_DIR/saymend"
  mkdir -p "$BIN_DIR"
  if [[ -e "$LINK" && ! -L "$LINK" ]]; then
    echo "略過 symlink：$LINK 已存在且不是 symlink"
  else
    ln -sfn "$PWD/$APP/Contents/Helpers/saymend" "$LINK"
    echo "CLI → $LINK -> $PWD/$APP/Contents/Helpers/saymend"
  fi
fi
echo "完成 → $APP"
