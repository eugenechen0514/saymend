# Speeckink

macOS 語音輸入工具：說完即成稿，改稿用嘴不用滑鼠（M1 為核心聽寫；口頭修正見規格 M2）。

## 需求
- macOS 26+（SpeechAnalyzer）
- Xcode 26 toolchain
- 一個 OpenAI-compatible LLM 端點（雲端或本地 Ollama／LM Studio）

## 建置與執行
    ./Scripts/make-app.sh
    open build/Speeckink.app

首次啟動請允許：輔助使用、麥克風、語音辨識。ad-hoc 簽章重建後可能需重新授權輔助使用。

## 使用
- 按住「右 Cmd」說話，放開即潤飾上屏；短按切換鎖定聽寫，再短按結束。
- 聽寫中按 Esc 取消目前段落。
- 口頭修正（M2）：說完一句後 8 秒內（HUD 顯示「可修正」），直接按住熱鍵說「欸前面星期二改成星期三」這類指令，文字原地更新；說「復原上一步」或點 HUD 的「復原」可回上一版。
- 聽寫中手動打字或點擊滑鼠會「凍結」本段（不再自動改寫）；密碼欄位一律拒絕聽寫。
- **選取即目標（M3）**：選取欄位文字後按住熱鍵說指令（「改正式一點」「翻成英文」）＝原地改寫選取；說新內容＝取代選取。替換後可繼續口頭修正與復原。
- **視覺回饋（M3）**：語音掌控中的文字帶細底線；每次替換閃現高亮。App 不支援座標查詢時，HUD 以刪除線／底線 diff 呈現最近異動。
- 設計規格：docs/superpowers/specs/2026-07-12-speeckink-design.md

## 開發
    swift test          # 核心邏輯全部單元測試
    swift build         # 編譯
